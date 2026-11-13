#!/usr/bin/env python3
# std::fs::File::{try_,}{lock,lock_shared} return Unsupported on Android (rust-lang/rust#148325).
# Rewrites call sites to flock(2) shims and bumps version.

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

INVENTORY = {
    "app-server-transport/src/transport/unix_socket.rs": {("file", "lock"): 1, ("file", "try_lock"): 1, ("self._file", "try_lock"): 1},
    "arg0/src/lib.rs": {("lock_file", "try_lock"): 3},
    "core/src/installation_id.rs": {("file", "lock"): 1},
    "execpolicy/src/amend.rs": {("file", "lock"): 1},
    "file-system/src/local_logs.rs": {("directory", "try_lock_shared"): 1},
    "login/src/oauth_session_storage.rs": {("file", "try_lock"): 1},
    "message-history/src/batch.rs": {("file", "try_lock_shared"): 1},
    "message-history/src/lib.rs": {("file", "try_lock_shared"): 1, ("history_file", "try_lock"): 1},
    "network-proxy/src/certs.rs": {("file", "lock"): 1, ("file", "lock_shared"): 1, ("lock_file", "try_lock"): 1},
    "rmcp-client/src/oauth/refresh_lock.rs": {("file", "try_lock"): 1},
    "rmcp-client/src/oauth/store_lock.rs": {("file", "try_lock"): 1, ("file", "try_lock_shared"): 1},
    "rollout/src/maintenance.rs": {("file", "try_lock"): 1},
    "rollout/src/writer_lock.rs": {("file", "lock"): 1, ("file", "try_lock"): 3},
    "tui/src/bottom_pane/mention_usage.rs": {("lock_file", "try_lock"): 1},
    "user-verification/src/lifecycle_lock.rs": {("file", "try_lock"): 1},
    "windows-sandbox-rs/tests/support/src/lib.rs": {("file", "lock"): 1},
}

METHODS = ("try_lock", "lock", "lock_shared", "try_lock_shared")

MIN_DYNAMIC_SITES = 10

# Receivers holding std::fs::File that elude SITE_RE's (file|dir) name hint
# (0.169.0 rollout/src/writer_lock_tests.rs opens a File as `opening`).
# Pinned per file on purpose: any other receiver or file still fails the
# leak gate closed.
EXPLICIT_FILE_RECEIVERS = {
    "rollout/src/writer_lock_tests.rs": ("opening", "coordination"),
}

SITE_RE = re.compile(r"\b((?:[\w]+\.)*\w*(?:file|dir)\w*)\.(try_lock|lock|lock_shared|try_lock_shared)\(")

EXCLUSIVE_FILE_LOCK_RE = re.compile(r"\b((?:[\w]+\.)*\w+)\.(lock_shared|try_lock_shared)\(")
FILE_HINT_RE = re.compile(r"\b(File|OpenOptions|NamedTempFile|tempfile|as_file)\b")
ANY_LOCK_RE = re.compile(r"\b((?:[\w]+\.)*\w+)\.(lock|try_lock)\(")


