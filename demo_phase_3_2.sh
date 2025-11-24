#!/bin/bash
# Phase 3.2 Demo: Cross-Compilation Build System
# Demonstrates the new runtime build system capabilities

set -e  # Exit on error

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  EigenScript Phase 3.2: Cross-Compilation Build System Demo     ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Change to repository root
cd "$(dirname "$0")"

echo "📦 Step 1: List Available Build Targets"
echo "═════════════════════════════════════════"
python3 src/eigenscript/compiler/runtime/build_runtime.py --list
echo ""

echo "🔨 Step 2: Build Runtime for Multiple Targets"
echo "═══════════════════════════════════════════════"
echo "Building host and x86_64 runtimes..."
python3 src/eigenscript/compiler/runtime/build_runtime.py --target host
python3 src/eigenscript/compiler/runtime/build_runtime.py --target x86_64
echo ""

echo "📂 Step 3: Verify Build Output Structure"
echo "═════════════════════════════════════════"
echo "Runtime build directory:"
tree -L 3 src/eigenscript/compiler/runtime/build/ 2>/dev/null || ls -R src/eigenscript/compiler/runtime/build/
echo ""

echo "🔗 Step 4: Check Symlinks"
echo "═════════════════════════"
ls -lh src/eigenscript/compiler/runtime/eigenvalue.* | grep -E "(eigenvalue.o|eigenvalue.bc)"
echo ""

echo "✨ Step 5: Compile with Default Target (uses host runtime)"
echo "══════════════════════════════════════════════════════════"
python3 -m eigenscript.compiler.cli.compile examples/factorial_simple.eigs -o /tmp/demo_default.ll 2>&1 | grep -E "(✓|✅|→)"
echo ""

echo "🎯 Step 6: Compile with Explicit x86_64 Target"
echo "═══════════════════════════════════════════════"
python3 -m eigenscript.compiler.cli.compile examples/factorial_simple.eigs \
    --target x86_64-unknown-linux-gnu \
    -o /tmp/demo_x86_64.ll 2>&1 | grep -E "(✓|✅|→)"
echo ""

echo "🔍 Step 7: Verify malloc Signatures in Generated IR"
echo "═════════════════════════════════════════════════════"
echo "Default (host):"
grep "declare.*malloc" /tmp/demo_default.ll | sed 's/^/  /'
echo ""
echo "x86_64:"
grep "declare.*malloc" /tmp/demo_x86_64.ll | sed 's/^/  /'
echo ""

echo "🧪 Step 8: Run Test Suite"
echo "═════════════════════════"
python3 -m pytest tests/test_runtime_build_system.py -v --tb=short 2>&1 | grep -E "(PASSED|FAILED|test_)" | head -15
echo ""

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  ✅ Phase 3.2 Demo Complete!                                    ║"
echo "║                                                                  ║"
echo "║  The runtime build system now supports:                         ║"
echo "║  • Cross-compilation for multiple architectures                 ║"
echo "║  • Automatic runtime building on demand                         ║"
echo "║  • Target-specific LTO optimization                             ║"
echo "║  • Graceful fallback for missing toolchains                     ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
