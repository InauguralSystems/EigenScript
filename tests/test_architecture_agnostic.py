"""
Unit tests for architecture-agnostic compiler features.

Tests cross-platform target compilation capabilities.
"""

import pytest
from eigenscript.lexer import Tokenizer
from eigenscript.parser.ast_builder import Parser
from eigenscript.compiler.codegen.llvm_backend import LLVMCodeGenerator
from eigenscript.compiler.analysis.observer import ObserverAnalyzer


class TestArchitectureAgnostic:
    """Test suite for architecture-agnostic compilation."""

    def test_default_target_x86_64_malloc(self):
        """Should use i64 for malloc on x86_64 (default)."""
        # Simple test program
        source = "x is 5\nprint of x"

        # Tokenize and parse
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        # Analyze
        analyzer = ObserverAnalyzer()
        observed_vars = analyzer.analyze(ast.statements)

        # Generate IR with default target
        codegen = LLVMCodeGenerator(observed_variables=observed_vars)
        llvm_ir = codegen.compile(ast.statements)

        # Check target triple and malloc signature
        assert 'target triple = "x86_64-unknown-linux-gnu"' in llvm_ir
        # malloc should use i64 on 64-bit platforms
        assert 'declare i8* @"malloc"(i64' in llvm_ir

    def test_wasm32_target_malloc(self):
        """Should use i32 for malloc on wasm32."""
        # Simple test program
        source = "x is 5\nprint of x"

        # Tokenize and parse
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        # Analyze
        analyzer = ObserverAnalyzer()
        observed_vars = analyzer.analyze(ast.statements)

        # Generate IR with wasm32 target
        codegen = LLVMCodeGenerator(
            observed_variables=observed_vars, target_triple="wasm32-unknown-unknown"
        )
        llvm_ir = codegen.compile(ast.statements)

        # Check target triple and malloc signature
        assert 'target triple = "wasm32-unknown-unknown"' in llvm_ir
        # malloc should use i32 on 32-bit platforms
        assert 'declare i8* @"malloc"(i32' in llvm_ir

    def test_aarch64_target_malloc(self):
        """Should use i64 for malloc on aarch64."""
        # Simple test program
        source = "x is 5\nprint of x"

        # Tokenize and parse
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        # Analyze
        analyzer = ObserverAnalyzer()
        observed_vars = analyzer.analyze(ast.statements)

        # Generate IR with aarch64 target
        codegen = LLVMCodeGenerator(
            observed_variables=observed_vars, target_triple="aarch64-apple-darwin"
        )
        llvm_ir = codegen.compile(ast.statements)

        # Check target triple and malloc signature
        assert 'target triple = "aarch64-apple-darwin"' in llvm_ir
        # malloc should use i64 on 64-bit platforms
        assert 'declare i8* @"malloc"(i64' in llvm_ir

    def test_arm32_target_malloc(self):
        """Should use i32 for malloc on 32-bit ARM."""
        # Simple test program
        source = "x is 5\nprint of x"

        # Tokenize and parse
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        # Analyze
        analyzer = ObserverAnalyzer()
        observed_vars = analyzer.analyze(ast.statements)

        # Generate IR with arm32 target
        codegen = LLVMCodeGenerator(
            observed_variables=observed_vars, target_triple="arm-linux-gnueabihf"
        )
        llvm_ir = codegen.compile(ast.statements)

        # Check target triple and malloc signature
        assert 'target triple = "arm-linux-gnueabihf"' in llvm_ir
        # malloc should use i32 on 32-bit platforms
        assert 'declare i8* @"malloc"(i32' in llvm_ir

    def test_i386_target_malloc(self):
        """Should use i32 for malloc on i386 (32-bit x86)."""
        # Simple test program
        source = "x is 5\nprint of x"

        # Tokenize and parse
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        # Analyze
        analyzer = ObserverAnalyzer()
        observed_vars = analyzer.analyze(ast.statements)

        # Generate IR with i386 target
        codegen = LLVMCodeGenerator(
            observed_variables=observed_vars, target_triple="i386-pc-linux-gnu"
        )
        llvm_ir = codegen.compile(ast.statements)

        # Check target triple and malloc signature
        assert 'target triple = "i386-pc-linux-gnu"' in llvm_ir
        # malloc should use i32 on 32-bit platforms
        assert 'declare i8* @"malloc"(i32' in llvm_ir

    def test_target_triple_preservation(self):
        """Should preserve custom target triples in generated IR."""
        source = "x is 5"

        # Test multiple custom triples
        test_triples = [
            "wasm32-unknown-unknown",
            "aarch64-apple-darwin",
            "x86_64-pc-windows-msvc",
            "riscv64-unknown-linux-gnu",
        ]

        for triple in test_triples:
            tokenizer = Tokenizer(source)
            tokens = tokenizer.tokenize()
            parser = Parser(tokens)
            ast = parser.parse()

            analyzer = ObserverAnalyzer()
            observed_vars = analyzer.analyze(ast.statements)

            codegen = LLVMCodeGenerator(
                observed_variables=observed_vars, target_triple=triple
            )
            llvm_ir = codegen.compile(ast.statements)

            # Verify triple is preserved
            assert f'target triple = "{triple}"' in llvm_ir
