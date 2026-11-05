import argparse
from pathlib import Path
import re
import subprocess
import sys


def inspect(tool, *args):
    return subprocess.check_output([tool, *map(str, args)], text=True)


def symbols(readelf, path):
    return [line.split() for line in inspect(readelf, "-sW", path).splitlines()
            if len(line.split()) >= 8 and line.split()[0].endswith(":")]


def check(binary, shim_object, readelf, objdump):
    if "AArch64" not in inspect(readelf, "-h", binary):
        raise ValueError("Expected an AArch64 ELF binary")
    shim_symbols = symbols(readelf, shim_object)
    if any(row[7] in {"__clear_cache", "__clear_cache_impl"} and row[6] != "UND"
           for row in shim_symbols):
        raise ValueError("bionic_compat must leave __clear_cache to compiler-rt")
    linked_symbols = symbols(readelf, binary)
    cache_symbols = [row for row in linked_symbols if row[7] == "__clear_cache"]
    if not cache_symbols or any(row[3] != "FUNC" or row[6] == "UND" for row in cache_symbols):
        raise ValueError("__clear_cache must be a defined function in the linked binary")
    if any(row[7] == "__clear_cache_impl" for row in linked_symbols):
        raise ValueError("Recursive cache shim remains in the linked binary")
    assembly = inspect(objdump, "--disassemble-symbols=__clear_cache",
                       "--no-show-raw-insn", binary).lower()
    instructions = []
    for line in assembly.splitlines():
        match = re.match(r"\s*[0-9a-f]+:\s+([a-z0-9.]+)\s*(.*)", line)
        if match:
            instructions.append((match[1], match[2]))
    if not instructions:
        raise ValueError("__clear_cache has no disassembled instructions")
    for mnemonic, operands in instructions:
        if mnemonic in {"bl", "blr", "br"} or (mnemonic == "b" and "<__clear_cache>" in operands):
            raise ValueError("__clear_cache must be a leaf cache synchronization implementation")
    for mnemonic, operand in [("mrs", "ctr_el0"), ("dc", "cvau"), ("ic", "ivau"),
                              ("dsb", "ish"), ("isb", "")]:
        if not any(name == mnemonic and operand in args for name, args in instructions):
            raise ValueError(f"__clear_cache lacks required cache instruction: {mnemonic} {operand}")
    print(f"PASS: {binary}: nonrecursive AArch64 cache synchronization")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--shim-object", required=True, type=Path)
    parser.add_argument("--readelf", default="llvm-readelf")
    parser.add_argument("--objdump", default="llvm-objdump")
    args = parser.parse_args()
    check(args.binary, args.shim_object, args.readelf, args.objdump)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
