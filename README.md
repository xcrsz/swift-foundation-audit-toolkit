# swift-foundation audit toolkit

A small set of scripts for auditing a Swift codebase against the
behavior changes introduced by the swift-foundation rewrite, with
particular attention to FreeBSD and GhostBSD targets.

## What's here

| Script | Covers | Language |
|--------|--------|----------|
| `scripts/scan-sources.sh` | Static pattern scan for migration risks | POSIX sh |
| `scripts/check-imports.sh` | FoundationEssentials right-sizing | POSIX sh |
| `scripts/json-roundtrip-diff.swift` | JSON encoder/decoder byte-diff vs golden | Swift |
| `scripts/filemanager-bsd-probe.swift` | FileManager BSD-specific behaviors | Swift |
| `scripts/url-parser-probe.swift` | URL stricter RFC 3986 conformance | Swift |
| `Makefile` | Orchestration and CI entry point | GNU/BSD make |

## Mapping to the assessment

Each script targets a specific risk category from the migration
assessment:

**Source-level compatibility risks (Objective-C runtime, identity
semantics, NSKeyedArchiver).** `scan-sources.sh` flags these with
severity tags. Run it first; it's the quickest filter.

**FoundationEssentials opportunity.** `check-imports.sh` classifies
each file by what Foundation subset it actually needs. Files tagged
`[ESSENTIALS]` are candidates for narrowing the import, which matters
for binary size on BSD base-system tools.

**JSON behavioral parity.** `json-roundtrip-diff.swift` exercises the
known edge cases (integer boundaries, key ordering, special characters,
double precision, non-conforming float strategies). Generate goldens
once on a build you trust, check them in, then verify in CI on each
target platform.

**FileManager behavior on BSD.** `filemanager-bsd-probe.swift` runs a
battery of probes against a scratch directory covering symlinks,
POSIX permissions, extended attributes, chflags, case-sensitivity,
`replaceItemAt`, directory listing determinism, and Process spawning.
Output is suitable for attaching to upstream bug reports.

**URL parser strictness.** `url-parser-probe.swift` tests a corpus of
historically-accepted-but-now-questionable URL strings. Accepts custom
input on stdin with `--stdin`, so you can pipe in URLs from your own
logs or persisted data.

## Quick start

    cd swift-foundation-audit
    make scan           # static source scan
    make imports        # right-size Foundation imports
    make fs-probe       # FileManager BSD probe
    make url-probe      # URL parser behavior
    make json-generate  # generate golden files (run on trusted build)
    make json-verify    # verify against golden files

Run everything:

    make all

CI-friendly (nonzero exit on any issue):

    make ci

## Recommended workflow

1. **Baseline.** On the current trusted build (macOS with shipping
   Foundation, or an older known-good Linux build), run:

       make scan imports > baseline-scan.txt
       make json-generate

   Commit `baseline-scan.txt` and the generated golden files
   (`audit-golden/json/`) to the repo.

2. **Target-platform probe.** On each target platform (GhostBSD,
   FreeBSD, Linux, whatever matters), run:

       make fs-probe > fs-probe-$(uname).txt
       make url-probe > url-probe-$(uname).txt

   Diff these across platforms. Differences are where swift-foundation
   is behaving differently under the hood.

3. **CI.** Add `make ci` to the CI pipeline for each target platform.
   Gate merges on a clean run once the baseline is stable.

4. **Iterate.** As you add new code that uses Foundation, re-run the
   scan. Treat `[AUDIT]` and `[WARN]` findings as review-required.

## Extending

The scripts are deliberately small and grep/Swift-based rather than
AST-based, so they're easy to extend. Add patterns to
`scan-sources.sh`, add test cases to `json-roundtrip-diff.swift`,
add probes to `filemanager-bsd-probe.swift`.

For heavier static analysis, consider integrating swift-syntax-based
lint rules; these shell and Swift scripts are intended as the
lightweight first line.

## Known limitations

- `scan-sources.sh` is grep-based; it will produce false positives
  for identifiers that happen to match patterns inside string literals
  or similar. Treat output as a starting point for review, not a
  verdict.

- `filemanager-bsd-probe.swift` uses `#if os(FreeBSD)` guards that
  require a Swift toolchain with FreeBSD support. On the current
  preview toolchains this works; earlier toolchains may need the
  conditional removed or the file rewritten using `canImport(Glibc)`
  as a coarse proxy.

- `json-roundtrip-diff.swift` compares byte-for-byte. If you don't
  use `.sortedKeys`, key ordering in `default` and `pretty` output
  may legitimately differ between runs even within a single
  implementation; in practice the new implementation is deterministic,
  but don't treat a diff there as automatically a bug.

- Extended attribute handling on FreeBSD uses `extattr_*` rather than
  `*xattr`; the probe currently marks this as `SKIP` on FreeBSD.
  Update as swift-foundation's API surface here stabilizes.
