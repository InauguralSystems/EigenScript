#!/usr/bin/env python3
"""
EigenScript Runtime Cross-Compilation Build System (Phase 3.2)

Compiles eigenvalue.c for multiple target architectures:
- Host (default x86_64)
- wasm32-unknown-unknown (WebAssembly)
- aarch64-apple-darwin (Apple Silicon)
- arm-linux-gnueabihf (32-bit ARM)

Usage:
    python3 build_runtime.py [--target TARGET] [--all]

Examples:
    python3 build_runtime.py                    # Build for host
    python3 build_runtime.py --target wasm32    # Build for WASM
    python3 build_runtime.py --all              # Build for all targets
"""

import os
import sys
import subprocess
import argparse
from pathlib import Path

# Target configurations
TARGETS = {
    "host": {
        "triple": None,  # Use system default
        "compiler": "clang",
        "flags": ["-c", "-O3", "-fPIC"],
        "output": "eigenvalue.o",
        "bitcode": "eigenvalue.bc",
    },
    "wasm32": {
        "triple": "wasm32-unknown-unknown",
        "compiler": "clang",
        "flags": [
            "-c",
            "-O3",
            "--target=wasm32-unknown-unknown",
            "-nostdlib",
            "-fno-builtin",
            "-DWASM_BUILD",
        ],
        "output": "eigenvalue.o",
        "bitcode": "eigenvalue.bc",
    },
    "aarch64": {
        "triple": "aarch64-apple-darwin",
        "compiler": "clang",
        "flags": ["-c", "-O3", "-fPIC", "--target=aarch64-apple-darwin"],
        "output": "eigenvalue.o",
        "bitcode": "eigenvalue.bc",
    },
    "arm": {
        "triple": "arm-linux-gnueabihf",
        "compiler": "clang",
        "flags": [
            "-c",
            "-O3",
            "-fPIC",
            "--target=arm-linux-gnueabihf",
            "-march=armv7-a",
        ],
        "output": "eigenvalue.o",
        "bitcode": "eigenvalue.bc",
    },
    "x86_64": {
        "triple": "x86_64-unknown-linux-gnu",
        "compiler": "clang",
        "flags": ["-c", "-O3", "-fPIC", "--target=x86_64-unknown-linux-gnu"],
        "output": "eigenvalue.o",
        "bitcode": "eigenvalue.bc",
    },
}


