#!/usr/bin/env python3

import contextlib
import importlib.util
import io
import tempfile
import unittest
from collections import Counter
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
            self.assertEqual(len(sites), 7)

    def test_trailing_comment_skipped(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            lib = root / "alpha/src/lib.rs"
            lib.write_text(
                lib.read_text()
                + '\n    let file = std::fs::File::open("q")?; // file.try_lock()\n'
            )
            sites = gen.scan_sites(root)
            self.assertEqual(len(sites), 7)
            old = gen.INVENTORY
            gen.INVENTORY = INVENTORY_FIXTURE
            try:
                gen.main(["--apply", "--src", str(root), "--dist-version", "0.1.0+android1"])
                text = (root / "alpha/src/lib.rs").read_text()
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
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            old = gen.INVENTORY
            gen.INVENTORY = {"alpha/src/lib.rs": {("lock_file", "try_lock"): 1}}
            try:
                rc = gen.main(["--src", str(root), "--dist-version", "0.1.0+android1"])
                self.assertEqual(rc, 1)
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
                for root_file in ("alpha/src/lib.rs", "beta/src/lib.rs", "gamma/src/main.rs"):
                    self.assertIn("mod file_lock_shim", (root / root_file).read_text())
                self.assertIn('version = "0.1.0+android1"', (root / "Cargo.toml").read_text())
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
        # Short receiver must not corrupt substring in longer receiver.
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
            }
            try:
                with self.assertRaises(SystemExit):
                    gen.main(["--apply", "--src", str(root), "--dist-version", "0.1.0+android1"])
            finally:
                gen.INVENTORY = old


