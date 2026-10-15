#!/usr/bin/env node
// build-wiki.mjs - Transform the Qoder Repo Wiki source tree into a flat,
// navigable GitHub Wiki.
//
// GitHub Wiki is a FLAT namespace: it discards the source directory hierarchy
// and renders one alphabetical "Pages" list. Mirroring the nested source tree
// verbatim therefore produces a wall of pages with confusing duplicate titles
// (the same basename living at several depths) and no navigation.
//
// This builder fixes that deterministically, WITHOUT editing the Qoder-managed
// source content:
//   - Every page is renamed to a collision-free, self-describing title derived
//     from its full path (e.g. "Core Concepts - Memory System - ...").
//   - Redundant folder-index duplication (".../X/X.md") is collapsed.
//   - A hierarchical `_Sidebar.md` and a landing `Home.md` are generated from
//     the tree so readers navigate by structure, not by the flat Pages list.
//   - Dead `file://<repo-path>` references are rewritten to clickable GitHub
//     blob URLs.
//
// Usage:
//   SOURCE_DIR=<abs content dir> node scripts/build-wiki.mjs <out-dir>
//
// Environment / arguments:
//   SOURCE_DIR   Source content dir (default: .qoder/repowiki/en/content).
//   <out-dir>    Destination build dir (required). Recreated fresh each run.
//
// Repository metadata (used for blob-URL rewriting and the sidebar title) is
// read from the environment so the same script works across SquadRules repos:
//   REPO_OWNER   GitHub org / user       (default: SquadRules)
//   REPO_NAME    Repository name         (default: containers)
//   REPO_BRANCH  Default branch          (default: main)
//   WIKI_TITLE     Short display title    (default: SQUADRULES CONTAINERS)
//   WIKI_TAGLINE One-line description used on the Home page.

import { promises as fs } from 'node:fs';
import path from 'node:path';

const REPO_OWNER = process.env.REPO_OWNER || 'SquadRules';
const REPO_NAME = process.env.REPO_NAME || 'containers';
const REPO_BRANCH = process.env.REPO_BRANCH || 'main';
const BLOB_BASE = `https://github.com/${REPO_OWNER}/${REPO_NAME}/blob/${REPO_BRANCH}/`;

const WIKI_TITLE = process.env.WIKI_TITLE || 'SQUADRULES CONTAINERS';
const WIKI_TAGLINE =
  process.env.WIKI_TAGLINE ||
  `Multi-arch, signed container image for the published @squadrules/mcp npm package, ` +
    `packaged in a pinned Debian base with an auto-bumping OS digest and expiring Trivy ignores.`;

const SOURCE_DIR = process.env.SOURCE_DIR || '.qoder/repowiki/en/content';
const OUT_DIR = process.argv[2] || process.env.OUT_DIR;

if (!OUT_DIR) {
  console.error('Error: output directory is required.');
  console.error('Usage: SOURCE_DIR=<dir> node scripts/build-wiki.mjs <out-dir>');
  process.exit(1);
}

// --- naming --------------------------------------------------------------

// GitHub Wiki keys page URLs by filename with spaces replaced by hyphens; other
// characters are preserved. Wrap link targets in <> so preserved characters
// (e.g. parentheses) never break Markdown link parsing.
function slug(pageName) {
  return pageName.replace(/ /g, '-');
}

function link(display, pageName) {
  return `[${display}](<${slug(pageName)}>)`;
}

// Full-path page name, collapsing a folder-index tail (".../X/X.md" -> ".../X").
// Path segments are unique, so the result is always collision-free.
function pageNameFor(relPathPosix) {
  const noExt = relPathPosix.replace(/\.md$/i, '');
  const segs = noExt.split('/');
  if (segs.length >= 2 && segs[segs.length - 1] === segs[segs.length - 2]) {
    segs.pop();
  }
  return segs.join(' - ');
}

// Move <cite> "Referenced Files" blocks from top to bottom of wiki pages.
function moveCiteToBottom(content) {
  const m = content.match(/<cite>\n\*\*Referenced Files in This Document\*\*[\s\S]*?<\/cite>\n*/);
  if (!m) return content;
  const inner = m[0].replace(/^<cite>\n/, '').replace(/\n?<\/cite>\n*$/, '');
  return content.replace(m[0], '').trimEnd() + '\n\n' + inner + '\n';
}

