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
#   2. Reemplaza los 17 call sites conocidos por crate::file_lock_shim::{...}(&file),
#      preservando `?`, `match` y `map_err` de cada llamada.
#      (El prefijo crate:: es obligatorio: desde Rust 1.96 los paths no
#      calificados hacia módulos del crate root ya no resuelven desde submódulos
#      anidados — E0433 —; ver docs/adr/0001-release-scheme.md.)
#   3. Bump de [workspace.package] version → <core>+<build> (--dist-version).
#
# Fail-closed: si el source difiere del inventario esperado (sitio faltante o
# nuevo), aborta con un informe y no deja un árbol a medio parchear.
#
# Uso:
#   gen-codex-lock-patch.py --src <codex-rs> --dist-version <X.Y.Z+BUILD> [--apply]
#
# Sin --apply solo verifica el estado (0 = ya parcheado completo, 1 = no).

import argparse
import re
import sys
from pathlib import Path

# ── Inventario esperado de call sites (archivo relativo a codex-rs/, línea 1-based) ──
# Fuente: escaneo exhaustivo de codex-rust-v0.146.0 (17 sitios en 10 archivos).
# Si el source upstream cambia cualquiera de estos, el generador aborta.
INVENTORY = [
    ("arg0/src/lib.rs", 380, "lock_file", "try_lock"),
    ("arg0/src/lib.rs", 513, "lock_file", "try_lock"),
    ("arg0/src/lib.rs", 731, "lock_file", "try_lock"),
    ("app-server-transport/src/transport/unix_socket.rs", 151, "file", "lock"),
    ("core/src/installation_id.rs", 32, "file", "lock"),
    ("execpolicy/src/amend.rs", 157, "file", "lock"),
    ("message-history/src/lib.rs", 163, "history_file", "try_lock"),
    ("message-history/src/lib.rs", 385, "file", "try_lock_shared"),
    ("message-history/src/batch.rs", 124, "file", "try_lock_shared"),
    ("network-proxy/src/certs.rs", 532, "file", "lock_shared"),
    ("network-proxy/src/certs.rs", 540, "file", "lock"),
    ("network-proxy/src/certs.rs", 633, "lock_file", "try_lock"),
    ("rmcp-client/src/oauth/refresh_lock.rs", 72, "file", "try_lock"),
    ("rmcp-client/src/oauth/store_lock.rs", 94, "file", "try_lock"),
    ("thread-store/src/local/writer_lock.rs", 64, "file", "try_lock"),
    ("thread-store/src/local/writer_lock.rs", 109, "file", "lock"),
    ("thread-store/src/local/writer_lock.rs", 143, "file", "try_lock"),
]

# Crate root donde se inserta `mod file_shim` por cada archivo con call sites.
CRATE_ROOTS = {
    "arg0/src/lib.rs",
    "app-server-transport/src/lib.rs",
    "core/src/lib.rs",
    "execpolicy/src/lib.rs",
    "message-history/src/lib.rs",
    "network-proxy/src/lib.rs",
    "rmcp-client/src/lib.rs",
    "thread-store/src/lib.rs",
}

METHODS = ("try_lock", "lock", "lock_shared", "try_lock_shared")

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
SITE_RE = re.compile(r"\b\w*file\w*\.(try_lock|lock|lock_shared|try_lock_shared)\(")


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


def workspace_version_core(src: Path) -> str:
    """Núcleo X.Y.Z de la versión del workspace (sin build metadata)."""
    return workspace_version(src).split("+", 1)[0]


def scan_sites(src: Path):
    """Todos los call sites de receiver file-like en el árbol (fuera de comentarios)."""
    sites = []
    for p in sorted(src.rglob("*.rs")):
        if "target" in p.parts:
            continue
        for i, line in enumerate(read_lines(p), start=1):
            if is_comment(line):
                continue
            for m in SITE_RE.finditer(line):
                sites.append((str(p.relative_to(src)), i, m.group(0)))
    return sites