class TestDynamicApply(unittest.TestCase):
    def test_dynamic_tolerates_inventory_drift(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            old_inv = gen.INVENTORY
            old_min = getattr(gen, "MIN_DYNAMIC_SITES", 10)
            gen.INVENTORY = {
                "alpha/src/lib.rs": {("lock_file", "try_lock"): 1}
            }
            gen.MIN_DYNAMIC_SITES = 5
            try:
                rc = gen.main([
                    "--apply",
                    "--dynamic",
                    "--src", str(root),
                    "--dist-version", "0.1.0+android1",
                ])
                self.assertEqual(rc, 0)
                beta_lib = (root / "beta/src/lib.rs").read_text()
                self.assertIn("crate::file_lock_shim::try_lock(&file)?;", beta_lib)
                self.assertIn('version = "0.1.0+android1"', (root / "Cargo.toml").read_text())
            finally:
                gen.INVENTORY = old_inv
                gen.MIN_DYNAMIC_SITES = old_min

    def test_dynamic_sanity_threshold_fails_when_too_few_sites(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            old_min = getattr(gen, "MIN_DYNAMIC_SITES", 10)
            gen.MIN_DYNAMIC_SITES = 15
            try:
                with self.assertRaises(SystemExit):
                    gen.main([
                        "--apply",
                        "--dynamic",
                        "--src", str(root),
                        "--dist-version", "0.1.0+android1",
                    ])
            finally:
                gen.MIN_DYNAMIC_SITES = old_min

    def test_directory_receiver_matched_and_patched(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            beta_lib = root / "beta/src/lib.rs"
            beta_lib.write_text(
                beta_lib.read_text() + '\npub fn log() { let directory = std::fs::File::open("x")?; directory.try_lock_shared()?; Ok(()) }\n'
            )
            old_min = getattr(gen, "MIN_DYNAMIC_SITES", 10)
            gen.MIN_DYNAMIC_SITES = 5
            try:
                rc = gen.main([
                    "--apply",
                    "--dynamic",
                    "--src", str(root),
                    "--dist-version", "0.1.0+android1",
                ])
                self.assertEqual(rc, 0)
                text = (root / "beta/src/lib.rs").read_text()
                self.assertIn("crate::file_lock_shim::try_lock_shared(&directory)?;", text)
            finally:
                gen.MIN_DYNAMIC_SITES = old_min

    def test_dynamic_leak_check_aborts_on_file_hint_with_lock(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            beta_lib = root / "beta/src/lib.rs"
            beta_lib.write_text(
                beta_lib.read_text() + '\npub fn leak() { let fd = std::fs::File::open("x")?; fd.lock()?; Ok(()) }\n'
            )
            old_min = getattr(gen, "MIN_DYNAMIC_SITES", 10)
            gen.MIN_DYNAMIC_SITES = 5
            try:
                with self.assertRaises(SystemExit):
                    gen.main([
                        "--apply",
                        "--dynamic",
                        "--src", str(root),
                        "--dist-version", "0.1.0+android1",
                    ])
            finally:
                gen.MIN_DYNAMIC_SITES = old_min


ROLLOUT_LIB = "pub use writer_lock::WriterLockCoordinator;\n"

# Mirrors 0.169.0 rollout/src/writer_lock_tests.rs: File receivers whose names
# elude SITE_RE, with the coordination.try_lock() call wrapped across lines.
ROLLOUT_WRITER_LOCK_TESTS = """use super::COORDINATION_LOCK_FILE;
use std::fs;
use tempfile::TempDir;

#[test]
fn rejects_competing_owners() {
    let home = TempDir::new().expect("temp dir");
    let opening = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(home.path().join(COORDINATION_LOCK_FILE))
        .expect("open coordination");
    opening.lock_shared().expect("another writer is opening");
    let file = std::fs::File::open("f")?;
    file.try_lock()?;
    Ok(())
}

#[test]
fn publication_skips_live_writers() {
    let coordination = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("coord")
        .expect("open coordination");
    assert!(matches!(
        coordination.try_lock(),
        Err(std::io::ErrorKind::WouldBlock)
    ));
    coordination
        .try_lock()
        .expect("publication releases coordination");
}
"""


def build_rollout(root: Path, tests_extra: str = ""):
    (root / "rollout/src").mkdir(parents=True)
    (root / "rollout/src/lib.rs").write_text(ROLLOUT_LIB)
    (root / "rollout/src/writer_lock_tests.rs").write_text(
        ROLLOUT_WRITER_LOCK_TESTS + tests_extra
    )


class TestExplicitReceivers(unittest.TestCase):
    def test_scan_includes_explicit_receivers_with_wrapped_call(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            build_rollout(root)
            sites = [
                (rel, recv, method)
                for rel, recv, method in gen.scan_sites(root)
                if rel == "rollout/src/writer_lock_tests.rs"
            ]
            counts = Counter((recv, method) for _, recv, method in sites)
            self.assertEqual(counts[("opening", "lock_shared")], 1)
            self.assertEqual(counts[("coordination", "try_lock")], 2)
            self.assertEqual(counts[("file", "try_lock")], 1)

    def test_dynamic_patches_explicit_receivers(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            build_rollout(root)
            old_min = getattr(gen, "MIN_DYNAMIC_SITES", 10)
            gen.MIN_DYNAMIC_SITES = 8
            try:
                rc = gen.main([
                    "--apply",
                    "--dynamic",
                    "--src", str(root),
                    "--dist-version", "0.1.0+android1",
                ])
                self.assertEqual(rc, 0)
                text = (root / "rollout/src/writer_lock_tests.rs").read_text()
                self.assertIn(
                    'crate::file_lock_shim::lock_shared(&opening).expect("another writer is opening");',
                    text,
                )
                self.assertIn("crate::file_lock_shim::try_lock(&coordination),", text)
                self.assertIn(
                    "crate::file_lock_shim::try_lock(&coordination)\n        .expect(",
                    text,
                )
                self.assertIn("crate::file_lock_shim::try_lock(&file)?;", text)
                self.assertNotIn("opening.lock_shared()", text)
                self.assertNotIn("(&coordination))", text)
                self.assertNotIn("(&opening))", text)
                self.assertIn("mod file_lock_shim", (root / "rollout/src/lib.rs").read_text())
                self.assertIn('version = "0.1.0+android1"', (root / "Cargo.toml").read_text())
                before = {
                    p.relative_to(root): p.read_bytes()
                    for p in root.rglob("*")
                    if p.is_file()
                }
                rc_again = gen.main([
                    "--apply",
                    "--dynamic",
                    "--src", str(root),
                    "--dist-version", "0.1.0+android1",
                ])
                self.assertEqual(rc_again, 0)
                after = {
                    p.relative_to(root): p.read_bytes()
                    for p in root.rglob("*")
                    if p.is_file()
                }
                self.assertEqual(before, after)
            finally:
                gen.MIN_DYNAMIC_SITES = old_min

    def test_dynamic_leak_aborts_on_receiver_outside_allowlisted_file(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            beta_lib = root / "beta/src/lib.rs"
            beta_lib.write_text(
                beta_lib.read_text()
                + '\npub fn leak() { let opening = std::fs::File::open("x")?; opening.lock_shared()?; }\n'
            )
            old_min = getattr(gen, "MIN_DYNAMIC_SITES", 10)
            gen.MIN_DYNAMIC_SITES = 5
            try:
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    with self.assertRaises(SystemExit):
                        gen.main([
                            "--apply",
                            "--dynamic",
                            "--src", str(root),
                            "--dist-version", "0.1.0+android1",
                        ])
                self.assertIn("gate de fugas fallido", err.getvalue())
                self.assertIn("opening.lock_shared()", err.getvalue())
            finally:
                gen.MIN_DYNAMIC_SITES = old_min

    def test_dynamic_leak_aborts_on_unlisted_receiver_in_allowlisted_file(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            build_rollout(
                root,
                tests_extra='\nfn leak() { let fd = std::fs::File::open("x")?; fd.lock_shared()?; }\n',
            )
            old_min = getattr(gen, "MIN_DYNAMIC_SITES", 10)
            gen.MIN_DYNAMIC_SITES = 8
            try:
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    with self.assertRaises(SystemExit):
                        gen.main([
                            "--apply",
                            "--dynamic",
                            "--src", str(root),
                            "--dist-version", "0.1.0+android1",
                        ])
                self.assertIn("gate de fugas fallido", err.getvalue())
                self.assertIn("fd.lock_shared()", err.getvalue())
            finally:
                gen.MIN_DYNAMIC_SITES = old_min

    def test_dynamic_aborts_on_explicit_receiver_in_string_or_comment(self):
        cases = [
            ("string", '\nfn note() { let _ = "opening.lock_shared()"; }\n'),
            ("raw_string", '\nfn note() { let _ = r#"coordination.try_lock()"#; }\n'),
            ("inline_block_comment", '\nfn note() { let x = 1; /* opening.lock_shared() */ let _ = x; }\n'),
            (
                "nested_block_comment",
                '\nfn note() {\n/* outer /* inner */\nopening.lock_shared()\n*/\n}\n',
            ),
            ("line_comment", '\nfn note() {\n    // coordination.try_lock()\n}\n'),
        ]
        for label, extra in cases:
            with self.subTest(case=label):
                with tempfile.TemporaryDirectory() as td:
                    root = Path(td) / "codex-rs"
                    build_tree(root)
                    build_rollout(root, tests_extra=extra)
                    target = root / "rollout/src/writer_lock_tests.rs"
                    original = target.read_text()
                    old_min = getattr(gen, "MIN_DYNAMIC_SITES", 10)
                    gen.MIN_DYNAMIC_SITES = 8
                    try:
                        with self.assertRaises(SystemExit):
                            gen.main([
                                "--apply",
                                "--dynamic",
                                "--src", str(root),
                                "--dist-version", "0.1.0+android1",
                            ])
                        self.assertEqual(target.read_text(), original)
                    finally:
                        gen.MIN_DYNAMIC_SITES = old_min

    def test_explicit_pattern_ignores_field_and_path_access(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            build_rollout(
                root,
                tests_extra=(
                    "\nfn helpers<'a>(h: &'a Holder) {\n"
                    "    let r#type = '\"';\n"
                    "    let _ = r#type;\n"
                    "    let _ = h.coordination.try_lock();\n"
                    "    let _ = foo::coordination.try_lock();\n"
                    "}\n"
                ),
            )
            old_min = getattr(gen, "MIN_DYNAMIC_SITES", 10)
            gen.MIN_DYNAMIC_SITES = 8
            try:
                rc = gen.main([
                    "--apply",
                    "--dynamic",
                    "--src", str(root),
                    "--dist-version", "0.1.0+android1",
                ])
                self.assertEqual(rc, 0)
                text = (root / "rollout/src/writer_lock_tests.rs").read_text()
                self.assertIn("let _ = h.coordination.try_lock();", text)
                self.assertIn("let _ = foo::coordination.try_lock();", text)
                self.assertNotIn("h.crate::", text)
                self.assertNotIn("foo::crate::", text)
                self.assertIn("crate::file_lock_shim::try_lock(&coordination),", text)
            finally:
                gen.MIN_DYNAMIC_SITES = old_min

    def test_scan_does_not_double_count_if_explicit_matches_site_re(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "codex-rs"
            build_tree(root)
            build_rollout(root)
            old_explicit = dict(gen.EXPLICIT_FILE_RECEIVERS)
            gen.EXPLICIT_FILE_RECEIVERS = {
                **old_explicit,
                "rollout/src/writer_lock_tests.rs": ("opening", "coordination", "file"),
            }
            try:
                sites = [
                    (recv, method)
                    for rel, recv, method in gen.scan_sites(root)
                    if rel == "rollout/src/writer_lock_tests.rs"
                ]
                self.assertEqual(Counter(sites)[("file", "try_lock")], 1)
            finally:
                gen.EXPLICIT_FILE_RECEIVERS = old_explicit


if __name__ == "__main__":
    unittest.main(verbosity=2)