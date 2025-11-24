#!/usr/bin/env python3
"""
EigenScript Compiler CLI
Compile .eigs files to LLVM IR, native code, or WebAssembly.
Supports recursive module compilation and dependency management.
"""

import sys
import os
import argparse
import subprocess
from typing import List, Set, Optional

from eigenscript.lexer import Tokenizer
from eigenscript.parser.ast_builder import Parser, Import
from eigenscript.compiler.codegen.llvm_backend import LLVMCodeGenerator
from eigenscript.compiler.analysis.observer import ObserverAnalyzer
from eigenscript.compiler.analysis.resolver import ModuleResolver
from eigenscript.compiler.runtime.targets import infer_target_name
from llvmlite import binding as llvm

# Default WASM target triple
DEFAULT_WASM_TARGET = "wasm32-unknown-unknown"


def get_runtime_path(runtime_dir: str, target_triple: str = None) -> tuple[str, str]:
    """Get the correct runtime object file and bitcode for the target architecture.

    Args:
        runtime_dir: Path to the runtime directory
        target_triple: LLVM target triple (e.g., "wasm32-unknown-unknown")

    Returns:
        Tuple of (object_file_path, bitcode_file_path)
    """
    # Default to host runtime
    if not target_triple:
        target_triple = "host"

    # Map triple to build directory
    build_dir = os.path.join(runtime_dir, "build", target_triple)
    runtime_o = os.path.join(build_dir, "eigenvalue.o")
    runtime_bc = os.path.join(build_dir, "eigenvalue.bc")

    # If target-specific runtime doesn't exist, try to build it
    if not os.path.exists(runtime_o):
        print(f"  → Runtime for {target_triple} not found, attempting to build...")

        # Use shared target name inference
        target_name = infer_target_name(target_triple)

        # Run build script
        build_script = os.path.join(runtime_dir, "build_runtime.py")
        if os.path.exists(build_script):
            result = subprocess.run(
                [sys.executable, build_script, "--target", target_name],
                capture_output=True,
                text=True,
                cwd=runtime_dir,
                timeout=60,  # Prevent hanging on build issues
            )

            if result.returncode != 0:
                print(f"  ⚠️  Runtime build failed for {target_triple}")
                # Fall back to host runtime if available
                host_runtime_o = os.path.join(runtime_dir, "eigenvalue.o")
                host_runtime_bc = os.path.join(runtime_dir, "eigenvalue.bc")
                if os.path.exists(host_runtime_o):
                    print(f"  → Falling back to host runtime")
                    return host_runtime_o, host_runtime_bc
                return None, None

    # If still doesn't exist after build attempt, fall back
    if not os.path.exists(runtime_o):
        # Try host runtime symlink
        host_runtime_o = os.path.join(runtime_dir, "eigenvalue.o")
        host_runtime_bc = os.path.join(runtime_dir, "eigenvalue.bc")
        if os.path.exists(host_runtime_o):
            return host_runtime_o, host_runtime_bc
        return None, None

    return runtime_o, runtime_bc


def scan_imports(ast) -> List[str]:
    """Scan AST for import statements and return list of module names."""
    imports = []
    for stmt in ast.statements:
        if isinstance(stmt, Import):
            imports.append(stmt.module_name)
    return imports