def verify_inventory(src: Path):
    """Cada sitio esperado debe estar presente textualmente en su línea exacta."""
    missing = []
    for rel, lineno, recv, method in INVENTORY:
        p = src / rel
        if not p.is_file():
            missing.append(f"{rel}: archivo faltante")
            continue
        lines = read_lines(p)
        if lineno > len(lines):
            missing.append(f"{rel}:{lineno}: archivo más corto que el inventario")
            continue
        needle = f"{recv}.{method}()"
        if needle not in lines[lineno - 1]:
            missing.append(f"{rel}:{lineno}: no contiene '{needle}'")
    return missing


def apply_replacements(src: Path):
    """Reemplaza cada call site en su línea exacta (fail-closed si algo difiere)."""
    for rel, lineno, recv, method in INVENTORY:
        p = src / rel
        lines = read_lines(p)
        needle = f"{recv}.{method}()"
        replacement = f"crate::file_lock_shim::{method}(&{recv})"
        line = lines[lineno - 1]
        if line.count(needle) != 1:
            raise SystemExit(
                f"ERROR: {rel}:{lineno}: '{needle}' aparece {line.count(needle)} veces "
                f"(esperado 1); el inventario no coincide con el source"
            )
        lines[lineno - 1] = line.replace(needle, replacement)
        write_lines(p, lines)


def insert_shim(src: Path):
    for root in sorted(CRATE_ROOTS):
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


def main():
    ap = argparse.ArgumentParser(
        description="Generador del parche de locks de archivo para Android (File::lock* en codex)"
    )
    ap.add_argument("--src", required=True, help="directorio raíz de codex-rs (contiene Cargo.toml)")
    ap.add_argument("--dist-version", required=True, help="versión del dist, ej: 0.146.0+android1")
    ap.add_argument("--apply", action="store_true", help="modificar el source (default: solo verificar)")
    args = ap.parse_args()

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

    # Estado ya-parcheado (idempotencia): shim en todos los crate roots + versión con build.
    already = (
        all(Path(src / r).is_file() and "mod file_lock_shim" in (Path(src / r).read_text(encoding="utf-8"))
            for r in CRATE_ROOTS)
        and "+" in full_version
    )

    if not args.apply:
        if already:
            print(f"OK: source ya parcheado (versión {full_version})")
            return 0
        print(f"INFO: source sin parchear (versión {core})")
        return 1

    if already:
        print(f"OK: source ya parcheado (versión {full_version}); nada que hacer")
        return 0

    missing = verify_inventory(src)
    if missing:
        print("ERROR: el source no coincide con el inventario esperado:", file=sys.stderr)
        for m in missing:
            print(f"  - {m}", file=sys.stderr)
        raise SystemExit(1)

    new_sites = scan_sites(src)
    known = {(rel, line) for rel, line, _, _ in INVENTORY}
    unknown = [s for s in new_sites if (s[0], s[1]) not in known]
    if unknown:
        print("ERROR: call sites nuevos no contemplados en el inventario (fail-closed):",
              file=sys.stderr)
        for rel, line, text in unknown:
            print(f"  - {rel}:{line}: {text}", file=sys.stderr)
        print("Actualizá INVENTORY/CRATE_ROOTS del generador tras revisarlos.", file=sys.stderr)
        raise SystemExit(1)

    insert_shim(src)
    apply_replacements(src)
    bump_version(src, args.dist_version)

    # Post-checks (fail-closed: si algo quedó sin parchear, abortar).
    remaining = scan_sites(src)
    if remaining:
        print("ERROR: post-check fallido, quedan call sites activos:", file=sys.stderr)
        for rel, line, text in remaining:
            print(f"  - {rel}:{line}: {text}", file=sys.stderr)
        raise SystemExit(1)
    if workspace_version(src) != args.dist_version:
        raise SystemExit(f"ERROR: post-check: versión no bumpada a {args.dist_version}")
    for root in sorted(CRATE_ROOTS):
        if "mod file_lock_shim" not in (src / root).read_text(encoding="utf-8"):
            raise SystemExit(f"ERROR: post-check: shim ausente en {root}")

    print(f"OK: parche aplicado — 17 call sites → crate::file_lock_shim, versión {args.dist_version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
