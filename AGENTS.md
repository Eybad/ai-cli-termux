# ai-cli-termux

CLI installer for Termux with glibc overlay or native binaries. Maintain the generic, fail-closed pipeline.

- Tool-specific behavior belongs in `registry/<tool>.conf`, `WRAPPER_ENV`, or hooks. Do not add per-tool conditionals to `install.sh` if a hook can solve it. `aicli` orchestrates; it does not duplicate installation or verification logic.
- Never install without a verified checksum. `release_digest`/`manifest` can resolve version and digest; `sha256.txt` is an optional pin there and a mandatory source for `hashfile`. Never omit `verify.sh`.
- `EXEC_DIRECT=true` requires `NEEDS_PATCHELF=false` and a natively compatible binary; the glibc overlay does not make arbitrary Linux binaries compatible. Preserve the `EXTRA_BINS` contract.
- Custom Android builds: pinned official source, integrity and compilation gates, separate distribution repo with digest/attestation. Revisions use `+androidN` and compare against manifest tags; do not simplify to bare SemVer core.
- `--resolve-version` prints strictly `TARGET_VERSION=<v>` to stdout, preserves `+build`, logs to stderr; no installation or persistent side effects. Incompatible arguments exit 2. `aicli list` degrades network failures to `n/a` without failing the listing.
- `aicli`: 0 success / 1 execution error / 2 usage; help/version to stdout; errors to stderr. Respect `NO_COLOR`, `TERM=dumb`, and non-TTY environments. Never overwrite `aicli` wrapper without the `aicli-managed` ownership mark. `DESCRIPTION` in `.conf` is a single line without internal quotes.
- Hooks are installer code: review and run `shellcheck` before testing.

## Verification

- Read relevant files and run `shellcheck install.sh verify.sh aicli registry/lib/*.sh registry/opencode.conf` according to scope. Never run `install.sh` as if it were a side-effect-free test.
- Installation, reinstallation, or update requires authorization within that scope. If not performed, state that integration was not executed; do not claim install/verify passed.
- Usage: `bash install.sh <tool> [-v X.Y.Z | --update | -r | -u]`; `bash verify.sh <tool>` verifies an existing installation. Do not habitually run all variants.
- Architecture, fields, and pipeline details: [technical reference](.agent-notes/20261026.md), `README.md`, and `docs/adr/`. Consult relevant contracts before modifying them. Historical notes do not override current code and evidence.

Technical decisions and contracts from `.agent-notes/20261026.md` remain part of project rules: consult the relevant section before modifying that subsystem. Historical test counts, progress states, and historical permissions require current verification and do not substitute for these rules or current global policy.

- Prefer portable POSIX constructs; do not add Bash 4+ specific features without strong justification, nor new dependencies without justification and Termux compatibility.
