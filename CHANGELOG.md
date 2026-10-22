# Changelog

## [1.2.0](https://github.com/SquadRules/containers/compare/v1.1.0...v1.2.0) (2026-10-22)


### Features

* add auto-update PR branches workflow ([#17](https://github.com/SquadRules/containers/issues/17)) ([f31ff3b](https://github.com/SquadRules/containers/commit/f31ff3babd724d85dad8f845da799d6d50060f3b))

## [1.1.0](https://github.com/SquadRules/containers/compare/v1.0.0...v1.1.0) (2026-10-22)


### Features

* content-addressable build fingerprint to skip redundant rebuilds ([#15](https://github.com/SquadRules/containers/issues/15)) ([77d2519](https://github.com/SquadRules/containers/commit/77d251997e257dccb3054fd0cbbc27460b02429d))

## 1.0.0 (2026-10-22)


### Features

* add push trigger for automatic image rebuilds ([#11](https://github.com/SquadRules/containers/issues/11)) ([e9dc64a](https://github.com/SquadRules/containers/commit/e9dc64aabe613a0da4c19f494e81b87ecb3e03e1))
* reset the image to a SIMPLE-by-default Node 24 runtime ([5c2f775](https://github.com/SquadRules/containers/commit/5c2f775952bef346d8a6e34f6a08353d09fefdbf))
* reset the image to a SIMPLE-by-default Node 24 runtime ([f6a53cb](https://github.com/SquadRules/containers/commit/f6a53cb7a41d55b0cc929adf039c23f5dff376e9))
* scaffold container image pipeline (built from published npm) ([4eeafb7](https://github.com/SquadRules/containers/commit/4eeafb7673ba7e3071b7bc83b4aba0cc1242cc7f))


### Bug Fixes

* **ci:** correct trivy SBOM output path for container-based action ([2df86ba](https://github.com/SquadRules/containers/commit/2df86ba02822975fa043babb44c10dfe52806dd7))
* **ci:** ensure .local/ exists before SBOM generation ([7df7635](https://github.com/SquadRules/containers/commit/7df763549006960e9757b8640b4f08ef18b88ed7))
* **ci:** export GHA cache runtime for buildx layer caching ([51c253d](https://github.com/SquadRules/containers/commit/51c253d13cb7fcad3429b6a75d8edbc769600933))
* **ci:** include hidden files in upload-artifact for .local/ paths ([d1b90df](https://github.com/SquadRules/containers/commit/d1b90df0ccd971b3f73790880be67e87f019f98e))
* **ci:** per-ref concurrency group with PR cancel-in-progress ([f6dd4fe](https://github.com/SquadRules/containers/commit/f6dd4fe0671c1541821422a684971bb2ff798b4f))
* **ci:** publish to each registry independently ([beb7528](https://github.com/SquadRules/containers/commit/beb752865021d320773765688a46e8a47c6a4831))
* **ci:** repair pipeline — dual-registry skip, arm64 timeout, daily cron ([d597b48](https://github.com/SquadRules/containers/commit/d597b48ca67ba78a49b70e8c8c738327c997c540))
* **ci:** replace arm64 full-boot smoke with native module load check ([7db590b](https://github.com/SquadRules/containers/commit/7db590bedbc4127d25012636553f1886185590f0))
* **containers:** default image to HTTP transport; fix smoke arg parser ([816adbe](https://github.com/SquadRules/containers/commit/816adbede92ad3467cc005a42cef95cb52381fa2))
* **containers:** raise arm64 smoke deadline for QEMU-emulated HTTP boot ([ffe30d9](https://github.com/SquadRules/containers/commit/ffe30d955c3211b2314a8e673626d18b053ac3c8))