def check_compiler(compiler):
    """Check if the specified compiler is available."""
    try:
        result = subprocess.run(
            [compiler, "--version"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return result.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def build_target(target_name, config, runtime_dir, verbose=False):
    """Build the runtime for a specific target."""
    print(f"\n{'='*60}")
    print(f"Building runtime for: {target_name}")
    print(f"{'='*60}")

    # Create build directory for this target
    # Use 'host' as directory name for default target to maintain consistency
    target_triple = config.get("triple") if config.get("triple") else "host"
    build_dir = runtime_dir / "build" / target_triple
    build_dir.mkdir(parents=True, exist_ok=True)

    # Source file
    source_file = runtime_dir / "eigenvalue.c"
    if not source_file.exists():
        print(f"❌ Error: Source file not found: {source_file}")
        return False

    # Check compiler availability
    compiler = config["compiler"]
    if not check_compiler(compiler):
        print(f"⚠️  Warning: {compiler} not available, skipping {target_name}")
        return False

    # Build object file
    obj_file = build_dir / config["output"]
    compile_cmd = [compiler] + config["flags"] + [str(source_file), "-o", str(obj_file)]

    if verbose:
        print(f"Command: {' '.join(compile_cmd)}")

    try:
        result = subprocess.run(
            compile_cmd,
            capture_output=True,
            text=True,
            timeout=30,
        )

        if result.returncode != 0:
            print(f"❌ Compilation failed:")
            print(result.stderr)
            return False

        print(f"✅ Object file: {obj_file}")

        # Build LLVM bitcode for LTO
        bc_file = build_dir / config["bitcode"]
        # Keep all flags and add -emit-llvm (needs -c to compile, not link)
        bc_flags = config["flags"].copy()
        bc_flags.append("-emit-llvm")
        bc_cmd = [compiler] + bc_flags + [str(source_file), "-o", str(bc_file)]

        if verbose:
            print(f"Bitcode command: {' '.join(bc_cmd)}")

        result = subprocess.run(
            bc_cmd,
            capture_output=True,
            text=True,
            timeout=30,
        )

        if result.returncode != 0:
            print(f"⚠️  Bitcode generation failed (non-critical):")
            if verbose:
                print(result.stderr)
        else:
            print(f"✅ Bitcode file: {bc_file}")

        # Create convenience symlink for host build
        if target_name == "host":
            obj_link = runtime_dir / "eigenvalue.o"
            bc_link = runtime_dir / "eigenvalue.bc"

            # Remove old symlinks if they exist
            for link in [obj_link, bc_link]:
                if link.exists() or link.is_symlink():
                    link.unlink()

            # Create new symlinks using relative paths
            try:
                # Use relative path from runtime_dir to the build output
                relative_obj = os.path.relpath(obj_file, runtime_dir)
                obj_link.symlink_to(relative_obj)
                print(f"✅ Created symlink: {obj_link} -> {relative_obj}")

                if bc_file.exists():
                    relative_bc = os.path.relpath(bc_file, runtime_dir)
                    bc_link.symlink_to(relative_bc)
                    print(f"✅ Created symlink: {bc_link} -> {relative_bc}")
            except OSError as e:
                if verbose:
                    print(f"⚠️  Could not create symlinks: {e}")

        return True

    except subprocess.TimeoutExpired:
        print(f"❌ Compilation timed out")
        return False
    except Exception as e:
        print(f"❌ Error: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(
        description="Build EigenScript runtime for multiple architectures",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                    # Build for host architecture
  %(prog)s --target wasm32    # Build for WebAssembly
  %(prog)s --all              # Build for all targets
  %(prog)s --list             # List available targets
        """,
    )

    parser.add_argument(
        "--target",
        "-t",
        choices=list(TARGETS.keys()),
        help="Target architecture to build",
    )
    parser.add_argument(
        "--all",
        "-a",
        action="store_true",
        help="Build for all supported targets",
    )
    parser.add_argument(
        "--list",
        "-l",
        action="store_true",
        help="List available targets",
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Enable verbose output",
    )

    args = parser.parse_args()

    # Get runtime directory
    runtime_dir = Path(__file__).parent.resolve()

    if args.list:
        print("\n📦 Available build targets:")
        print("=" * 60)
        for name, config in TARGETS.items():
            triple = config.get("triple") or "system-default"
            compiler = config["compiler"]
            available = "✅" if check_compiler(compiler) else "❌"
            print(f"  {available} {name:10s} - {triple}")
        print()
        return 0

    # Determine which targets to build
    if args.all:
        targets_to_build = list(TARGETS.keys())
    elif args.target:
        targets_to_build = [args.target]
    else:
        # Default: build for host
        targets_to_build = ["host"]

    # Build each target
    print(f"\n🔨 EigenScript Runtime Cross-Compilation Build System")
    print(f"Runtime directory: {runtime_dir}\n")

    success_count = 0
    total_count = len(targets_to_build)

    for target_name in targets_to_build:
        config = TARGETS[target_name]
        if build_target(target_name, config, runtime_dir, args.verbose):
            success_count += 1

    # Summary
    print(f"\n{'='*60}")
    print(f"Build Summary: {success_count}/{total_count} targets successful")
    print(f"{'='*60}")

    if success_count < total_count:
        print(
            f"\n⚠️  Some builds failed. This is normal if you don't have "
            f"cross-compilation toolchains installed."
        )
        print(
            f"To install cross-compilation support:\n"
            f"  - Ubuntu/Debian: sudo apt-get install clang llvm lld\n"
            f"  - macOS: Xcode command line tools include clang\n"
            f"  - WASM: May require emscripten or WASI SDK\n"
        )

    return 0 if success_count > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
