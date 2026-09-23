#!/usr/bin/env python3
# test-gen-codex-lock-patch.py — Tests del generador de locks (fixtures sintéticos).
#
# Corre sin red ni clone upstream: construye un árbol codex-rs mínimo y ejercita
# el generador por su interfaz (--src / --dist-version / --apply). Uso:
#   python3 scripts/test-gen-codex-lock-patch.py

import importlib.util
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "gen_codex_lock_patch", HERE / "gen-codex-lock-patch.py"
)
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

CARGO = """[workspace]
members = ["alpha", "beta", "gamma"]

[workspace.package]
version = "0.1.0"
"""

ALPHA_LIB = """pub fn a() {
    let lock_file = std::fs::File::open("x")?;
    lock_file.try_lock()?;
    lock_file.try_lock()?;
    let file = std::fs::File::open("y")?;
    file.lock()?;
    Ok(())
}
"""

ALPHA_OTHER = """pub fn b() {
    let file = std::fs::File::open("z")?;
    file.try_lock_shared()?;
    Ok(())
}
"""

BETA_LIB = """pub fn c() {
    let file = std::fs::File::open("w")?;
    file.try_lock()?;
    Ok(())
}
"""

BETA_NESTED = """pub fn d() {
    let file = std::fs::File::open("v")?;
    self.file.try_lock()?;
    Ok(())
}
"""

GAMMA_MAIN = """fn main() {
    let file = std::fs::File::open("u")?;
    file.lock()?;
    Ok(())
}
"""

INVENTORY_FIXTURE = {
    "alpha/src/lib.rs": {("lock_file", "try_lock"): 2, ("file", "lock"): 1},
    "alpha/src/other.rs": {("file", "try_lock_shared"): 1},
    "beta/src/lib.rs": {("file", "try_lock"): 1},
    "beta/src/deep/nested.rs": {("self.file", "try_lock"): 1},
    "gamma/src/main.rs": {("file", "lock"): 1},
}


def build_tree(root: Path):
    root.mkdir(parents=True)
    (root / "Cargo.toml").write_text(CARGO)
    (root / "alpha/src").mkdir(parents=True)
    (root / "alpha/src/lib.rs").write_text(ALPHA_LIB)
    (root / "alpha/src/other.rs").write_text(ALPHA_OTHER)
    (root / "beta/src/deep").mkdir(parents=True)
    (root / "beta/src/lib.rs").write_text(BETA_LIB)
    (root / "beta/src/deep/nested.rs").write_text(BETA_NESTED)
    (root / "gamma/src").mkdir(parents=True)
    (root / "gamma/src/main.rs").write_text(GAMMA_MAIN)


