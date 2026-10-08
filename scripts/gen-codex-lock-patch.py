#!/usr/bin/env python3
# gen-codex-lock-patch.py — Generador del parche de locks de archivo para Android.
#
# std::fs::File::{try_,}{lock,lock_shared}() devuelven io::ErrorKind::Unsupported
# en Android desde Rust 1.89 (flock no se usa en esa plataforma; ver
# rust-lang/rust#148325). Este script reescribe el source de codex-rs de forma
# determinista y fail-closed:
#
#   1. Inserta el módulo `file_lock_shim` en el crate root de cada crate con
#      call sites (delega en std fuera de Android; usa flock(2) directo en
#      Android, mapeando EWOULDBLOCK a std::fs::TryLockError::WouldBlock).
#   2. Reemplaza todos los call sites por crate::file_lock_shim::{...}(&recv),
#      preservando `?`, `match` y `map_err` de cada llamada.
#      (El prefijo crate:: es obligatorio: desde Rust 1.96 los paths no
#      calificados hacia módulos del crate root ya no resuelven desde submódulos
#      anidados — E0433 —; ver docs/adr/0001-release-scheme.md.)
#   3. Bump de [workspace.package] version → <core>+<build> (--dist-version).
#
# Inventario semántico (sin números de línea): INVENTORY es un multiset por
# archivo de pares (receiver, método). El generador ubica cada par por
# contenido y verifica que el multiset escaneado coincida exactamente. Un
# desplazamiento de líneas en el source upstream NO rompe el inventario; una
# deriva semántica (par nuevo, par removido, cantidad distinta, archivo nuevo)
# aborta con el inventario propuesto listo para revisar y pegar.
#
# Fail-closed: si el source difiere del inventario esperado, aborta con un
# informe y no deja un árbol a medio parchear.
#
# Uso:
#   gen-codex-lock-patch.py --src <codex-rs> --dist-version <X.Y.Z+BUILD> [--apply]
#
# Sin --apply solo verifica el estado (0 = ya parcheado completo, 1 = no).

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

# ── Inventario esperado de call sites (archivo relativo a codex-rs/) ──
# Formato: {archivo: {(receiver, método): cantidad}}. Sin números de línea: el
# generador ubica cada par por contenido y verifica el multiset completo.
# Fuente: escaneo exhaustivo de codex-rs v0.161.0 (23 sitios en 14 archivos).
INVENTORY = {
    "arg0/src/lib.rs": {("lock_file", "try_lock"): 3},
    "app-server-transport/src/transport/unix_socket.rs": {("file", "lock"): 1},
    "core/src/installation_id.rs": {("file", "lock"): 1},
    "execpolicy/src/amend.rs": {("file", "lock"): 1},
    "login/src/gateway_auth_storage.rs": {("file", "try_lock"): 1},
    "message-history/src/batch.rs": {("file", "try_lock_shared"): 1},
    "message-history/src/lib.rs": {("history_file", "try_lock"): 1, ("file", "try_lock_shared"): 1},
    "network-proxy/src/certs.rs": {("file", "lock_shared"): 1, ("file", "lock"): 1, ("lock_file", "try_lock"): 1},
    "rmcp-client/src/oauth/refresh_lock.rs": {("file", "try_lock"): 1},
    "rmcp-client/src/oauth/store_lock.rs": {("file", "try_lock_shared"): 1, ("file", "try_lock"): 1},
    "rollout/src/maintenance.rs": {("file", "try_lock"): 1},
    "rollout/src/writer_lock.rs": {("file", "try_lock"): 3, ("file", "lock"): 1},
    "user-verification/src/lifecycle_lock.rs": {("file", "try_lock"): 1},
    "windows-sandbox-rs/tests/support/src/lib.rs": {("file", "lock"): 1},
}

METHODS = ("try_lock", "lock", "lock_shared", "try_lock_shared")

# Receiver: cadena punteada cuyo último identificador contiene "file" (heurística
# que limita el escaneo a receivers tipo archivo; el compilador es el gate final
# para receivers que no sean std::fs::File). Exige la llamada completa `()` en
# una línea: un call site multi-línea no se escanea → verify_inventory aborta
# ANTES de modificar el árbol (fail-closed, sin árbol a medio parchear).
SITE_RE = re.compile(r"\b((?:[\w]+\.)*\w*file\w*)\.(try_lock|lock|lock_shared|try_lock_shared)\(")


def strip_line_comment(line: str) -> str:
    """Corta la línea en el primer `//` fuera de un string literal.

    Un comentario trailing (`x = file.lock()?; // file.try_lock()`) no debe
    contarse como call site ni reescribirse. Los `/* */` en línea propia ya los
    descarta is_comment; un bloque `/* */` inline no se maneja (upstream usa
    `//`; un miss aborta fail-closed por conteo).
    """
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

