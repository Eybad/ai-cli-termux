# Changelog

All notable changes to ai-cli-termux are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Automated CI** (`.github/workflows/ci.yml`): Strict ShellCheck on `install.sh`/`verify.sh`/`aicli`, ShellCheck on `registry/*.conf` and `registry/lib/*.sh`, Python syntax checks on generators/patch scripts, and declarative validation of registries (mandatory fields + EXEC_DIRECT/EXTRA_BINS/ENTRY_POINT/ALIASES/RELEASE_SOURCE invariants). Runs on push to main and PRs.
- **`registry/lib/shims.sh`**: Shared helpers for `pre_wrapper_hook` (`tool_shims_reset`, `tool_browser_shims`, `tool_clipboard_shims`). codex/agy source this shared library instead of duplicating ~200 lines; identical logic (marker-based ownership, pre-ownership migration, FIFO-safe guards, reset-before-append contract with fail-safe).
- **`aicli update --all`**: Sequentially updates all installed CLIs (manifest present); failures do not abort remaining tools, reflected in exit code (0 all succeeded, 1 on any failure). `AICLI_VERSION` bumped to 1.3.0. Bash, Zsh, and Fish completions updated.
- **Dependabot** (`.github/dependabot.yml`, weekly github-actions) to refresh action pins by SHA, and **SECURITY.md** (private reporting channel + supply chain trust model).

### Removed

- **`kiro-cli`**, **`cursor-agent`**, **`copilot`**: Removed from registry and active project support.
- **`update-hashes.yml` workflow**: Hash updates via CI were manual and redundant (API digests + attestations are already automated and fail-closed). `sha256.txt` remains as the mandatory source for `hashfile` tools and optional pinning for others, with inline documentation. Removed optional pin for `opencode/v1.18.9`.

### Changed

- `install.sh`: `curl` uses `--retry 3 --retry-delay 2 --retry-all-errors` on downloads and API/manifest fetches to protect against transient network failures.
- Error message for unpinned `url_template` versions now directs to `sha256.txt` documentation instead of the removed workflow.
- `registry/opencode.conf`: Header note updated to reflect glibc loader mode (`NEEDS_PATCHELF=false`).
- `registry/opencode.conf`: Attestation disabled (`ATTEST_PREDICATE=""`). Releases are published by `opencode-agent[bot]` with a dotcom certificate SAN (`dotcom.releases.github.com`), which `gh attestation verify --repo` rejects due to requiring an Actions workflow identity. Integrity relies on the GitHub API SHA256 digest.

## [1.3.0] - 2026-08-09

### Fixed

- **codex: Code tool SIGSEGV (`code-mode host closed its stdout`) on file operations**. The `bionic_compat` shim for `mprotect`/`madvise` in CI aligned fractional page boundaries expansively (floor to ceil); destructive operations (`PROT_NONE`, `MADV_DONTNEED`) on fractional V8 ranges revoked entire pages with live data, leading to SIGSEGV on subsequent access. Destructive operations are now non-expansive: applied strictly to pages completely contained within the requested range (`ceil(addr)`..`floor(addr+len)`), with fractional ranges treated as successful no-ops. Additive calls (`PROT_READ|PROT_WRITE|PROT_EXEC`) remain expansive. Published in release `v0.147.0+android5`.
- **codex workflow**: Host nm verification switched to `readelf -sW` to avoid NDK `nm` false negatives on shim symbols.

## [1.2.0] - 2026-08-06

### Added