def compile_module(
    source_path: str,
    resolver: ModuleResolver,
    compiled_objects: Set[str],
    target_triple: str = None,
    opt_level: int = 0,
    is_main: bool = False,
) -> Optional[str]:
    """
    Recursively compile a module and its dependencies.

    Args:
        source_path: Path to the .eigs file to compile
        resolver: ModuleResolver for finding imported modules
        compiled_objects: Set of already-compiled module paths (prevents recompilation)
        target_triple: LLVM target triple
        opt_level: Optimization level (0-3)
        is_main: True if this is the main entry point (generates main()), False for libraries

    Returns:
        Path to the compiled object file, or None on failure
    """
    # Prevent circular dependencies and duplicate compilation
    abs_path = os.path.abspath(source_path)
    if abs_path in compiled_objects:
        # Already compiled, return the object file path
        return resolver.get_output_path(source_path, target_triple)

    print(f"\n→ Compiling module: {source_path}")

    # Read source
    try:
        with open(source_path, "r") as f:
            source_code = f.read()
    except FileNotFoundError:
        print(f"  ✗ Module not found: {source_path}")
        return None

    # Parse to find imports
    tokenizer = Tokenizer(source_code)
    tokens = tokenizer.tokenize()
    parser = Parser(tokens)
    ast = parser.parse()

    # Find and recursively compile dependencies first
    imports = scan_imports(ast)
    if imports:
        print(f"  → Found imports: {imports}")
        for module_name in imports:
            try:
                module_path = resolver.resolve(module_name)
                # Dependencies are always libraries (is_main=False)
                dep_obj = compile_module(
                    module_path,
                    resolver,
                    compiled_objects,
                    target_triple,
                    opt_level,
                    is_main=False,
                )
                if not dep_obj:
                    print(f"  ✗ Failed to compile dependency: {module_name}")
                    return None
            except ImportError as e:
                print(f"  ✗ {e}")
                return None

    # Now compile this module
    try:
        # Filter out import statements (they're compile-time only)
        code_statements = [
            stmt for stmt in ast.statements if not isinstance(stmt, Import)
        ]

        # Analyze for observer effect
        analyzer = ObserverAnalyzer()
        observed_vars = analyzer.analyze(code_statements)

        # Determine if this is a library module or main program
        # Extract module name from source path (e.g., "math_utils.eigs" -> "math_utils")
        # Only pass module_name if this is a library (not the main entry point)
        # The main file generates main(), libraries generate {module}_init()
        codegen_module_name = (
            None if is_main else os.path.splitext(os.path.basename(source_path))[0]
        )

        # Generate LLVM IR
        codegen = LLVMCodeGenerator(
            observed_variables=observed_vars,
            target_triple=target_triple,
            module_name=codegen_module_name,
        )
        # Phase 4.4: Pass imported modules so main() can call their init functions
        imported_modules_for_codegen = imports if is_main else None
        llvm_ir = codegen.compile(code_statements, imported_modules_for_codegen)

        # Parse and verify
        llvm_module = llvm.parse_assembly(llvm_ir)
        llvm_module.verify()

        # Link runtime bitcode
        llvm_module = codegen.link_runtime_bitcode(llvm_module, target_triple)

        # Apply optimizations if requested
        if opt_level > 0:
            pto = llvm.create_pipeline_tuning_options()
            pto.speed_level = opt_level
            pto.size_level = 0

            if target_triple:
                target = llvm.Target.from_triple(target_triple)
            else:
                target = llvm.Target.from_default_triple()
            target_machine = target.create_target_machine()

            pb = llvm.create_pass_builder(target_machine, pto)
            mpm = llvm.create_module_pass_manager()
            pb.populate_module_pass_manager(mpm)
            mpm.run(llvm_module)

        # Emit object file
        output_path = resolver.get_output_path(source_path, target_triple)
        if target_triple:
            target = llvm.Target.from_triple(target_triple)
        else:
            target = llvm.Target.from_default_triple()
        target_machine = target.create_target_machine()

        with open(output_path, "wb") as f:
            f.write(target_machine.emit_object(llvm_module))

        print(f"  ✓ Compiled to: {output_path}")

        # Mark as compiled
        compiled_objects.add(abs_path)
        return output_path

    except Exception as e:
        print(f"  ✗ Compilation failed: {e}")
        return None