// Rewrite `[text](file://<repo-path>)` references to clickable GitHub blob URLs.
// Also converts "Referenced Files in This Document" sections from inline-link
// bullet lists into reference-style link lists so GitHub Wiki renders them
// correctly (inline links with long URLs often render as raw text on Wiki).
function rewriteSourceLinks(content) {
  // Step 1: replace file:// with blob URL
  let out = content.split('](file://').join(`](${BLOB_BASE}`);

  // Step 2: detect "Referenced Files in This Document" sections and convert
  // their inline-link bullet items to reference-style links.
  // These sections may be wrapped in <cite>...</cite> tags — strip those.
  const refSectionRe = /^(?:<cite>\n)?(\*\*Referenced Files in This Document\*\*)$/gm;
  const matches = [...out.matchAll(refSectionRe)];
  if (matches.length === 0) return out;

  // Process each section independently (in reverse order to preserve indices).
  for (const m of matches.reverse()) {
    const headingStartIdx = m.index;
    const startIdx = m.index + m[0].length; // after heading line
    // Skip the newline after the heading.
    const afterHeading = out[startIdx] === '\n' ? startIdx + 1 : startIdx;

    // Collect consecutive `- [label](url)` lines by splitting into lines.
    const remaining = out.substring(afterHeading);
    const lines = remaining.split('\n');
    const refs = [];
    let consumedLines = 0;
    const itemLineRe = /^- \[(.+?)\]\(([^)]+)\)$/;
    for (const line of lines) {
      const lm = line.match(itemLineRe);
      if (!lm) break;
      refs.push({ label: lm[1], url: lm[2] });
      consumedLines++;
    }
    if (refs.length === 0) continue;

    // Find end of section: check if </cite> follows the list items.
    const afterListIdx = afterHeading + lines.slice(0, consumedLines).join('\n').length;
    let endIdx = afterListIdx;
    if (out.startsWith('</cite>', endIdx)) {
      endIdx += '</cite>'.length;
      if (out[endIdx] === '\n') endIdx++;
    } else if (out[endIdx] === '\n') {
      endIdx++; // skip trailing newline after last list item
    }

    // Build replacement: heading + blank line + reference-style list + definitions.
    const heading = m[1];
    const listLines = refs.map((r, i) => `- [${r.label}][ref-${i}]`).join('\n');
    const defs = refs.map((r, i) => `[ref-${i}]: ${r.url}`).join('\n');
    const replacement = `${heading}\n\n${listLines}\n\n${defs}`;

    out = out.substring(0, headingStartIdx) + replacement + out.substring(endIdx);
  }

  return out;
}

// --- tree ----------------------------------------------------------------

// Load section ordering from Qoder RepoWiki metadata (single source of truth).
// The wiki_catalogs array order IS the logical display order.
// parent_id links children to parents; root items have no parent_id.
async function loadSectionOrder(sourceDir) {
  const metaPath = path.join(path.dirname(sourceDir), 'meta', 'repowiki-metadata.json');
  try {
    const meta = JSON.parse(await fs.readFile(metaPath, 'utf8'));
    const catalogs = meta.wiki_catalogs || [];
    // Build ordered children map: parentName -> [childName, ...]
    const childrenMap = new Map();
    const rootOrder = [];
    // Track position index for each catalog entry
    const positionMap = new Map();
    catalogs.forEach((c, idx) => positionMap.set(c.id, idx));
    // Group by parent
    for (const c of catalogs) {
      if (!c.parent_id) {
        rootOrder.push({ name: c.name, pos: positionMap.get(c.id) });
      } else {
        // Find parent name
        const parent = catalogs.find((p) => p.id === c.parent_id);
        if (parent) {
          const key = parent.name;
          if (!childrenMap.has(key)) childrenMap.set(key, []);
          childrenMap.get(key).push({ name: c.name, pos: positionMap.get(c.id) });
        }
      }
    }
    // Sort each children list by position
    for (const [, children] of childrenMap) {
      children.sort((a, b) => a.pos - b.pos);
    }
    rootOrder.sort((a, b) => a.pos - b.pos);
    return { rootOrder: rootOrder.map((r) => r.name), childrenMap };
  } catch {
    return { rootOrder: [], childrenMap: new Map() };
  }
}

function sortByName(items, orderList) {
  if (!orderList || orderList.length === 0) return items.sort((a, b) => a.localeCompare(b));
  const maxIdx = orderList.length;
  return items.sort((a, b) => {
    const ai = orderList.indexOf(a);
    const bi = orderList.indexOf(b);
    const aIdx = ai === -1 ? maxIdx : ai;
    const bIdx = bi === -1 ? maxIdx : bi;
    return aIdx - bIdx || a.localeCompare(b);
  });
}

// node: { name, indexPage, pages: [{display, pageName}], sections: [node] }
async function buildDir(absDir, relSegs, rootOrder, childrenMap) {
  const dirName = relSegs.length ? relSegs[relSegs.length - 1] : null;
  const node = { name: dirName, indexPage: null, pages: [], sections: [] };
  const entries = await fs.readdir(absDir, { withFileTypes: true });

  const mdFiles = entries
    .filter((e) => e.isFile() && e.name.toLowerCase().endsWith('.md'))
    .map((e) => e.name)
    .sort((a, b) => a.localeCompare(b));

  for (const file of mdFiles) {
    const base = file.replace(/\.md$/i, '');
    const relPath = [...relSegs, file].join('/');
    const pageName = pageNameFor(relPath);
    if (dirName && base === dirName) {
      node.indexPage = pageName; // section landing page
    } else {
      node.pages.push({ display: base, pageName, relPath });
    }
  }

  const subDirs = entries
    .filter((e) => e.isDirectory())
    .map((e) => e.name);

  // Apply logical order from metadata; fallback to alphabetical.
  const orderList = relSegs.length === 0 ? rootOrder : (childrenMap.get(dirName) || []).map((c) => c.name);
  sortByName(subDirs, orderList);

  for (const dir of subDirs) {
    node.sections.push(await buildDir(path.join(absDir, dir), [...relSegs, dir], rootOrder, childrenMap));
  }

  return node;
}

