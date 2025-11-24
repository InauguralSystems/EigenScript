"""
Main entry point for EigenScript interpreter.

Run as: python -m eigenscript [file.eigs]
"""

import sys
import argparse
from pathlib import Path
from eigenscript import __version__
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser
from eigenscript.evaluator import Interpreter
from eigenscript.benchmark import Benchmark


def run_file(
    file_path: str,
    verbose: bool = False,
    show_fs: bool = False,
    benchmark: bool = False,
) -> int:
    """
    Execute an EigenScript file.

    Args:
        file_path: Path to .eigs file
        verbose: Print execution details
        show_fs: Show Framework Strength metrics after execution
        benchmark: Measure and display performance metrics

    Returns:
        Exit code (0 for success, 1 for error)
    """
    bench_ctx = None

    try:
        # Read source code
        with open(file_path, "r", encoding="utf-8") as f:
            source = f.read()

        if verbose:
            print(f"Executing: {file_path}")
            print("=" * 60)

        # Start benchmarking if requested
        if benchmark:
            bench_ctx = Benchmark(track_memory=True)
            bench_ctx.__enter__()

        # Tokenize
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()

        # Parse
        parser = Parser(tokens)
        ast = parser.parse()

        # Interpret
        interpreter = Interpreter(dimension=768)
        result = interpreter.evaluate(ast)

        # Stop benchmarking
        if benchmark and bench_ctx:
            bench_ctx.add_metadata("file", file_path)
            bench_ctx.add_metadata("source_lines", source.count("\n") + 1)
            bench_ctx.add_metadata("tokens", len(tokens))
            bench_ctx.__exit__(None, None, None)
            bench_result = bench_ctx.get_result()
            print(f"\n{bench_result}")

        if verbose:
            print("=" * 60)
            print(f"Execution complete")
            print(f"Framework Strength: {interpreter.fs_tracker.compute_fs():.4f}")
            print(f"Variables: {len(interpreter.environment.bindings)}")

        # Show metrics if requested
        if show_fs:
            fs = interpreter.get_framework_strength()
            signature, classification = interpreter.get_spacetime_signature()
            converged = interpreter.has_converged()

            print(f"\n=== Framework Strength Metrics ===")
            print(f"Framework Strength: {fs:.4f}")
            print(f"Converged: {converged}")
            print(f"Spacetime Signature: {signature:.4f} ({classification})")

        return 0

    except FileNotFoundError:
        if benchmark and bench_ctx:
            bench_ctx.__exit__(FileNotFoundError, None, None)
        print(f"Error: File not found: {file_path}", file=sys.stderr)
        print(f"Please check the file path and try again.", file=sys.stderr)
        return 1
    except SyntaxError as e:
        if benchmark and bench_ctx:
            bench_ctx.__exit__(SyntaxError, e, None)
        print(f"Syntax Error: {e}", file=sys.stderr)
        print(f"Please check your EigenScript syntax.", file=sys.stderr)
        if verbose:
            import traceback

            traceback.print_exc()
        return 1
    except NameError as e:
        if benchmark and bench_ctx:
            bench_ctx.__exit__(NameError, e, None)
        print(f"Name Error: {e}", file=sys.stderr)
        print(f"This variable or function may not be defined.", file=sys.stderr)
        return 1
    except RuntimeError as e:
        if benchmark and bench_ctx:
            bench_ctx.__exit__(RuntimeError, e, None)
        print(f"Runtime Error: {e}", file=sys.stderr)
        if verbose:
            import traceback

            traceback.print_exc()
        return 1
    except Exception as e:
        if benchmark and bench_ctx:
            bench_ctx.__exit__(type(e), e, None)
        print(f"Error: {type(e).__name__}: {e}", file=sys.stderr)
        if verbose:
            import traceback

            traceback.print_exc()
        return 1


def run_repl(verbose: bool = False) -> int:
    """
    Run interactive Read-Eval-Print Loop with multi-line support.

    Args:
        verbose: Show detailed execution information

    Returns:
        Exit code (0 for success)
    """
    print(f"EigenScript {__version__}")
    print("Type 'exit' or press Ctrl+D to quit")
    print("Use blank line to complete multi-line blocks")
    print("=" * 60)

    interpreter = Interpreter(dimension=768)

    while True:
        try:
            lines = []
            prompt = ">>> "

            while True:
                line = input(prompt)

                if line.strip() in ("exit", "quit") and not lines:
                    print("Goodbye!")
                    return 0

                if not line.strip() and not lines:
                    break

                if not line.strip() and lines:
                    break

                lines.append(line)

                if line.endswith(":"):
                    prompt = "... "
                elif prompt == ">>> ":
                    break
                elif prompt == "... " and line and not line[0].isspace():
                    break

            if not lines:
                continue

            source = "\n".join(lines)

            tokenizer = Tokenizer(source)
            tokens = tokenizer.tokenize()

            parser = Parser(tokens)
            ast = parser.parse()

            result = interpreter.evaluate(ast)

            print(result)

            if verbose:
                fs = interpreter.fs_tracker.compute_fs()
                print(
                    f"[FS: {fs:.4f}, Variables: {len(interpreter.environment.bindings)}]"
                )

        except EOFError:
            print("\nGoodbye!")
            return 0
        except KeyboardInterrupt:
            print("\nInterrupted. Type 'exit' to quit.")
            continue
        except SyntaxError as e:
            print(f"Syntax Error: {e}", file=sys.stderr)
            print(
                f"Hint: Check your EigenScript syntax (operators, indentation, etc.)",
                file=sys.stderr,
            )
            if verbose:
                import traceback

                traceback.print_exc()
        except NameError as e:
            print(f"Name Error: {e}", file=sys.stderr)
            print(
                f"Hint: Make sure all variables and functions are defined before use",
                file=sys.stderr,
            )
        except Exception as e:
            print(f"Error: {type(e).__name__}: {e}", file=sys.stderr)
            if verbose:
                import traceback

                traceback.print_exc()


def main():
    """Main entry point for the EigenScript interpreter."""
    parser = argparse.ArgumentParser(
        description="EigenScript: A geometric programming language"
    )
    parser.add_argument(
        "file", nargs="?", help="EigenScript source file (.eigs) to execute"
    )
    parser.add_argument(
        "--version", action="version", version=f"EigenScript {__version__}"
    )
    parser.add_argument(
        "-i", "--interactive", action="store_true", help="Start interactive REPL"
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="Verbose output")
    parser.add_argument(
        "--show-fs",
        action="store_true",
        help="Show Framework Strength metrics after execution",
    )
    parser.add_argument(
        "-b",
        "--benchmark",
        action="store_true",
        help="Measure and display performance metrics (time, memory)",
    )

    args = parser.parse_args()

    if args.interactive:
        return run_repl(verbose=args.verbose)

    if args.file:
        return run_file(
            args.file,
            verbose=args.verbose,
            show_fs=args.show_fs,
            benchmark=args.benchmark,
        )
    else:
        parser.print_help()
        return 0


if __name__ == "__main__":
    sys.exit(main())