def compile_file(
    input_file: str,
    output_file: str = None,
    emit_llvm: bool = True,
    verify: bool = True,
    link_exec: bool = False,
    opt_level: int = 0,
    target_triple: str = None,
):
    """Compile an EigenScript file to LLVM IR, object code, or executable."""

    # Read source file
    try:
        with open(input_file, "r") as f:
            source_code = f.read()
    except FileNotFoundError:
        print(f"Error: File '{input_file}' not found")
        return 1
    except Exception as e:
        print(f"Error reading file: {e}")
        return 1

    # Determine output file
    # Detect WASM target for extension selection
    is_wasm = target_triple and "wasm" in target_triple.lower()

    if output_file is None:
        base = os.path.splitext(input_file)[0]
        if link_exec:
            # For executables, use .wasm for WASM targets, .exe for native
            output_file = f"{base}.wasm" if is_wasm else f"{base}.exe"
        else:
            output_file = f"{base}.ll" if emit_llvm else f"{base}.o"

    print(f"Compiling {input_file} -> {output_file}")

    try:
        # Initialize module resolver
        root_dir = os.path.dirname(os.path.abspath(input_file))
        resolver = ModuleResolver(root_dir=root_dir)
        compiled_objects: Set[str] = set()

        # If linking, we need to compile modules and collect object files
        if link_exec or not emit_llvm:
            # Compile main file and all dependencies
            main_obj = compile_module(
                input_file,
                resolver,
                compiled_objects,
                target_triple,
                opt_level,
                is_main=True,
            )

            if not main_obj:
                print(f"❌ Compilation failed")
                return 1

            # Collect all compiled object files
            object_files = [
                resolver.get_output_path(path, target_triple)
                for path in compiled_objects
            ]

            # If we just want object file, we're done
            if not link_exec:
                if not emit_llvm:
                    # Move/copy the main object to output location if different
                    if main_obj != output_file:
                        import shutil

                        shutil.copy(main_obj, output_file)
                    print(f"\n✅ Compilation successful!")
                    return 0

            # Link to executable
            runtime_dir = os.path.join(os.path.dirname(__file__), "../runtime")
            runtime_o, _ = get_runtime_path(runtime_dir, target_triple)

            if not runtime_o:
                print(f"  ✗ Runtime library not available for target")
                return 1

            # Select linker and flags based on target
            if is_wasm:
                # WebAssembly Linking
                linker = "clang"
                wasm_target = target_triple if target_triple else DEFAULT_WASM_TARGET
                link_cmd = (
                    [
                        linker,
                        f"--target={wasm_target}",
                        "-nostdlib",
                        "-Wl,--no-entry",
                        "-Wl,--export-all",
                        "-Wl,--allow-undefined",
                    ]
                    + object_files
                    + [runtime_o, "-o", output_file]
                )
            else:
                # Standard Native Linking
                linker = "gcc"
                link_cmd = (
                    [linker] + object_files + [runtime_o, "-o", output_file, "-lm"]
                )

            print(f"\n→ Linking {len(object_files)} module(s) with {linker}...")
            result = subprocess.run(link_cmd, capture_output=True, text=True)

            if result.returncode == 0:
                print(f"  ✓ Linked to {output_file}")
                print(f"\n✅ Compilation successful!")
                return 0
            else:
                print(f"  ✗ Linking failed: {result.stderr}")
                return 1

        # Original path for LLVM IR emission (no modules yet)
        # Tokenize
        tokenizer = Tokenizer(source_code)
        tokens = tokenizer.tokenize()
        print(f"  ✓ Tokenized: {len(tokens)} tokens")

        # Parse
        parser = Parser(tokens)
        ast = parser.parse()
        print(f"  ✓ Parsed: {len(ast.statements)} statements")

        # Analyze
        analyzer = ObserverAnalyzer()
        observed_vars = analyzer.analyze(ast.statements)
        if observed_vars:
            print(
                f"  ✓ Analysis: {len(observed_vars)} observed variables {observed_vars}"
            )
        else:
            print(f"  ✓ Analysis: No variables need geometric tracking (pure scalars!)")

        # Generate LLVM IR
        codegen = LLVMCodeGenerator(
            observed_variables=observed_vars, target_triple=target_triple
        )
        llvm_ir = codegen.compile(ast.statements)
        print(f"  ✓ Generated LLVM IR")

        # Verify
        llvm_module = llvm.parse_assembly(llvm_ir)
        if verify:
            try:
                llvm_module.verify()
                print(f"  ✓ Verification passed")
            except Exception as verify_error:
                print(f"  ✗ Verification failed: {verify_error}")
                return 1

        # Link runtime bitcode
        llvm_module = codegen.link_runtime_bitcode(llvm_module, target_triple)
        print(f"  ✓ Linked runtime bitcode (LTO enabled)")

        # Apply optimizations
        if opt_level > 0:
            pto = llvm.create_pipeline_tuning_options()
            pto.speed_level = opt_level
            pto.size_level = 0
            pto.inline_threshold = 225

            if opt_level == 1:
                pto.inline_threshold = 75
            elif opt_level == 2:
                pto.inline_threshold = 225
            elif opt_level == 3:
                pto.inline_threshold = 375

            if opt_level >= 2:
                pto.loop_vectorization = True
                pto.slp_vectorization = True
                pto.loop_interleaving = True
                pto.loop_unrolling = True

            if target_triple:
                target = llvm.Target.from_triple(target_triple)
            else:
                target = llvm.Target.from_default_triple()
            target_machine = target.create_target_machine()

            pb = llvm.create_pass_builder(target_machine, pto)
            mpm = llvm.create_module_pass_manager()
            pb.populate_module_pass_manager(mpm)
            mpm.run(llvm_module)
            print(f"  ✓ Optimizations applied (level {opt_level})")

        # Write output
        if emit_llvm:
            with open(output_file, "w") as f:
                f.write(str(llvm_module))
            print(f"  ✓ LLVM IR written to {output_file}")
        else:
            if target_triple:
                target = llvm.Target.from_triple(target_triple)
            else:
                target = llvm.Target.from_default_triple()
            target_machine = target.create_target_machine()
            with open(output_file, "wb") as f:
                f.write(target_machine.emit_object(llvm_module))
            print(f"  ✓ Object file written to {output_file}")

        print(f"\n✅ Compilation successful!")
        return 0

    except Exception as e:
        print(f"\n❌ Compilation failed: {e}")
        import traceback

        traceback.print_exc()
        return 1