def strip_line_comment(line: str) -> str:
    """Strip line at the first `//` outside string literals."""
    in_str = False
    i = 0
    while i < len(line) - 1:
        c = line[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c == "/" and line[i + 1] == "/":
                return line[:i]
        i += 1
    return line

SHIM = """// Injected by scripts/gen-codex-lock-patch.py. Provides flock(2) shim on Android (rust-lang/rust#148325).
#[allow(dead_code)]
mod file_lock_shim {
    #[cfg(target_os = "android")]
    const LOCK_SH: i32 = 1;
    #[cfg(target_os = "android")]
    const LOCK_EX: i32 = 2;
    #[cfg(target_os = "android")]
    const LOCK_NB: i32 = 4;
    // EAGAIN == EWOULDBLOCK == 11 on Linux/Android ABI.
    #[cfg(target_os = "android")]
    const EWOULDBLOCK: i32 = 11;

    #[cfg(target_os = "android")]
    unsafe extern "C" {
        fn flock(fd: i32, operation: i32) -> i32;
    }

    #[cfg(target_os = "android")]
    fn flock_block_impl(file: &std::fs::File, operation: i32) -> std::io::Result<()> {
        use std::os::fd::AsRawFd;
        let rc = unsafe { flock(file.as_raw_fd(), operation) };
        if rc == 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error())
        }
    }

    #[cfg(target_os = "android")]
    fn flock_try_impl(file: &std::fs::File, operation: i32) -> Result<(), std::fs::TryLockError> {
        use std::os::fd::AsRawFd;
        let rc = unsafe { flock(file.as_raw_fd(), operation) };
        if rc == 0 {
            return Ok(());
        }
        let err = std::io::Error::last_os_error();
        match err.raw_os_error() {
            Some(EWOULDBLOCK) => Err(std::fs::TryLockError::WouldBlock),
            _ => Err(std::fs::TryLockError::Error(err)),
        }
    }

    #[cfg(not(target_os = "android"))]
    fn std_lock(f: &std::fs::File) -> std::io::Result<()> {
        f.lock()
    }
    #[cfg(not(target_os = "android"))]
    fn std_lock_shared(f: &std::fs::File) -> std::io::Result<()> {
        f.lock_shared()
    }
    #[cfg(not(target_os = "android"))]
    fn std_try_lock(f: &std::fs::File) -> Result<(), std::fs::TryLockError> {
        f.try_lock()
    }
    #[cfg(not(target_os = "android"))]
    fn std_try_lock_shared(f: &std::fs::File) -> Result<(), std::fs::TryLockError> {
        f.try_lock_shared()
    }

    pub fn lock(file: &std::fs::File) -> std::io::Result<()> {
        #[cfg(target_os = "android")]
        {
            flock_block_impl(file, LOCK_EX)
        }
        #[cfg(not(target_os = "android"))]
        {
            std_lock(file)
        }
    }

    pub fn lock_shared(file: &std::fs::File) -> std::io::Result<()> {
        #[cfg(target_os = "android")]
        {
            flock_block_impl(file, LOCK_SH)
        }
        #[cfg(not(target_os = "android"))]
        {
            std_lock_shared(file)
        }
    }

    pub fn try_lock(file: &std::fs::File) -> Result<(), std::fs::TryLockError> {
        #[cfg(target_os = "android")]
        {
            flock_try_impl(file, LOCK_EX | LOCK_NB)
        }
        #[cfg(not(target_os = "android"))]
        {
            std_try_lock(file)
        }
    }

    pub fn try_lock_shared(file: &std::fs::File) -> Result<(), std::fs::TryLockError> {
        #[cfg(target_os = "android")]
        {
            flock_try_impl(file, LOCK_SH | LOCK_NB)
        }
        #[cfg(not(target_os = "android"))]
        {
            std_try_lock_shared(file)
        }
    }
}
"""

CORE_RE = re.compile(r"^version\s*=\s*\"([0-9]+\.[0-9]+\.[0-9]+(?:\+[0-9A-Za-z._-]+)?)\"\s*$")
DIST_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+\+[0-9A-Za-z._-]+$")


def is_comment(line: str) -> bool:
    t = line.strip()
    return t.startswith("//") or t.startswith("/*") or t.startswith("*") or t.startswith("#")


def read_lines(path: Path):
    return path.read_text(encoding="utf-8").splitlines()


def write_lines(path: Path, lines):
    text = "\n".join(lines) + "\n"
    path.write_text(text, encoding="utf-8")


def workspace_version(src: Path) -> str:
    """Return root workspace version from Cargo.toml."""
    cargo = src / "Cargo.toml"
    lines = read_lines(cargo)
    in_workspace = False
    for i, line in enumerate(lines):
        if line.startswith("["):
            in_workspace = line.strip() == "[workspace.package]"
            continue
        if not in_workspace:
            continue
        m = CORE_RE.match(line)
        if m:
            return m.group(1)
    raise SystemExit(f"ERROR: [workspace.package] version no encontrado en {cargo}")


def explicit_receiver_pattern(rel: str):
    """Return pattern for a file's allowlisted File receivers."""
    recv_alt = "|".join(map(re.escape, EXPLICIT_FILE_RECEIVERS[rel]))
    return re.compile(
        rf"(?<!\.)(?<!::)\b({recv_alt})\s*\.\s*({'|'.join(METHODS)})\s*\(\s*\)"
    )


def _scan_block_comment(text: str, start: int) -> int:
    i = start + 2
    n = len(text)
    depth = 1
    while i < n and depth > 0:
        if text[i] == "/" and i + 1 < n and text[i + 1] == "*":
            depth += 1
            i += 2
        elif text[i] == "*" and i + 1 < n and text[i + 1] == "/":
            depth -= 1
            i += 2
        else:
            i += 1
    return i


def _scan_raw_string(text: str, start: int):
    if start > 0 and (text[start - 1].isalnum() or text[start - 1] == "_"):
        return None
    n = len(text)
    if text[start] == "r":
        j = start + 1
    elif text[start] in ("b", "c") and start + 1 < n and text[start + 1] == "r":
        j = start + 2
    else:
        return None
    hashes = 0
    while j < n and text[j] == "#":
        hashes += 1
        j += 1
    if j >= n or text[j] != '"':
        return None
    closing = '"' + "#" * hashes
    end = text.find(closing, j + 1)
    return n if end == -1 else end + len(closing)


def _scan_quoted_string(text: str, start: int) -> int:
    i = start + 1
    n = len(text)
    while i < n:
        if text[i] == "\\":
            i += 2
        elif text[i] == '"':
            return i + 1
        else:
            i += 1
    return n


def _scan_char_literal(text: str, start: int):
    # Match only closed char literals so Rust lifetimes ('a, 'static) stay intact.
    n = len(text)
    if start + 2 < n and text[start + 1] not in ("'", "\\", "\n", "\r") and text[start + 2] == "'":
        return start + 3
    if start + 1 >= n or text[start + 1] != "\\":
        return None
    k = start + 2
    if k >= n:
        return None
    if text[k] == "u" and k + 1 < n and text[k + 1] == "{":
        k += 2
        while k < n and text[k] not in ("}", "'", "\n", "\r"):
            k += 1
        if k + 1 < n and text[k] == "}" and text[k + 1] == "'":
            return k + 2
        return None
    if text[k] == "x" and k + 3 < n and text[k + 3] == "'":
        return k + 4
    if text[k] in ("n", "r", "t", "0", "\\", "'", '"') and k + 1 < n and text[k + 1] == "'":
        return k + 2
    return None


def _append_masked(out, span: str):
    out.extend("\n" if ch == "\n" else " " for ch in span)


def mask_rust_non_code(text: str) -> str:
    """Replace Rust comments, strings, and char literals with spaces, preserving newlines."""
    out = []
    n = len(text)
    i = 0
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            end = text.find("\n", i + 2)
            end = n if end == -1 else end
            _append_masked(out, text[i:end])
            i = end
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            end = _scan_block_comment(text, i)
            _append_masked(out, text[i:end])
            i = end
            continue
        if c in ("r", "b", "c"):
            end = _scan_raw_string(text, i)
            if end is not None:
                _append_masked(out, text[i:end])
                i = end
                continue
        if c == '"':
            end = _scan_quoted_string(text, i)
            _append_masked(out, text[i:end])
            i = end
            continue
        if c == "'":
            end = _scan_char_literal(text, i)
            if end is not None:
                _append_masked(out, text[i:end])
                i = end
                continue
        out.append(c)
        i += 1
    return "".join(out)


def scan_explicit_sites(src: Path, rel: str):
    """Sites on allowlisted receivers, including calls wrapped across lines.

    Masks comments, strings, and char literals so non-code text never counts
    as a site; apply_explicit_replacements later fails closed if raw matches
    differ.
    """
    p = src / rel
    if not p.is_file():
        return []
    lines = []
    for line in read_lines(p):
        if "mod file_lock_shim" in line:
            break
        lines.append(line)
    masked = mask_rust_non_code("\n".join(lines))
    pattern = explicit_receiver_pattern(rel)
    return [(rel, m.group(1), m.group(2)) for m in pattern.finditer(masked)]


def scan_sites(src: Path):
    """Scan call sites (rel_path, receiver, method) outside comments and shims."""
    sites = []
    for p in sorted(src.rglob("*.rs")):
        if "target" in p.parts:
            continue
        rel = str(p.relative_to(src))
        allowed = EXPLICIT_FILE_RECEIVERS.get(rel, ())
        if allowed:
            sites.extend(scan_explicit_sites(src, rel))
        in_shim = False
        for i, line in enumerate(read_lines(p), start=1):
            if "mod file_lock_shim" in line:
                in_shim = True
            if in_shim or is_comment(line):
                continue
            if "lock" not in line:
                continue
            clean = strip_line_comment(line)
            for m in SITE_RE.finditer(clean):
                if m.group(1) in allowed:
                    continue
                sites.append((rel, m.group(1), m.group(2)))
    return sites


def site_multiset(sites):
    """Return multiset of (receiver, method) per file."""
    per_file = {}
    for rel, recv, method in sites:
        per_file.setdefault(rel, Counter())[(recv, method)] += 1
    return per_file


def verify_inventory(src: Path):
    """Compare scanned sites against INVENTORY."""
    scanned = site_multiset(scan_sites(src))
    problems = []
    for rel, pairs in INVENTORY.items():
        got = scanned.get(rel)
        if got is None:
            problems.append(f"{rel}: archivo sin call sites (esperado {dict(pairs)})")
            continue
        for key, expected in pairs.items():
            actual = got.get(key, 0)
            if actual != expected:
                problems.append(
                    f"{rel}: {key[0]}.{key[1]}() esperado {expected}, obtenido {actual}"
                )
    for rel, pairs in scanned.items():
        expected = INVENTORY.get(rel)
        if expected is None:
            problems.append(f"{rel}: call sites nuevos no contemplados ({dict(pairs)})")
        else:
            for key, count in pairs.items():
                if key not in expected:
                    problems.append(f"{rel}: par nuevo ({key[0]}, {key[1]}) ×{count}")
    return problems, scanned


def proposed_inventory(scanned) -> str:
    """Format proposed INVENTORY literal."""
    lines = ["INVENTORY = {"]
    for rel in sorted(scanned):
        pairs = ", ".join(
            f'("{r}", "{m}"): {c}' for (r, m), c in sorted(scanned[rel].items())
        )
        lines.append(f'    "{rel}": {{{pairs}}},')
    lines.append("}")
    return "\n".join(lines)


def check_call_site_leaks(src: Path):
    """Detect file lock calls with receivers unhandled by SITE_RE."""
    leaks = []
    for p in sorted(src.rglob("*.rs")):
        if "target" in p.parts:
            continue
        rel = str(p.relative_to(src))
        allowed = EXPLICIT_FILE_RECEIVERS.get(rel, ())
        in_shim = False
        for line_no, line in enumerate(read_lines(p), start=1):
            if "mod file_lock_shim" in line:
                in_shim = True
            if in_shim or is_comment(line):
                continue
            clean = strip_line_comment(line)
            if not clean or "lock" not in clean:
                continue
            for m in EXCLUSIVE_FILE_LOCK_RE.finditer(clean):
                recv = m.group(1)
                method = m.group(2)
                if recv in allowed:
                    continue
                if not re.search(r"(?:file|dir)", recv, re.IGNORECASE):
                    leaks.append(
                        f"{rel}:{line_no}: llamada a {recv}.{method}() elude SITE_RE (método exclusivo de File)"
                    )
            if FILE_HINT_RE.search(clean):
                for m in ANY_LOCK_RE.finditer(clean):
                    recv = m.group(1)
                    method = m.group(2)
                    if recv in allowed:
                        continue
                    if not re.search(r"(?:file|dir)", recv, re.IGNORECASE):
                        leaks.append(
                            f"{rel}:{line_no}: posible lock de archivo con receiver '{recv}' que elude SITE_RE ({method})"
                        )
    return leaks


def derive_crate_roots(src: Path, site_files):
    """Find crate roots for call site files."""
    roots = set()
    for rel in site_files:
        d = (src / rel).parent
        while True:
            found = None
            for root_name in ("lib.rs", "main.rs"):
                if (d / root_name).is_file():
                    found = f"{d.relative_to(src)}/{root_name}"
                    break
            if found:
                roots.add(found)
                break
            if d == src:
                raise SystemExit(f"ERROR: crate root no encontrado para {rel}")
            d = d.parent
    return roots


def apply_explicit_replacements(p: Path, rel: str, expected: int):
    """Rewrite allowlisted-receiver sites on raw text and return the count.

    Raw matches must equal the non-code-masked count: a receiver appearing
    in a comment or string would rewrite prose, so fail closed instead.
    """
    pattern = explicit_receiver_pattern(rel)
    raw = p.read_text(encoding="utf-8")
    raw_matches = len(pattern.findall(raw))
    if raw_matches != expected:
        raise SystemExit(
            f"ERROR: {rel}: {raw_matches} matches crudos contra "
            f"{expected} limpios; receiver permitido en comentario o string"
        )

    def repl(m):
        return f"crate::file_lock_shim::{m.group(2)}(&{m.group(1)})"

    p.write_text(pattern.sub(repl, raw), encoding="utf-8")
    return expected


def apply_replacements(src: Path, sites):
    """Replace (receiver, method) pairs with file_lock_shim calls."""
    by_file = {}
    for rel, recv, method in sites:
        by_file.setdefault(rel, []).append((recv, method))
    for rel, pairs in by_file.items():
        p = src / rel
        allowed = EXPLICIT_FILE_RECEIVERS.get(rel, ())
        explicit_pairs = Counter((r, m) for r, m in pairs if r in allowed)
        line_pairs = [pair for pair in set(pairs) if pair[0] not in allowed]
        total = 0
        if explicit_pairs:
            total += apply_explicit_replacements(p, rel, sum(explicit_pairs.values()))
        lines = None
        if line_pairs:
            lines = read_lines(p)
            ordered = sorted(line_pairs, key=lambda r: len(r[0]), reverse=True)
            alts = []
            for i, (recv, method) in enumerate(ordered):
                alts.append(f"(?P<r{i}>{re.escape(recv)})\\.(?P<m{i}>{method})\\(\\)")
            pattern = re.compile(r"\b(?:" + "|".join(alts) + ")")

            def repl(m):
                for i, (recv, method) in enumerate(ordered):
                    if m.group(f"r{i}") is not None:
                        return f"crate::file_lock_shim::{method}(&{recv})"
                raise AssertionError("unreachable alternation match")

            for i, line in enumerate(lines):
                if is_comment(line):
                    continue
                if "lock" not in line:
                    continue
                prefix = strip_line_comment(line)
                if prefix == line:
                    new_line, n = pattern.subn(repl, line)
                else:
                    new_line, n = pattern.subn(repl, prefix)
                    new_line += line[len(prefix):]
                if n:
                    lines[i] = new_line
                    total += n
        expected = sum(c for _, c in Counter(pairs).items())
        if total != expected:
            raise SystemExit(
                f"ERROR: {rel}: se reemplazaron {total} call sites, esperado {expected}"
            )
        if lines is not None:
            write_lines(p, lines)


def insert_shim(src: Path, roots):
    for root in sorted(roots):
        p = src / root
        if not p.is_file():
            raise SystemExit(f"ERROR: crate root faltante: {root}")
        lines = read_lines(p)
        if any("mod file_lock_shim" in l for l in lines):
            raise SystemExit(f"ERROR: {root} ya contiene 'mod file_lock_shim'; source a medio parchear")
        text = p.read_text(encoding="utf-8")
        if not text.endswith("\n"):
            text += "\n"
        p.write_text(text + "\n" + SHIM, encoding="utf-8")


def bump_version(src: Path, dist_version: str):
    cargo = src / "Cargo.toml"
    lines = read_lines(cargo)
    in_workspace = False
    done = False
    for i, line in enumerate(lines):
        if line.startswith("["):
            in_workspace = line.strip() == "[workspace.package]"
            continue
        if not in_workspace:
            continue
        m = CORE_RE.match(line)
        if m:
            lines[i] = line.replace(m.group(1), dist_version)
            done = True
            break
    if not done:
        raise SystemExit(f"ERROR: [workspace.package] version no encontrado en {cargo}")
    write_lines(cargo, lines)


def has_shim(src: Path) -> bool:
    """Check if any source file contains file_lock_shim."""
    for p in src.rglob("*.rs"):
        if "target" in p.parts:
            continue
        if "mod file_lock_shim" in p.read_text(encoding="utf-8"):
            return True
    return False


def report_drift(problems, scanned):
    print("ERROR: el source no coincide con el inventario esperado:", file=sys.stderr)
    for pr in problems:
        print(f"  - {pr}", file=sys.stderr)
    print("\nInventario propuesto (revisar y pegar en INVENTORY):", file=sys.stderr)
    print(proposed_inventory(scanned), file=sys.stderr)


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Generador del parche de locks de archivo para Android (File::lock* en codex)"
    )
    ap.add_argument("--src", required=True, help="directorio raíz de codex-rs (contiene Cargo.toml)")
    ap.add_argument("--dist-version", required=True, help="versión del dist, ej: 0.146.0+android1")
    ap.add_argument("--apply", action="store_true", help="modificar el source (default: solo verificar)")
    ap.add_argument(
        "--dynamic",
        action="store_true",
        help="parchea dinámicamente según call sites escaneados con gates de integridad en vez de inventario estático",
    )
    args = ap.parse_args(argv)

    src = Path(args.src).resolve()
    if not (src / "Cargo.toml").is_file():
        raise SystemExit(f"ERROR: --src no es un directorio codex-rs: {src}")
    if not DIST_RE.match(args.dist_version):
        raise SystemExit(
            f"ERROR: --dist-version inválido: '{args.dist_version}' "
            f"(esperado X.Y.Z+BUILD, ej: 0.146.0+android1)"
        )

    full_version = workspace_version(src)
    core = full_version.split("+", 1)[0]
    dist_core = args.dist_version.split("+", 1)[0]
    if core != dist_core:
        raise SystemExit(
            f"ERROR: [workspace.package] version={core} no coincide con el núcleo de "
            f"--dist-version ({dist_core}); el tag upstream no está sincronizado con el "
            f"Cargo.toml del workspace"
        )

    sites = scan_sites(src)
    already = ("+" in full_version) and not sites and has_shim(src)

    if already:
        msg = f"OK: source ya parcheado (versión {full_version})"
        if args.apply:
            msg += "; nada que hacer"
        print(msg)
        return 0

    if args.dynamic:
        leaks = check_call_site_leaks(src)
        if leaks:
            print("ERROR: gate de fugas fallido, call sites eluden SITE_RE:", file=sys.stderr)
            for lk in leaks:
                print(f"  - {lk}", file=sys.stderr)
            raise SystemExit(1)
        if len(sites) < MIN_DYNAMIC_SITES:
            raise SystemExit(
                f"ERROR: gate de sanidad fallido: solo se detectaron {len(sites)} call sites "
                f"(mínimo esperado: {MIN_DYNAMIC_SITES})"
            )
        problems, scanned = verify_inventory(src)
        if problems:
            print(
                "INFO: modo dinámico detectó deriva respecto a INVENTORY "
                "(tolerada por gates de integridad):",
                file=sys.stderr,
            )
            for pr in problems:
                print(f"  - {pr}", file=sys.stderr)
        if not args.apply:
            print(f"INFO: modo dinámico verificado ({len(sites)} call sites válidos, versión {core})")
            return 0
    else:
        problems, scanned = verify_inventory(src)
        if problems:
            report_drift(problems, scanned)
            if not args.apply:
                return 1
            raise SystemExit(1)
        if not args.apply:
            print(f"INFO: source sin parchear (versión {core})")
            return 1

    roots = derive_crate_roots(src, [s[0] for s in sites])
    insert_shim(src, roots)
    apply_replacements(src, sites)
    bump_version(src, args.dist_version)

    remaining = scan_sites(src)
    if remaining:
        print("ERROR: post-check fallido, quedan call sites activos:", file=sys.stderr)
        for rel, recv, method in remaining:
            print(f"  - {rel}: {recv}.{method}()", file=sys.stderr)
        raise SystemExit(1)
    if workspace_version(src) != args.dist_version:
        raise SystemExit(f"ERROR: post-check: versión no bumpada a {args.dist_version}")
    for root in sorted(roots):
        if "mod file_lock_shim" not in (src / root).read_text(encoding="utf-8"):
            raise SystemExit(f"ERROR: post-check: shim ausente en {root}")

    print(f"OK: parche aplicado — {len(sites)} call sites → crate::file_lock_shim, versión {args.dist_version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())