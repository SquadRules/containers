#!/usr/bin/env python3
"""
Fail CI when .trivyignore contains expired or invalid exp:YYYY-MM-DD entries.
Warn for entries expiring soon.
"""

from datetime import date
from pathlib import Path
import argparse
import re
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--file",
        default=".trivyignore",
        help="Path to .trivyignore-like file",
    )
    parser.add_argument(
        "--warning-days",
        type=int,
        default=45,
        help="Warn when expiry is within this many days",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    path = Path(args.file)
    if not path.exists():
        print(f"::error::{args.file} not found")
        return 1

    today = date.today()
    lines = path.read_text(encoding="utf-8").splitlines()
    exp_re = re.compile(r"^\s*([A-Za-z0-9._-]+)\s+exp:(\d{4}-\d{2}-\d{2})\s*$")

    found = 0
    failures: list[str] = []
    warnings: list[str] = []

    for idx, line in enumerate(lines, start=1):
        match = exp_re.match(line)
        if not match:
            continue
        found += 1
        cve, exp_raw = match.groups()
        try:
            exp_date = date.fromisoformat(exp_raw)
        except ValueError:
            failures.append(f"line {idx}: {cve} has invalid date: {exp_raw}")
            continue

        days_left = (exp_date - today).days
        if days_left < 0:
            failures.append(f"line {idx}: {cve} expired {abs(days_left)} day(s) ago on {exp_raw}")
        elif days_left <= args.warning_days:
            warnings.append(f"line {idx}: {cve} expires in {days_left} day(s) on {exp_raw}")

    if found == 0:
        print(f"::warning::No exp:YYYY-MM-DD entries found in {args.file}")
        return 0

    for msg in warnings:
        print(f"::warning::{msg}")

    if failures:
        for msg in failures:
            print(f"::error::{msg}")
        print(f"::error::{args.file} contains {len(failures)} expired or invalid ignore entry(ies)")
        return 1

    if warnings:
        print(
            f"::warning::{args.file} has {len(warnings)} entry(ies) expiring within {args.warning_days} day(s)"
        )

    print(f"Validated {args.file} expiry metadata successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
