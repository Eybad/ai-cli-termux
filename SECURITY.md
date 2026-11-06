# Security Policy

## Scope

This repository provides the installer and manager CLI (`install.sh`, `verify.sh`, `aicli`), tool configurations (`registry/`), and CI/build workflows (`.github/workflows/`). The software binaries installed through this project are **third-party upstream artifacts**: this project does not compile them (with the exception of Codex, whose CI build compiles directly from OpenAI's official source code), and their security relies on the verification chain outlined below.

## Reporting a Vulnerability

- Report security issues **privately** via GitHub Security Advisories: navigate to the **Security → Report a vulnerability** tab of this repository. Please do not open public issues for active vulnerabilities.
- Include: affected version, description, reproduction steps, and a proposed patch if available.
- Response timeline: Initial triage within 7 business days. Security fixes are published alongside a GitHub Security Advisory (GHSA) when applicable.

## Trust Model & Supply Chain Security

- **Fail-closed checksums**: No binary or archive is installed without verified integrity. Checksum sources vary by tool (GitHub API asset digests, vendor JSON manifests, or manual pins in `sha256.txt`). Any mismatch immediately aborts the installation.
- **Attestation**: In-house CI builds (Codex) publish workflow attestations (Sigstore/SLSA v1); `install.sh` verifies them using `gh attestation verify` when provided.
- **Codex sandbox**: Defaults to `landlock`. On Android kernels without Landlock support, `sandbox_mode = "off"` in `~/.codex/config.toml` is documented as an acknowledged user risk.
- **Minimal attack surface**: The installer does not download or execute remote scripts; all repository code is audited with `verify.sh` post-installation and continuously checked in CI (ShellCheck + registry validation).

## Dependencies

- **GitHub Actions**: Pinned by immutable commit SHA (not mutable release tags) and kept up to date by Dependabot (`.github/dependabot.yml`).
- **Codex Build NDK**: Verified against Google's official SHA256 checksums.
- **Installed binaries**: Validated on every install or update against official upstream hashes.