// Collect every emitted page (flat) from the tree, in write order.
function collectPages(node, acc) {
  if (node.indexPage) acc.push({ display: node.name, pageName: node.indexPage });
  for (const p of node.pages) acc.push(p);
  for (const s of node.sections) collectPages(s, acc);
  return acc;
}

// --- navigation rendering ------------------------------------------------

function renderSection(node, depth, lines, maxDepth) {
  const indent = '  '.repeat(depth);
  if (node.indexPage) {
    lines.push(`${indent}- ${link(node.name, node.indexPage)}`);
  } else {
    lines.push(`${indent}- **${node.name}**`);
  }

  const childIndent = '  '.repeat(depth + 1);
  for (const p of node.pages) {
    lines.push(`${childIndent}- ${link(p.display, p.pageName)}`);
  }
  for (const s of node.sections) {
    if (depth + 1 <= maxDepth) {
      renderSection(s, depth + 1, lines, maxDepth);
    } else if (s.indexPage) {
      lines.push(`${childIndent}- ${link(s.name, s.indexPage)}`);
    } else {
      lines.push(`${childIndent}- **${s.name}**`);
    }
  }
}

function renderRoot(root, maxDepth) {
  const lines = [];
  for (const s of root.sections) renderSection(s, 0, lines, maxDepth);
  for (const p of root.pages) lines.push(`- ${link(p.display, p.pageName)}`);
  return lines.join('\n');
}

function buildSidebar(root) {
  return [`### ${WIKI_TITLE}`, '', `- ${link('Home', 'Home')}`, '', renderRoot(root, Infinity), ''].join('\n');
}

function buildHome(root) {
  return [
    `# ${WIKI_TITLE} Wiki`,
    '',
    WIKI_TAGLINE,
    '',
    'This wiki is generated from the repository and published automatically —',
    'do not edit pages here by hand. Use the sidebar or the sections below to',
    'navigate.',
    '',
    '## Sections',
    '',
    renderRoot(root, 1),
    '',
  ].join('\n');
}

// --- main ----------------------------------------------------------------

async function main() {
  const sourceAbs = path.resolve(SOURCE_DIR);
  const outAbs = path.resolve(OUT_DIR);

  const stat = await fs.stat(sourceAbs).catch(() => null);
  if (!stat || !stat.isDirectory()) {
    console.error(`Error: source directory '${sourceAbs}' not found.`);
    process.exit(1);
  }

  const sectionOrder = await loadSectionOrder(sourceAbs);
  const root = await buildDir(sourceAbs, [], sectionOrder.rootOrder, sectionOrder.childrenMap);

  // Emit pages; assert global uniqueness (defensive — should never trigger).
  const pages = collectPages(root, []);
  const seen = new Map();
  for (const p of pages) {
    if (seen.has(p.pageName)) {
      console.error(`Error: duplicate page name '${p.pageName}'`);
      console.error(`  first : ${seen.get(p.pageName)}`);
      console.error(`  second: ${p.relPath ?? '(index)'}`);
      process.exit(1);
    }
    seen.set(p.pageName, p.relPath ?? '(index)');
  }

  await fs.rm(outAbs, { recursive: true, force: true });
  await fs.mkdir(outAbs, { recursive: true });

  let count = 0;
  const writeOne = async (pageName, relPath) => {
    const raw = await fs.readFile(path.join(sourceAbs, relPath), 'utf8');
    const moved = moveCiteToBottom(raw);
    await fs.writeFile(path.join(outAbs, `${pageName}.md`), rewriteSourceLinks(moved));
    count += 1;
  };

  // Re-walk to get relPath for index pages too.
  const writeTree = async (node, relSegs) => {
    if (node.indexPage) {
      await writeOne(node.indexPage, [...relSegs, `${node.name}.md`].join('/'));
    }
    for (const p of node.pages) await writeOne(p.pageName, p.relPath);
    for (const s of node.sections) await writeTree(s, [...relSegs, s.name]);
  };
  await writeTree(root, []);

  await fs.writeFile(path.join(outAbs, 'Home.md'), buildHome(root));
  await fs.writeFile(path.join(outAbs, '_Sidebar.md'), buildSidebar(root));

  console.log(`Built ${count} page(s) + Home + _Sidebar into ${outAbs}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