SHIM = """// ─────────────────────────────────────────────────────────────────────────
// file_lock_shim: compatibilidad Android para File::{try_,}{lock,lock_shared}
//
// Generado por scripts/gen-codex-lock-patch.py (repo ai-cli-termux). No editar.
//
// std::fs::File::lock* / try_lock* devuelven io::ErrorKind::Unsupported en
// android (flock no se usa en esa plataforma; rust-lang/rust#148325). Este
// módulo usa flock(2) directo en android (bionic lo expone como libc::flock,
// soportado y sin dependencias) replicando la semántica de std:
//   - lock / lock_shared: bloqueante (LOCK_EX / LOCK_SH)
//   - try_lock / try_lock_shared: no bloqueante (| LOCK_NB), EWOULDBLOCK
//     mapeado a std::fs::TryLockError::WouldBlock (igual que std)
// En plataformas no-android delega en std (comportamiento original).
// El CI compila solo para android; la rama no-android se valida por inspección.
// ─────────────────────────────────────────────────────────────────────────
#[allow(dead_code)]  // cada crate usa un subconjunto de los cuatro métodos
mod file_lock_shim {
    #[cfg(target_os = "android")]
    const LOCK_SH: i32 = 1; // flock(2): shared lock
    #[cfg(target_os = "android")]
    const LOCK_EX: i32 = 2; // flock(2): exclusive lock
    #[cfg(target_os = "android")]
    const LOCK_NB: i32 = 4; // flock(2): non-blocking
    // EAGAIN == EWOULDBLOCK == 11 en Linux/Android (constante ABI estable).
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

    /// Bloquea el archivo con lock exclusivo.
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

    /// Bloquea el archivo con lock compartido.
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

    /// Intenta un lock exclusivo no bloqueante (WouldBlock si está tomado).
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

    /// Intenta un lock compartido no bloqueante (WouldBlock si está tomado).
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
    """Versión de [workspace.package] del Cargo.toml raíz (fail-closed si falta)."""
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


def scan_sites(src: Path):
    """Todos los call sites (rel, receiver, method) fuera de comentarios."""
    sites = []
    for p in sorted(src.rglob("*.rs")):
        if "target" in p.parts:
            continue
        for i, line in enumerate(read_lines(p), start=1):
            if is_comment(line):
                continue
            # Pre-filtro barato: SITE_RE exige receiver con "file" y método con
            # "lock"; sin ambos substrings la línea no puede matchear (evita el
            # regex sobre miles de líneas irrelevantes).
            if "file" not in line or "lock" not in line:
                continue
            for m in SITE_RE.finditer(strip_line_comment(line)):
                sites.append((str(p.relative_to(src)), m.group(1), m.group(2)))
    return sites


def site_multiset(sites):
    """Multiset por archivo de (receiver, method)."""
    per_file = {}
    for rel, recv, method in sites:
        per_file.setdefault(rel, Counter())[(recv, method)] += 1
    return per_file


def verify_inventory(src: Path):
    """Compara el multiset escaneado contra INVENTORY; devuelve (problemas, escaneado)."""
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
    """Inventario propuesto como literal Python (revisar y pegar en INVENTORY)."""
    lines = ["INVENTORY = {"]
    for rel in sorted(scanned):
        pairs = ", ".join(
            f'("{r}", "{m}"): {c}' for (r, m), c in sorted(scanned[rel].items())
        )
        lines.append(f'    "{rel}": {{{pairs}}},')
    lines.append("}")
    return "\n".join(lines)


def derive_crate_roots(src: Path, site_files):
    """Crate root de cada archivo con call sites: sube hasta src/lib.rs o src/main.rs."""
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


def apply_replacements(src: Path, sites):
    """Reemplaza todas las ocurrencias de cada par (receiver, method) por el shim.

    Alternación longest-first con \b: evita que un receiver corto (file)
    corrompa uno largo (lock_file, self.file) por substring. El patrón consume
    la llamada completa `recv.method()` (ambos paréntesis) y el reemplazo
    produce `crate::file_lock_shim::method(&recv)`: el `?`/`match`/`map_err`
    que sigue a la llamada queda intacto.
    """
    by_file = {}
    for rel, recv, method in sites:
        by_file.setdefault(rel, []).append((recv, method))
    for rel, pairs in by_file.items():
        p = src / rel
        lines = read_lines(p)
        ordered = sorted(set(pairs), key=lambda r: len(r[0]), reverse=True)
        alts = []
        for i, (recv, method) in enumerate(ordered):
            alts.append(f"(?P<r{i}>{re.escape(recv)})\\.(?P<m{i}>{method})\\(\\)")
        pattern = re.compile(r"\b(?:" + "|".join(alts) + ")")

        def repl(m):
            for i, (recv, method) in enumerate(ordered):
                if m.group(f"r{i}") is not None:
                    return f"crate::file_lock_shim::{method}(&{recv})"
            raise AssertionError("alternación sin match")  # inalcanzable

        total = 0
        for i, line in enumerate(lines):
            if is_comment(line):
                continue
            if "file" not in line or "lock" not in line:
                continue
            prefix = strip_line_comment(line)
            if prefix == line:
                new_line, n = pattern.subn(repl, line)
            else:
                # Comentario trailing: reemplazar solo en el prefijo real.
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
    """¿Algún .rs del árbol contiene el shim? (gate de idempotencia)."""
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
    # Estado ya-parcheado (idempotencia): versión con +build, sin call sites
    # activos y con el shim presente en el árbol (gate equivalente al del
    # generador anterior: shim en todos los crate roots).
    already = ("+" in full_version) and not sites and has_shim(src)

    if not args.apply:
        if already:
            print(f"OK: source ya parcheado (versión {full_version})")
            return 0
        problems, scanned = verify_inventory(src)
        if problems:
            report_drift(problems, scanned)
            return 1
        print(f"INFO: source sin parchear (versión {core})")
        return 1

    if already:
        print(f"OK: source ya parcheado (versión {full_version}); nada que hacer")
        return 0

    problems, scanned = verify_inventory(src)
    if problems:
        report_drift(problems, scanned)
        raise SystemExit(1)

    roots = derive_crate_roots(src, [s[0] for s in sites])
    insert_shim(src, roots)
    apply_replacements(src, sites)
    bump_version(src, args.dist_version)

    # Post-checks (fail-closed: si algo quedó sin parchear, abortar).
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