def main():
    parser = argparse.ArgumentParser(
        description="EigenScript Compiler - Compile .eigs files to LLVM IR, native code, or WASM",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Examples:
  %(prog)s program.eigs                              # Compile to LLVM IR (program.ll)
  %(prog)s program.eigs -o out.ll                    # Specify output file
  %(prog)s program.eigs --obj                        # Compile to object file (program.o)
  %(prog)s program.eigs --exec                       # Compile and link to executable (program.exe)
  %(prog)s program.eigs -O2 --exec                   # Compile with -O2 optimizations
  %(prog)s program.eigs --target {DEFAULT_WASM_TARGET} --exec  # Compile to WebAssembly (program.wasm)
  %(prog)s program.eigs --no-verify                  # Skip verification
        """,
    )

    parser.add_argument("input", help="Input EigenScript file (.eigs)")
    parser.add_argument(
        "-o", "--output", help="Output file (default: input with .ll or .o extension)"
    )
    parser.add_argument(
        "--obj", action="store_true", help="Compile to object file instead of LLVM IR"
    )
    parser.add_argument(
        "--exec", action="store_true", help="Compile and link to executable"
    )
    parser.add_argument(
        "-O",
        "--optimize",
        type=int,
        choices=[0, 1, 2, 3],
        default=0,
        help="Optimization level (0=none, 1=basic, 2=standard, 3=aggressive)",
    )
    parser.add_argument(
        "--target",
        help=f"Target triple (e.g., {DEFAULT_WASM_TARGET} for WebAssembly)",
    )
    parser.add_argument(
        "--no-verify", action="store_true", help="Skip LLVM IR verification"
    )

    args = parser.parse_args()

    # Determine output mode
    emit_llvm = not args.obj and not args.exec
    link_exec = args.exec

    result = compile_file(
        input_file=args.input,
        output_file=args.output,
        emit_llvm=emit_llvm,
        verify=not args.no_verify,
        link_exec=link_exec,
        opt_level=args.optimize,
        target_triple=args.target,
    )

    sys.exit(result)


if __name__ == "__main__":
    main()