- **`aicli` manager**: Unified CLI front-end over `install.sh` and `verify.sh`. Subcommands: `install`/`update`/`remove`/`verify` (pure delegation), `list` (local manifest state + update checks in parallel with per-tool timeouts; UPDATE column: yes/no/n/a; `--offline`, `--json`, tool filtering; always exit 0), `help` (general, subcommand, and tool-specific), `doctor` (repo, arch, deps, wrapper, glibc loader, tools), `completion <bash|zsh|fish>` (stdout with dynamic tool discovery), and `self-install`/`self-update` (registers wrapper in `$PREFIX/bin` with ownership marker `aicli-managed: ai-cli-termux`, fail-closed: never overwrites foreign binaries). Standard exit codes (0 success, 1 runtime error, 2 usage), `--version`, `--no-color`, respects `NO_COLOR`/`TERM=dumb`/no-TTY, and typo suggestions.
- `install.sh --resolve-version`: Internal machine interface printing `TARGET_VERSION=<v>` (without `v`, preserving `+build`) to stdout; logs directed to stderr via fd 1 redirection; side-effect free (no `check_current`, does not modify `$PREFIX`); incompatible with `-u`/`-r`/`--update`/`-v`/`--sha256` (exit 2). Consumed by `aicli list`.
- Optional single-line `DESCRIPTION` in `registry/*.conf` powering `aicli help <tool>` and `aicli list`.
- Dynamic shell completions including all active tools from the registry.

## [1.1.0] - 2026-08-05

> [!NOTE]
> Version 1.1.0 was rolled into the v1.2.0 release tag.

### Added

- Added Cursor Agent CLI (`cursor-agent`) via Cursor CDN (`url_template` + manual pin in `sha256.txt`). Embedded node bundle patched for glibc overlay, `ENTRY_POINT` launcher, managed `agent` alias, blocked self-updater, `EXTRA_BINS` for `cursorsandbox`/`crepectl`, and browser/DNS shims for OAuth flow.
- `ENTRY_POINT` in `install.sh`: Allows primary wrapper to execute a bundle script instead of an ELF binary (fail-closed validation with trap rollback).
- `ALIASES` in `install.sh`: Managed symlinks for wrappers with collision checks and ownership guards on uninstall; verified in step 8.1 of `verify.sh`.
- `latest_hashfile_version` supports prereleases and build metadata (`2026.07.23-e383d2b`, `0.146.0+android1`).

### Fixed

- `patchelf` 0.19.1 corrupted non-PIE ELFs when combining `--set-interpreter` and `--set-rpath` in a single invocation. Step 10 of `install.sh` now splits patching into two separate invocations (rpath then interpreter).
- Preflight hardening: Restricted charset `[a-zA-Z0-9._-]` for naming fields and rejection of quotes/`$`/backticks in `DISPLAY_NAME`.
- Rollback on failed upgrades restores the previous version wrapper.
- Cleanup on failed fresh installs removes hook shims and temporary aliases.
- Explicit tool ownership markers (`# termux-shim: <tool>`) in shims prevent cross-tool collisions during uninstallation.
- Rejection of `.`/`..` path tokens and control characters (0x01-0x1f, 0x7f) across naming variables.
- `verify.sh`: Emits `extra_bins` warnings only if `EXTRA_BINS` is defined in `.conf` but missing from the manifest.

## [1.0.0] - 2026-08-01

### Added

- Generic installer for AI CLIs on Termux without PRoot: `install.sh` supporting tool selection, specific versions (`-v`), `--update`, reinstall (`-r`), and uninstall (`-u`).
- Post-installation auditor (`verify.sh`): Validates binary integrity, checksums, wrappers, loader configuration, and runtime execution.
- Automated fail-closed checksums: GitHub API asset digests (`release_digest`) or vendor JSON manifests (`manifest`); optional pinning in `sha256.txt`.
- Initial supported tools: OpenCode (glibc loader invocation), Antigravity CLI (VA39 adaptive patch, libc shim, cgo DNS), Kiro CLI (patched Bun runtime, `EXTRA_BINS`), Codex (custom CI build).
- Custom CI build pattern for Codex: Bionic Android compilation in GitHub Actions with SLSA attestations.
- `EXEC_DIRECT`: Direct execution for native binaries bypassing the glibc overlay.
- Browser and clipboard shims for OAuth workflows in Termux (`xdg-open` → `termux-open-url`).
