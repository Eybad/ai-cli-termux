# Codex: instruction cache on Android aarch64

The generated `bionic_compat.c` leaves `__clear_cache` undefined. The workflow
extracts `clear_cache.c.o` from compiler-rt, bundled in the NDK whose checksum
it already verifies, and archives it into `libbionic_compat.a`. This resolves
V8's reference using the standalone NDK implementation. No external
implementation is downloaded and no dependency is added. Synchronization remains
active.

Explicit inclusion is required because Rust links with `-nodefaultlibs`: relying
on libraries Clang adds by default is not enough. The static archive path
embeds its SHA-256 digest and is passed in `RUSTFLAGS`. Changing the shim or the
cache object alters those flags and invalidates cached Cargo artifacts, forcing
a rebuild.

The previous wrapper called `__builtin___clear_cache` and defined `__clear_cache`
as an alias of the wrapper itself. On aarch64 the builtin emits a call to that
symbol, causing infinite recursion until `SIGSEGV`. A regex such as `/a|b/` or
`/[ab]/` hits that path when generating native code in V8.

Primary references:

- [Clang runtime and compiler-rt linking](https://clang.llvm.org/docs/Toolchain.html#compiler-runtime).
- [`__clear_cache` implementation in LLVM 17](https://github.com/llvm/llvm-project/blob/llvmorg-17.0.2/compiler-rt/lib/builtins/clear_cache.c).

## Build gates

The Android job compiles `scripts/codex-clear-cache-probe.c` with the same
`libbionic_compat.a` archive and NDK linker used for the build. The probe
generates and overwrites AArch64 code 128 times, flushes the cache, and checks
the executed value. It alternates RW and RX pages; RWX pages are not required.

On Ubuntu, the probe is compiled and inspected rather than executed as a Linux
binary. `scripts/check-codex-clear-cache.py` inspects the extracted compiler-rt
object, the probe, and the linked Android host before packaging. It rejects
`__clear_cache` definitions in the shim, the old alias, unresolved symbols,
calls out of the cache implementation, and missing expected AArch64 compiler-rt
instructions (`mrs ctr_el0`, `dc cvau`, `ic ivau`, `dsb ish`, `isb`). A
legitimate change in compiler-rt may require updating this gate; the build fails
until reviewed. These static checks alone do not prove that the Android host
executes regexes properly.

The amd64 job runs `scripts/smoke-codex-code-mode.py` against the verified musl
host. The client opens synthetic sessions with no tools enabled, runs both
regexes separately, and requires a final result of `true`, no error, and process
exit code 0. `execution/started` alone does not count as success. Reading and
shutdown are bounded by timeouts. Client unit tests run in CI with
`python3 scripts/test-codex-code-mode-smoke.py`.

## Pending native verification per Android build

With the probe and fixed host available on Termux, run:

```sh
./codex-clear-cache-probe
python3 scripts/smoke-codex-code-mode.py ./stage/codex-code-mode-host
```

The host must have its companion libraries alongside the executable and the
`RUNPATH` configured by the workflow. Use the fixed bundle in a temporary
directory; there is no need to install it or replace the current installation
to test it. The probe must be the one linked against the shim from the same
build.

A passing amd64 smoke test does not validate Android execution. Testing the
probe locally with Termux Clang also does not substitute for compiling with the
pinned NDK or running the full Android host. Record those pieces of evidence
separately. Publishing and installing still require authorization; a re-release
preserves checksums, attestation, and bumps the `+androidN` revision.

## Validation build in GitHub Actions

Manual dispatch uses `publish=false` by default: it builds both architectures
without publishing a release. Scheduled cron runs retain automatic publishing.
To rebuild an already distributed version, pick a new `patch_rev` revision; the
idempotency gate continues to prevent overwriting existing releases.

The run produces `codex-arm64`, `codex-amd64`, and `validation-arm64`. The
latter contains the probe from the same build for native execution on Termux.
It is not part of the distribution assets. An existing installation is not
required to test the executables extracted from the artifact.

## Build evidence for 0.166.0+android2

Date: 2026-11-05.

- Run: [41960828923](https://github.com/Eybad/ai-cli-termux/actions/runs/41960828923),
  attempt 1, completed successfully.
- Workflow commit: `94953d56872b6bc6b2126839b56a841a63a2d4b9`.
- Pinned upstream source: `6ff1e1ca3b30fc8b914720681fcf5fe62e95f856`.
- NDK r26d: checksum verified by the workflow. Inspection of the compiler-rt
  object, the probe, and the linked Android host passed.
- The amd64 job completed both regexes with result `true` and exit code 0.
- `publish=false`: the release job was skipped.

ZIP SHA-256 checksums reported by the Actions API:

| Artifact | SHA256 |
|---|---|
| `codex-arm64` | `109fccfe50ee7df01b1e397d4270395f0b340fb198a773d14d01bcfbce271777` |
| `validation-arm64` | `465313de0156fc84004aa84cfda1f457e289b0c9a3433eb0bbbcdeff9ade3654` |

The Android job log reports SHA-256 for the `codex-arm64.tar.gz` tarball:
`6e2f2e1127af95901b626dffaad10b27b61a5098badb289aa3eedb3ec73b3a01`.

The probe download verified its ZIP against the Actions digest before
extraction. The run's probe successfully executed 128 code replacements on
Android aarch64/Termux and exited with 0.

The Android ZIP download verified its SHA-256 against the Actions digest and the
extracted tarball matched the build log SHA-256 before extracting and running
binaries. A transfer interruption was recovered via an HTTP Range request; final
verification covered the complete file.

The bundle extracted in a Termux temporary directory reported
`codex-cli 0.166.0+android2`. The native host smoke test returned:

```text
PASS: text(/a|b/.test("alpha"));
PASS: text(/[ab]/.test("alpha"));
```

Each regex ran in a synthetic session with no tools enabled, returning final
result `true`, no execution error, and host exit code 0. This test covers both
reproductions that caused `SIGSEGV` in the previously installed build. It does
not validate all Codex flows, MCP, or prolonged usage.

The current distribution was neither installed nor replaced, user configuration
was not modified, and no release was published. Unrelated OpenCode changes and
temporary documents in the main checkout remained untouched.