class TestScan(unittest.TestCase):
    def test_scan_finds_all_sites(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            sites = gen.scan_sites(root)
            self.assertEqual(len(sites), 7)
            by_rel = {}
            for rel, recv, method in sites:
                by_rel.setdefault(rel, []).append((recv, method))
            self.assertEqual(by_rel["beta/src/deep/nested.rs"], [("self.file", "try_lock")])
            self.assertEqual(by_rel["alpha/src/lib.rs"].count(("lock_file", "try_lock")), 2)

    def test_comment_skipped(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            lib = root / "alpha/src/lib.rs"
            lib.write_text(lib.read_text() + "\n// file.try_lock()\n")
            sites = gen.scan_sites(root)
            self.assertEqual(len(sites), 7)  # el comentario no suma

    def test_trailing_comment_skipped(self):
        # Un call site dentro de un comentario trailing no se escanea ni se
        # reescribe (el `//` corta la línea fuera de strings).
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            lib = root / "alpha/src/lib.rs"
            lib.write_text(
                lib.read_text()
                + '\n    let file = std::fs::File::open("q")?; // file.try_lock()\n'
            )
            sites = gen.scan_sites(root)
            self.assertEqual(len(sites), 7)  # el trailing no suma
            old = gen.INVENTORY
            gen.INVENTORY = INVENTORY_FIXTURE
            try:
                gen.main(["--apply", "--src", str(root), "--dist-version", "0.1.0+android1"])
                text = (root / "alpha/src/lib.rs").read_text()
                # el comentario quedó intacto y el call real fue reemplazado
                self.assertIn("// file.try_lock()", text)
                self.assertIn("crate::file_lock_shim::lock(&file)?;", text)
            finally:
                gen.INVENTORY = old


class TestVerify(unittest.TestCase):
    def test_verify_clean(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            old = gen.INVENTORY
            gen.INVENTORY = INVENTORY_FIXTURE
            try:
                problems, _ = gen.verify_inventory(root)
                self.assertEqual(problems, [])
            finally:
                gen.INVENTORY = old

    def test_verify_drift_reports_proposed(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            old = gen.INVENTORY
            gen.INVENTORY = {"alpha/src/lib.rs": {("lock_file", "try_lock"): 1}}  # mal
            try:
                problems, scanned = gen.verify_inventory(root)
                self.assertTrue(problems)
                proposed = gen.proposed_inventory(scanned)
                ns = {}
                exec(proposed, ns)  # el propuesto debe ser parseable
                self.assertEqual(ns["INVENTORY"], INVENTORY_FIXTURE)
            finally:
                gen.INVENTORY = old

    def test_verify_mode_reports_drift(self):
        # Sin --apply, una deriva también reporta el inventario propuesto
        # (exit 1, sin modificar nada).
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            old = gen.INVENTORY
            gen.INVENTORY = {"alpha/src/lib.rs": {("lock_file", "try_lock"): 1}}  # mal
            try:
                rc = gen.main(["--src", str(root), "--dist-version", "0.1.0+android1"])
                self.assertEqual(rc, 1)
                # el árbol quedó intacto
                self.assertIn("file.try_lock()", (root / "beta/src/lib.rs").read_text())
            finally:
                gen.INVENTORY = old


class TestApply(unittest.TestCase):
    def test_apply_end_to_end(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            old = gen.INVENTORY
            gen.INVENTORY = INVENTORY_FIXTURE
            try:
                gen.main(["--apply", "--src", str(root), "--dist-version", "0.1.0+android1"])
                # call sites reemplazados (forma exacta: sin paréntesis huérfanos)
                beta_lib = (root / "beta/src/lib.rs").read_text()
                self.assertIn(
                    "crate::file_lock_shim::try_lock(&file)?;",
                    beta_lib,
                )
                self.assertNotIn("))?", beta_lib)
                self.assertNotIn("file.try_lock()", beta_lib)
                self.assertIn(
                    "crate::file_lock_shim::try_lock(&self.file)?;",
                    (root / "beta/src/deep/nested.rs").read_text(),
                )
                # shims en los crate roots derivados (incluye main.rs de gamma)
                for root_file in ("alpha/src/lib.rs", "beta/src/lib.rs", "gamma/src/main.rs"):
                    self.assertIn("mod file_lock_shim", (root / root_file).read_text())
                # versión bumpada
                self.assertIn('version = "0.1.0+android1"', (root / "Cargo.toml").read_text())
                # idempotencia: segunda corrida no toca nada (árbol intacto)
                before = {
                    p.relative_to(root): p.read_bytes()
                    for p in root.rglob("*")
                    if p.is_file()
                }
                gen.main(["--apply", "--src", str(root), "--dist-version", "0.1.0+android1"])
                after = {
                    p.relative_to(root): p.read_bytes()
                    for p in root.rglob("*")
                    if p.is_file()
                }
                self.assertEqual(before, after)
            finally:
                gen.INVENTORY = old

    def test_apply_substring_collision(self):
        # lock_file.try_lock() y file.try_lock() en el mismo archivo: el receiver
        # corto no debe corromper al largo (lock_crate::...).
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            lib = root / "alpha/src/lib.rs"
            lib.write_text(
                lib.read_text()
                + '\n    let file = std::fs::File::open("q")?;\n    file.try_lock()?;\n'
            )
            old = gen.INVENTORY
            gen.INVENTORY = dict(INVENTORY_FIXTURE)
            gen.INVENTORY["alpha/src/lib.rs"] = {
                ("lock_file", "try_lock"): 2,
                ("file", "lock"): 1,
                ("file", "try_lock"): 1,
            }
            try:
                gen.main(["--apply", "--src", str(root), "--dist-version", "0.1.0+android1"])
                text = (root / "alpha/src/lib.rs").read_text()
                self.assertNotIn("lock_crate::", text)
                self.assertNotIn("))?", text)
                self.assertIn("crate::file_lock_shim::try_lock(&lock_file)?;", text)
                self.assertIn("crate::file_lock_shim::try_lock(&file)?;", text)
            finally:
                gen.INVENTORY = old

    def test_drift_aborts(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            old = gen.INVENTORY
            gen.INVENTORY = {
                "alpha/src/lib.rs": {("lock_file", "try_lock"): 2, ("file", "lock"): 1}
            }  # faltan beta y gamma
            try:
                with self.assertRaises(SystemExit):
                    gen.main(["--apply", "--src", str(root), "--dist-version", "0.1.0+android1"])
            finally:
                gen.INVENTORY = old


if __name__ == "__main__":
    unittest.main(verbosity=2)