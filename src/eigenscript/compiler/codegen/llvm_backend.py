"""
LLVM Backend for EigenScript Compiler
Generates LLVM IR from EigenScript AST nodes.
"""

import os
import re
from llvmlite import ir
from llvmlite import binding as llvm
from typing import Dict, Optional, Union, Set
from enum import Enum
from dataclasses import dataclass

from eigenscript.parser.ast_builder import (
    ASTNode,
    Literal,
    Identifier,
    BinaryOp,
    UnaryOp,
    Assignment,
    IndexedAssignment,
    FunctionDef,
    Return,
    Break,
    Conditional,
    Loop,
    Relation,
    Interrogative,
    ListLiteral,
    Index,
    Import,
    MemberAccess,
    StructDef,
    StructLiteral,
)


class CompilerError(Exception):
    """Enhanced compiler error with source location and hints."""

    def __init__(
        self, message: str, hint: Optional[str] = None, node: Optional[ASTNode] = None
    ):
        self.message = message
        self.hint = hint
        self.node = node

        # Build full error message
        full_msg = f"CompilerError: {message}"
        if hint:
            full_msg += f"\n  Hint: {hint}"
        if node and hasattr(node, "line"):
            full_msg += f"\n  Location: line {node.line}"
            if hasattr(node, "column"):
                full_msg += f", column {node.column}"

        super().__init__(full_msg)


class ValueKind(Enum):
    """Tracks the kind of value generated during compilation."""

    SCALAR = "scalar"  # Raw double value
    EIGEN_PTR = "eigen_ptr"  # EigenValue* pointer
    LIST_PTR = "list_ptr"  # EigenList* pointer
    STRING_PTR = "string_ptr"  # EigenString* pointer (for self-hosting)
    STRUCT_PTR = "struct_ptr"  # User-defined struct pointer (for self-hosting)
    PACKED_I64 = "packed_i64"  # i64 that could be scalar or pointer (function params)


@dataclass
class GeneratedValue:
    """Wrapper for values generated during compilation.

    This enables Option 2 (interrogative aliasing) by tracking whether
    a value is a raw scalar or an EigenValue pointer, preserving the
    is/of duality where 'of' is observational (stable) and 'is' is computational.
    """

    value: ir.Value
    kind: ValueKind
    struct_name: Optional[str] = None  # For STRUCT_PTR: name of the struct type


class LLVMCodeGenerator:
    """Generates LLVM IR from EigenScript AST."""

    def __init__(
        self,
        observed_variables: Optional[Set[str]] = None,
        target_triple: Optional[str] = None,
        module_name: Optional[str] = None,
        imported_names: Optional[Set[str]] = None,
    ):
        # Initialize LLVM targets (initialization is now automatic in llvmlite)
        llvm.initialize_native_target()
        llvm.initialize_native_asmprinter()

        # Module vs Program: Determine compilation mode
        # If module_name is None → Generate main() (it's the entry point)
        # If module_name is "physics" → Skip main(), create physics_init()
        self.is_library = module_name is not None
        self.module_prefix = f"{module_name}_" if self.is_library else ""
        # Track entry function name for proper scoping
        self.entry_function_name = f"{module_name}_init" if self.is_library else "main"

        # Create module
        self.module = ir.Module(name="eigenscript_module")

        # 1. Configure Target Architecture
        # Store target_triple as instance variable for WASM-specific code paths
        self.target_triple = target_triple
        if target_triple:
            self.module.triple = target_triple
        else:
            self.module.triple = llvm.get_default_triple()

        # Get Target Data Layout (Crucial for pointer sizes)
        try:
            target = llvm.Target.from_triple(self.module.triple)
            target_machine = target.create_target_machine()
            target_data = target_machine.target_data
            self.module.data_layout = str(target_data)
        except RuntimeError as e:
            # Fallback for unknown triples (e.g. during cross-compilation setup)
            import warnings

            warnings.warn(
                f"Could not load target data for '{self.module.triple}': {e}",
                RuntimeWarning,
            )
            # Default to x86_64 if native lookup fails
            target_data = None

        # Observer Effect: Track which variables need geometric tracking
        # Unobserved variables compile to raw doubles for C-level performance
        self.observed_variables = observed_variables or set()

        # Track imported names - these are declared as external, not defined
        self.imported_names = imported_names or set()

        # 2. Dynamic Type Definitions
        self.double_type = ir.DoubleType()
        self.int64_type = ir.IntType(64)  # Fixed size for data (iterations, etc)
        self.int32_type = ir.IntType(32)
        self.int8_type = ir.IntType(8)
        self.void_type = ir.VoidType()
        self.bool_type = ir.IntType(1)

        # Determine size_t (pointer integer type) by analyzing the triple
        # WASM32 -> 32-bit, x86_64 -> 64-bit, ARM64 -> 64-bit
        # Check the triple for architecture indicators
        triple_lower = self.module.triple.lower()
        # 32-bit architectures
        if (
            "wasm32" in triple_lower
            or "i386" in triple_lower
            or "i686" in triple_lower
            or triple_lower.startswith("arm-")
            or "armv7" in triple_lower
        ):
            self.size_t_type = ir.IntType(32)
        # 64-bit architectures
        elif (
            "x86_64" in triple_lower
            or "aarch64" in triple_lower
            or "arm64" in triple_lower
            or "wasm64" in triple_lower
            or "riscv64" in triple_lower
        ):
            self.size_t_type = ir.IntType(64)
        else:
            # Default fallback to 64-bit for unknown architectures
            self.size_t_type = ir.IntType(64)

        # EigenValue structure - Architecture Independent (Fixed width types)
        # MUST match eigenvalue.h exactly!
        # typedef struct {
        #     double value, gradient, stability;
        #     int64_t iteration;
        #     double history[100];
        #     int history_size, history_index;
        #     double prev_value, prev_gradient;
        # } EigenValue;
        self.eigen_value_type = ir.LiteralStructType(
            [
                self.double_type,  # value
                self.double_type,  # gradient (why)
                self.double_type,  # stability (how)
                self.int64_type,  # iteration (when) - always 64-bit in C runtime
                ir.ArrayType(self.double_type, 100),  # history[100]
                self.int32_type,  # history_size
                self.int32_type,  # history_index
                self.double_type,  # prev_value
                self.double_type,  # prev_gradient
            ]
        )

        # EigenList structure: {double* data, i64 length, i64 capacity}
        # matches C: {double* data, int64_t length, int64_t capacity}
        self.eigen_list_type = ir.LiteralStructType(
            [
                self.double_type.as_pointer(),  # data ptr (size varies by arch)
                self.int64_type,  # length (always 64-bit)
                self.int64_type,  # capacity (always 64-bit)
            ]
        )

        # Pointer types
        self.eigen_value_ptr = self.eigen_value_type.as_pointer()
        self.eigen_list_ptr = self.eigen_list_type.as_pointer()
        self.string_type = self.int8_type.as_pointer()  # C-style char*

        # EigenString structure: {char* data, i64 length, i64 capacity}
        # This is the native string type for self-hosting
        self.eigen_string_type = ir.LiteralStructType(
            [
                self.string_type,  # data ptr (char*)
                self.int64_type,  # length
                self.int64_type,  # capacity
            ]
        )
        self.eigen_string_ptr = self.eigen_string_type.as_pointer()

        # Symbol tables
        self.global_vars: Dict[str, ir.AllocaInstr] = {}
        self.local_vars: Dict[str, ir.AllocaInstr] = {}
        self.functions: Dict[str, ir.Function] = {}
        self.external_globals: Dict[str, ir.GlobalVariable] = {}  # Cross-module refs
        self.external_functions: Dict[str, ir.Function] = {}  # Cross-module funcs

        # Struct type registry (for self-hosting)
        # Maps struct name -> (LLVM type, field names)
        self.struct_types: Dict[str, tuple[ir.Type, list[str]]] = {}

        # Current function and builder
        self.current_function: Optional[ir.Function] = None
        self.builder: Optional[ir.IRBuilder] = None
        self.entry_block: Optional[ir.Block] = (
            None  # Entry block for alloca instructions
        )

        # Loop context (for break/continue statements)
        self.loop_end_stack: list[ir.Block] = []  # Stack of loop end blocks

        # Cleanup tracking (for memory management)
        self.allocated_eigenvalues: list[ir.Value] = []
        self.allocated_lists: list[ir.Value] = []
        self.allocated_strings: list[ir.Value] = []  # EigenString* for self-hosting

        # Initialize runtime functions
        self._declare_runtime_functions()

    def _declare_runtime_functions(self):
        """Declare runtime functions with architecture-correct types."""

        # printf for debugging (native targets)
        printf_type = ir.FunctionType(self.int32_type, [self.string_type], var_arg=True)
        self.printf = ir.Function(self.module, printf_type, name="printf")
        self.printf.attributes.add("nounwind")

        # eigen_print_f64 for WASM (non-variadic, simpler for JS bridge)
        # This avoids variadic calling convention issues in WebAssembly
        eigen_print_f64_type = ir.FunctionType(self.void_type, [self.double_type])
        self.eigen_print_f64 = ir.Function(
            self.module, eigen_print_f64_type, name="eigen_print_f64"
        )
        self.eigen_print_f64.attributes.add("nounwind")

        # malloc - CRITICAL FIX: Use size_t_type, NOT int64_type
        # On WASM32, malloc takes i32. On x64, it takes i64.
        malloc_type = ir.FunctionType(self.string_type, [self.size_t_type])
        self.malloc = ir.Function(self.module, malloc_type, name="malloc")
        self.malloc.attributes.add("nounwind")

        # Runtime functions for geometric tracking
        # eigen_create(value) -> EigenValue* (heap allocation)
        eigen_create_type = ir.FunctionType(self.eigen_value_ptr, [self.double_type])
        self.eigen_create = ir.Function(
            self.module, eigen_create_type, name="eigen_create"
        )
        self.eigen_create.attributes.add("nounwind")

        # eigen_init(eigen*, value) -> void (stack initialization)
        eigen_init_type = ir.FunctionType(
            self.void_type, [self.eigen_value_ptr, self.double_type]
        )
        self.eigen_init = ir.Function(self.module, eigen_init_type, name="eigen_init")
        self.eigen_init.attributes.add("nounwind")

        # eigen_update(eigen*, new_value) -> void
        eigen_update_type = ir.FunctionType(
            self.void_type, [self.eigen_value_ptr, self.double_type]
        )
        self.eigen_update = ir.Function(
            self.module, eigen_update_type, name="eigen_update"
        )
        self.eigen_update.attributes.add("nounwind")

        # eigen_get_value(eigen*) -> double
        eigen_get_value_type = ir.FunctionType(self.double_type, [self.eigen_value_ptr])
        self.eigen_get_value = ir.Function(
            self.module, eigen_get_value_type, name="eigen_get_value"
        )
        self.eigen_get_value.attributes.add("nounwind")
        self.eigen_get_value.attributes.add("readonly")

        # eigen_get_gradient(eigen*) -> double (for 'why')
        eigen_get_gradient_type = ir.FunctionType(
            self.double_type, [self.eigen_value_ptr]
        )
        self.eigen_get_gradient = ir.Function(
            self.module, eigen_get_gradient_type, name="eigen_get_gradient"
        )
        self.eigen_get_gradient.attributes.add("nounwind")
        self.eigen_get_gradient.attributes.add("readonly")

        # eigen_get_stability(eigen*) -> double (for 'how')
        eigen_get_stability_type = ir.FunctionType(
            self.double_type, [self.eigen_value_ptr]
        )
        self.eigen_get_stability = ir.Function(
            self.module, eigen_get_stability_type, name="eigen_get_stability"
        )
        self.eigen_get_stability.attributes.add("nounwind")
        self.eigen_get_stability.attributes.add("readonly")

        # eigen_get_iteration(eigen*) -> i64 (for 'when')
        eigen_get_iteration_type = ir.FunctionType(
            self.int64_type, [self.eigen_value_ptr]
        )
        self.eigen_get_iteration = ir.Function(
            self.module, eigen_get_iteration_type, name="eigen_get_iteration"
        )
        self.eigen_get_iteration.attributes.add("nounwind")
        self.eigen_get_iteration.attributes.add("readonly")

        # eigen_check_converged(eigen*) -> bool
        eigen_check_converged_type = ir.FunctionType(
            self.bool_type, [self.eigen_value_ptr]
        )
        self.eigen_check_converged = ir.Function(
            self.module, eigen_check_converged_type, name="eigen_check_converged"
        )
        self.eigen_check_converged.attributes.add("nounwind")
        self.eigen_check_converged.attributes.add("readonly")

        # eigen_check_diverging(eigen*) -> bool
        eigen_check_diverging_type = ir.FunctionType(
            self.bool_type, [self.eigen_value_ptr]
        )
        self.eigen_check_diverging = ir.Function(
            self.module, eigen_check_diverging_type, name="eigen_check_diverging"
        )
        self.eigen_check_diverging.attributes.add("nounwind")
        self.eigen_check_diverging.attributes.add("readonly")

        # eigen_check_oscillating(eigen*) -> bool
        eigen_check_oscillating_type = ir.FunctionType(
            self.bool_type, [self.eigen_value_ptr]
        )
        self.eigen_check_oscillating = ir.Function(
            self.module, eigen_check_oscillating_type, name="eigen_check_oscillating"
        )
        self.eigen_check_oscillating.attributes.add("nounwind")
        self.eigen_check_oscillating.attributes.add("readonly")

        # eigen_check_stable(eigen*) -> bool
        eigen_check_stable_type = ir.FunctionType(
            self.bool_type, [self.eigen_value_ptr]
        )
        self.eigen_check_stable = ir.Function(
            self.module, eigen_check_stable_type, name="eigen_check_stable"
        )
        self.eigen_check_stable.attributes.add("nounwind")
        self.eigen_check_stable.attributes.add("readonly")

        # eigen_check_improving(eigen*) -> bool
        eigen_check_improving_type = ir.FunctionType(
            self.bool_type, [self.eigen_value_ptr]
        )
        self.eigen_check_improving = ir.Function(
            self.module, eigen_check_improving_type, name="eigen_check_improving"
        )
        self.eigen_check_improving.attributes.add("nounwind")
        self.eigen_check_improving.attributes.add("readonly")

        # List runtime functions
        # eigen_list_create(length) -> EigenList*
        eigen_list_create_type = ir.FunctionType(self.eigen_list_ptr, [self.int64_type])
        self.eigen_list_create = ir.Function(
            self.module, eigen_list_create_type, name="eigen_list_create"
        )
        self.eigen_list_create.attributes.add("nounwind")

        # eigen_list_get(list*, index) -> double
        eigen_list_get_type = ir.FunctionType(
            self.double_type, [self.eigen_list_ptr, self.int64_type]
        )
        self.eigen_list_get = ir.Function(
            self.module, eigen_list_get_type, name="eigen_list_get"
        )
        self.eigen_list_get.attributes.add("nounwind")
        self.eigen_list_get.attributes.add("readonly")

        # eigen_list_set(list*, index, value) -> void
        eigen_list_set_type = ir.FunctionType(
            self.void_type, [self.eigen_list_ptr, self.int64_type, self.double_type]
        )
        self.eigen_list_set = ir.Function(
            self.module, eigen_list_set_type, name="eigen_list_set"
        )
        self.eigen_list_set.attributes.add("nounwind")

        # eigen_list_length(list*) -> i64
        eigen_list_length_type = ir.FunctionType(self.int64_type, [self.eigen_list_ptr])
        self.eigen_list_length = ir.Function(
            self.module, eigen_list_length_type, name="eigen_list_length"
        )
        self.eigen_list_length.attributes.add("nounwind")
        self.eigen_list_length.attributes.add("readonly")

        # Cleanup functions (memory management)
        # eigen_destroy(eigen*) -> void
        eigen_destroy_type = ir.FunctionType(self.void_type, [self.eigen_value_ptr])
        self.eigen_destroy = ir.Function(
            self.module, eigen_destroy_type, name="eigen_destroy"
        )
        self.eigen_destroy.attributes.add("nounwind")

        # eigen_list_destroy(list*) -> void
        eigen_list_destroy_type = ir.FunctionType(self.void_type, [self.eigen_list_ptr])
        self.eigen_list_destroy = ir.Function(
            self.module, eigen_list_destroy_type, name="eigen_list_destroy"
        )
        self.eigen_list_destroy.attributes.add("nounwind")

        # eigen_list_append(list*, value) -> void
        eigen_list_append_type = ir.FunctionType(
            self.void_type, [self.eigen_list_ptr, self.double_type]
        )
        self.eigen_list_append = ir.Function(
            self.module, eigen_list_append_type, name="eigen_list_append"
        )
        self.eigen_list_append.attributes.add("nounwind")

        # ============================================================
        # String Runtime Functions (for self-hosting)
        # ============================================================

        # eigen_string_create(char*) -> EigenString*
        eigen_string_create_type = ir.FunctionType(
            self.eigen_string_ptr, [self.string_type]
        )
        self.eigen_string_create = ir.Function(
            self.module, eigen_string_create_type, name="eigen_string_create"
        )
        self.eigen_string_create.attributes.add("nounwind")

        # eigen_string_create_empty(i64 capacity) -> EigenString*
        eigen_string_create_empty_type = ir.FunctionType(
            self.eigen_string_ptr, [self.int64_type]
        )
        self.eigen_string_create_empty = ir.Function(
            self.module,
            eigen_string_create_empty_type,
            name="eigen_string_create_empty",
        )
        self.eigen_string_create_empty.attributes.add("nounwind")

        # eigen_string_destroy(EigenString*) -> void
        eigen_string_destroy_type = ir.FunctionType(
            self.void_type, [self.eigen_string_ptr]
        )
        self.eigen_string_destroy = ir.Function(
            self.module, eigen_string_destroy_type, name="eigen_string_destroy"
        )
        self.eigen_string_destroy.attributes.add("nounwind")

        # eigen_string_length(EigenString*) -> i64
        eigen_string_length_type = ir.FunctionType(
            self.int64_type, [self.eigen_string_ptr]
        )
        self.eigen_string_length = ir.Function(
            self.module, eigen_string_length_type, name="eigen_string_length"
        )
        self.eigen_string_length.attributes.add("nounwind")
        self.eigen_string_length.attributes.add("readonly")

        # eigen_char_at(EigenString*, i64 index) -> i64
        eigen_char_at_type = ir.FunctionType(
            self.int64_type, [self.eigen_string_ptr, self.int64_type]
        )
        self.eigen_char_at = ir.Function(
            self.module, eigen_char_at_type, name="eigen_char_at"
        )
        self.eigen_char_at.attributes.add("nounwind")
        self.eigen_char_at.attributes.add("readonly")

        # eigen_substring(EigenString*, i64 start, i64 length) -> EigenString*
        eigen_substring_type = ir.FunctionType(
            self.eigen_string_ptr,
            [self.eigen_string_ptr, self.int64_type, self.int64_type],
        )
        self.eigen_substring = ir.Function(
            self.module, eigen_substring_type, name="eigen_substring"
        )
        self.eigen_substring.attributes.add("nounwind")

        # eigen_string_concat(EigenString*, EigenString*) -> EigenString*
        eigen_string_concat_type = ir.FunctionType(
            self.eigen_string_ptr, [self.eigen_string_ptr, self.eigen_string_ptr]
        )
        self.eigen_string_concat = ir.Function(
            self.module, eigen_string_concat_type, name="eigen_string_concat"
        )
        self.eigen_string_concat.attributes.add("nounwind")

        # eigen_string_append_char(EigenString*, i64 char_code) -> void
        eigen_string_append_char_type = ir.FunctionType(
            self.void_type, [self.eigen_string_ptr, self.int64_type]
        )
        self.eigen_string_append_char = ir.Function(
            self.module, eigen_string_append_char_type, name="eigen_string_append_char"
        )
        self.eigen_string_append_char.attributes.add("nounwind")

        # eigen_string_equals(EigenString*, EigenString*) -> i64
        eigen_string_equals_type = ir.FunctionType(
            self.int64_type, [self.eigen_string_ptr, self.eigen_string_ptr]
        )
        self.eigen_string_equals = ir.Function(
            self.module, eigen_string_equals_type, name="eigen_string_equals"
        )
        self.eigen_string_equals.attributes.add("nounwind")
        self.eigen_string_equals.attributes.add("readonly")

        # eigen_string_compare(EigenString*, EigenString*) -> i64
        eigen_string_compare_type = ir.FunctionType(
            self.int64_type, [self.eigen_string_ptr, self.eigen_string_ptr]
        )
        self.eigen_string_compare = ir.Function(
            self.module, eigen_string_compare_type, name="eigen_string_compare"
        )
        self.eigen_string_compare.attributes.add("nounwind")
        self.eigen_string_compare.attributes.add("readonly")

        # Character classification functions
        # eigen_char_is_digit(i64) -> i64
        char_class_type = ir.FunctionType(self.int64_type, [self.int64_type])

        self.eigen_char_is_digit = ir.Function(
            self.module, char_class_type, name="eigen_char_is_digit"
        )
        self.eigen_char_is_digit.attributes.add("nounwind")
        self.eigen_char_is_digit.attributes.add("readonly")

        self.eigen_char_is_alpha = ir.Function(
            self.module, char_class_type, name="eigen_char_is_alpha"
        )
        self.eigen_char_is_alpha.attributes.add("nounwind")
        self.eigen_char_is_alpha.attributes.add("readonly")

        self.eigen_char_is_alnum = ir.Function(
            self.module, char_class_type, name="eigen_char_is_alnum"
        )
        self.eigen_char_is_alnum.attributes.add("nounwind")
        self.eigen_char_is_alnum.attributes.add("readonly")

        self.eigen_char_is_whitespace = ir.Function(
            self.module, char_class_type, name="eigen_char_is_whitespace"
        )
        self.eigen_char_is_whitespace.attributes.add("nounwind")
        self.eigen_char_is_whitespace.attributes.add("readonly")

        self.eigen_char_is_newline = ir.Function(
            self.module, char_class_type, name="eigen_char_is_newline"
        )
        self.eigen_char_is_newline.attributes.add("nounwind")
        self.eigen_char_is_newline.attributes.add("readonly")

        # eigen_char_to_string(i64) -> EigenString*
        eigen_char_to_string_type = ir.FunctionType(
            self.eigen_string_ptr, [self.int64_type]
        )
        self.eigen_char_to_string = ir.Function(
            self.module, eigen_char_to_string_type, name="eigen_char_to_string"
        )
        self.eigen_char_to_string.attributes.add("nounwind")

        # eigen_number_to_string(double) -> EigenString*
        eigen_number_to_string_type = ir.FunctionType(
            self.eigen_string_ptr, [self.double_type]
        )
        self.eigen_number_to_string = ir.Function(
            self.module, eigen_number_to_string_type, name="eigen_number_to_string"
        )
        self.eigen_number_to_string.attributes.add("nounwind")

        # eigen_string_to_number(EigenString*) -> double
        eigen_string_to_number_type = ir.FunctionType(
            self.double_type, [self.eigen_string_ptr]
        )
        self.eigen_string_to_number = ir.Function(
            self.module, eigen_string_to_number_type, name="eigen_string_to_number"
        )
        self.eigen_string_to_number.attributes.add("nounwind")
        self.eigen_string_to_number.attributes.add("readonly")

        # eigen_string_find(EigenString*, EigenString*, i64 start) -> i64
        eigen_string_find_type = ir.FunctionType(
            self.int64_type,
            [self.eigen_string_ptr, self.eigen_string_ptr, self.int64_type],
        )
        self.eigen_string_find = ir.Function(
            self.module, eigen_string_find_type, name="eigen_string_find"
        )
        self.eigen_string_find.attributes.add("nounwind")
        self.eigen_string_find.attributes.add("readonly")

        # eigen_string_cstr(EigenString*) -> char*
        eigen_string_cstr_type = ir.FunctionType(
            self.string_type, [self.eigen_string_ptr]
        )
        self.eigen_string_cstr = ir.Function(
            self.module, eigen_string_cstr_type, name="eigen_string_cstr"
        )
        self.eigen_string_cstr.attributes.add("nounwind")
        self.eigen_string_cstr.attributes.add("readonly")

        # ============================================================
        # File I/O Functions (for self-hosting)
        # ============================================================

        # eigen_file_read(EigenString* filename) -> EigenString*
        eigen_file_read_type = ir.FunctionType(
            self.eigen_string_ptr, [self.eigen_string_ptr]
        )
        self.eigen_file_read = ir.Function(
            self.module, eigen_file_read_type, name="eigen_file_read"
        )
        self.eigen_file_read.attributes.add("nounwind")

        # eigen_file_write(EigenString* filename, EigenString* contents) -> i64
        eigen_file_write_type = ir.FunctionType(
            self.int64_type, [self.eigen_string_ptr, self.eigen_string_ptr]
        )
        self.eigen_file_write = ir.Function(
            self.module, eigen_file_write_type, name="eigen_file_write"
        )
        self.eigen_file_write.attributes.add("nounwind")

        # eigen_file_append(EigenString* filename, EigenString* contents) -> i64
        eigen_file_append_type = ir.FunctionType(
            self.int64_type, [self.eigen_string_ptr, self.eigen_string_ptr]
        )
        self.eigen_file_append = ir.Function(
            self.module, eigen_file_append_type, name="eigen_file_append"
        )
        self.eigen_file_append.attributes.add("nounwind")

    def ensure_scalar(self, gen_val: Union[GeneratedValue, ir.Value]) -> ir.Value:
        """Convert a GeneratedValue to a scalar double.

        This is used when arithmetic, comparisons, or printing need raw values.
        If given an EigenValue* pointer, extracts the value field.
        If given a raw ir.Value, assumes it's already a scalar and returns it.
        Handles conversion of boolean (i1) to double (1.0 or 0.0).
        """
        # Backward compatibility: if passed raw ir.Value, assume it's a scalar
        if isinstance(gen_val, ir.Value):
            # Check if it's a boolean that needs conversion to double
            if isinstance(gen_val.type, ir.IntType) and gen_val.type.width == 1:
                # Convert i1 to double: 0 -> 0.0, 1 -> 1.0
                return self.builder.uitofp(gen_val, self.double_type)
            return gen_val

        if gen_val.kind == ValueKind.SCALAR:
            scalar_val = gen_val.value
            # Check if it's a boolean that needs conversion to double
            if isinstance(scalar_val.type, ir.IntType) and scalar_val.type.width == 1:
                return self.builder.uitofp(scalar_val, self.double_type)
            return scalar_val
        elif gen_val.kind == ValueKind.EIGEN_PTR:
            # Dereference the EigenValue* to get the value
            return self.builder.call(self.eigen_get_value, [gen_val.value])
        elif gen_val.kind == ValueKind.LIST_PTR:
            raise TypeError("Cannot convert list to scalar")
        elif gen_val.kind == ValueKind.STRING_PTR:
            # Convert pointer to i64, then to double (for storage in lists)
            ptr_int = self.builder.ptrtoint(gen_val.value, self.int64_type)
            return self.builder.bitcast(ptr_int, self.double_type)
        elif gen_val.kind == ValueKind.STRUCT_PTR:
            # Convert pointer to i64, then to double (for storage in lists)
            ptr_int = self.builder.ptrtoint(gen_val.value, self.int64_type)
            return self.builder.bitcast(ptr_int, self.double_type)
        elif gen_val.kind == ValueKind.PACKED_I64:
            # Function parameter packed as i64, bitcast to double for numeric ops
            return self.builder.bitcast(gen_val.value, self.double_type)
        else:
            raise ValueError(f"Unknown ValueKind: {gen_val.kind}")

    def ensure_eigen_ptr(self, gen_val: Union[GeneratedValue, ir.Value]) -> ir.Value:
        """Convert a GeneratedValue to an EigenValue* pointer.

        This is used when we need to store or pass geometric state.
        If given a scalar, wraps it in a new EigenValue.
        If given an EigenValue*, returns it directly (enabling aliasing).

        NOTE: Only track heap allocations in main scope for cleanup.
        Functions manage their own temporary allocations.
        """
        # Backward compatibility: if passed raw ir.Value, assume it's a scalar
        if isinstance(gen_val, ir.Value):
            eigen_ptr = self.builder.call(self.eigen_create, [gen_val])
            # Only track allocations in main scope (not in functions)
            if self.current_function and self.current_function.name == "main":
                self.allocated_eigenvalues.append(eigen_ptr)
            return eigen_ptr

        if gen_val.kind == ValueKind.SCALAR:
            # Wrap scalar in new EigenValue
            eigen_ptr = self.builder.call(self.eigen_create, [gen_val.value])
            # Only track allocations in main scope (not in functions)
            if self.current_function and self.current_function.name == "main":
                self.allocated_eigenvalues.append(eigen_ptr)
            return eigen_ptr
        elif gen_val.kind == ValueKind.EIGEN_PTR:
            # Already a pointer, return directly (this enables aliasing!)
            return gen_val.value
        elif gen_val.kind == ValueKind.LIST_PTR:
            raise TypeError("Cannot convert list to EigenValue")
        elif gen_val.kind == ValueKind.PACKED_I64:
            # Function parameter - bitcast to double and wrap in EigenValue
            scalar_val = self.builder.bitcast(gen_val.value, self.double_type)
            eigen_ptr = self.builder.call(self.eigen_create, [scalar_val])
            if self.current_function and self.current_function.name == "main":
                self.allocated_eigenvalues.append(eigen_ptr)
            return eigen_ptr
        elif gen_val.kind == ValueKind.STRING_PTR:
            raise TypeError("Cannot convert string to EigenValue")
        elif gen_val.kind == ValueKind.STRUCT_PTR:
            raise TypeError("Cannot convert struct to EigenValue")
        else:
            raise ValueError(f"Unknown ValueKind: {gen_val.kind}")

    def ensure_bool(self, val: Union[GeneratedValue, ir.Value]) -> ir.Value:
        """
        Convert any value to an i1 boolean for branching.
        - i1: returns as-is
        - double: returns (val != 0.0)
        - ptr: returns (val != null)
        """
        # Handle GeneratedValue wrapper
        if isinstance(val, GeneratedValue):
            val = val.value

        if val.type == self.bool_type:
            return val

        if val.type == self.double_type:
            # Compare != 0.0
            return self.builder.fcmp_ordered(
                "!=", val, ir.Constant(self.double_type, 0.0)
            )

        if isinstance(val.type, ir.PointerType):
            # Compare != null
            return self.builder.icmp_unsigned("!=", val, ir.Constant(val.type, None))

        raise CompilerError(f"Cannot convert type {val.type} to boolean")

    def _ensure_string_ptr(self, val: Union[GeneratedValue, ir.Value]) -> ir.Value:
        """Extract EigenString* from a GeneratedValue or raw ir.Value.

        Used by string builtin functions to get the string pointer.
        """
        if isinstance(val, GeneratedValue):
            if val.kind == ValueKind.STRING_PTR:
                return val.value
            elif val.kind == ValueKind.PACKED_I64:
                # Function parameter that might be a string pointer
                return self.builder.inttoptr(val.value, self.eigen_string_ptr)
            else:
                raise CompilerError(
                    f"Expected string, got {val.kind}",
                    hint="String operations require EigenString* values",
                )
        elif isinstance(val, ir.Value):
            # Check if it's already an EigenString*
            if isinstance(val.type, ir.PointerType):
                return val
            # Handle i64 (packed pointer from function parameter)
            elif val.type == self.int64_type:
                return self.builder.inttoptr(val, self.eigen_string_ptr)
            # Handle double (might be a packed pointer passed through)
            elif val.type == self.double_type:
                # Convert double -> i64 -> pointer
                i64_val = self.builder.bitcast(val, self.int64_type)
                return self.builder.inttoptr(i64_val, self.eigen_string_ptr)
            else:
                raise CompilerError(
                    f"Expected string pointer, got {val.type}",
                    hint="String operations require EigenString* values",
                )
        else:
            raise CompilerError(f"Unexpected value type: {type(val)}")

    def _ensure_int64(self, val: Union[GeneratedValue, ir.Value]) -> ir.Value:
        """Convert a value to i64 for use in string operations.

        EigenScript uses doubles for all numbers, so this converts double -> i64.
        """
        if isinstance(val, GeneratedValue):
            val = val.value

        if val.type == self.int64_type:
            return val
        elif val.type == self.double_type:
            return self.builder.fptosi(val, self.int64_type)
        elif isinstance(val.type, ir.IntType):
            # Extend or truncate to i64
            if val.type.width < 64:
                return self.builder.sext(val, self.int64_type)
            elif val.type.width > 64:
                return self.builder.trunc(val, self.int64_type)
            else:
                return val
        else:
            raise CompilerError(
                f"Cannot convert {val.type} to int64", hint="Expected a numeric value"
            )

    def _pack_to_i64(self, val: Union[GeneratedValue, ir.Value]) -> ir.Value:
        """Pack a value into i64 for function parameter passing.

        - doubles are bitcast to i64
        - pointers are converted via ptrtoint
        - i64 values are passed through
        """
        if isinstance(val, GeneratedValue):
            if val.kind == ValueKind.SCALAR:
                # Bitcast double to i64
                return self.builder.bitcast(val.value, self.int64_type)
            elif val.kind in (
                ValueKind.STRING_PTR,
                ValueKind.LIST_PTR,
                ValueKind.EIGEN_PTR,
                ValueKind.STRUCT_PTR,
            ):
                # Convert pointer to i64
                return self.builder.ptrtoint(val.value, self.int64_type)
            elif val.kind == ValueKind.PACKED_I64:
                # Already i64, pass through
                return val.value
            else:
                raise ValueError(f"Cannot pack {val.kind} to i64")
        elif isinstance(val, ir.Value):
            if val.type == self.double_type:
                return self.builder.bitcast(val, self.int64_type)
            elif val.type == self.int64_type:
                return val
            elif isinstance(val.type, ir.PointerType):
                return self.builder.ptrtoint(val, self.int64_type)
            elif isinstance(val.type, ir.IntType):
                if val.type.width < 64:
                    return self.builder.sext(val, self.int64_type)
                elif val.type.width > 64:
                    return self.builder.trunc(val, self.int64_type)
                return val
            else:
                raise ValueError(f"Cannot pack {val.type} to i64")
        else:
            raise ValueError(f"Cannot pack {type(val)} to i64")

    def _ensure_list_ptr(self, val: Union[GeneratedValue, ir.Value]) -> ir.Value:
        """Extract EigenList* from a GeneratedValue or raw ir.Value.

        Used by list builtin functions to get the list pointer.
        """
        if isinstance(val, GeneratedValue):
            if val.kind == ValueKind.LIST_PTR:
                return val.value
            elif val.kind == ValueKind.PACKED_I64:
                # Function parameter that might be a list pointer
                return self.builder.inttoptr(val.value, self.eigen_list_ptr)
            else:
                raise CompilerError(
                    f"Expected list, got {val.kind}",
                    hint="List operations require EigenList* values",
                )
        elif isinstance(val, ir.Value):
            # Check if it's already an EigenList*
            if isinstance(val.type, ir.PointerType):
                return val
            # Handle i64 (packed pointer from function parameter)
            elif val.type == self.int64_type:
                return self.builder.inttoptr(val, self.eigen_list_ptr)
            # Handle double (might be a packed pointer passed through)
            elif val.type == self.double_type:
                # Convert double -> i64 -> pointer
                i64_val = self.builder.bitcast(val, self.int64_type)
                return self.builder.inttoptr(i64_val, self.eigen_list_ptr)
            else:
                raise CompilerError(
                    f"Expected list pointer, got {val.type}",
                    hint="List operations require EigenList* values",
                )
        else:
            raise CompilerError(f"Unexpected value type: {type(val)}")

    def _extract_list_args(self, node, expected_count: int) -> list:
        """Extract arguments from a list literal for multi-arg builtins.

        Many string functions take multiple arguments via list syntax:
            char_at of [str, index]
            substring of [str, start, length]
        """
        from eigenscript.parser.ast_builder import ListLiteral

        if isinstance(node, ListLiteral):
            if len(node.elements) != expected_count:
                raise CompilerError(
                    f"Expected {expected_count} arguments, got {len(node.elements)}",
                    hint=f"This function requires exactly {expected_count} arguments in a list",
                )
            return [self._generate(elem) for elem in node.elements]
        else:
            # Single argument - wrap in list if expecting 1
            if expected_count == 1:
                return [self._generate(node)]
            else:
                raise CompilerError(
                    f"Expected list with {expected_count} arguments",
                    hint="Use [arg1, arg2, ...] syntax for multiple arguments",
                )

    def _alloca_at_entry(self, ty: ir.Type, name: str = "") -> ir.AllocaInstr:
        """Allocate a variable in the entry block of the current function.

        This ensures all allocas are in the entry block, which is required for
        proper LLVM IR and enables optimizations like mem2reg.

        Args:
            ty: The type to allocate
            name: Optional name for the variable

        Returns:
            The alloca instruction
        """
        if not self.entry_block:
            # If no entry block, just do normal alloca (shouldn't happen in practice)
            return self.builder.alloca(ty, name=name)

        # Save current position
        current_block = self.builder.block

        # Move to the beginning of the entry block (after any existing allocas)
        if self.entry_block.instructions:
            # Find the last alloca instruction in the entry block
            last_alloca = None
            for inst in self.entry_block.instructions:
                if isinstance(inst, ir.AllocaInstr):
                    last_alloca = inst
                else:
                    break  # Stop at first non-alloca

            if last_alloca:
                # Position after the last alloca
                self.builder.position_after(last_alloca)
            else:
                # No allocas yet, position at start
                self.builder.position_at_start(self.entry_block)
        else:
            # Empty entry block, position at start
            self.builder.position_at_start(self.entry_block)

        # Do the allocation
        alloca_inst = self.builder.alloca(ty, name=name)

        # Restore position
        self.builder.position_at_end(current_block)

        return alloca_inst

    def _create_global_variable(
        self, ty: ir.Type, name: str, initial_value=None
    ) -> ir.GlobalVariable:
        """Create a module-level global variable.

        This creates an actual LLVM global that can be accessed from any function.
        Used for EigenScript variables defined in main scope that need to be
        accessed from user-defined functions.

        Args:
            ty: The type of the variable (e.g., double_type, eigen_string_ptr)
            name: Name for the global variable
            initial_value: Optional initial value (must match type)

        Returns:
            The global variable (as a pointer to the value type)
        """
        # Create a unique name to avoid conflicts
        global_name = f"__eigs_global_{name}"

        # Create the global variable
        global_var = ir.GlobalVariable(self.module, ty, name=global_name)

        # Determine linkage based on variable name pattern
        # For library modules (is_library=True), only export shared data
        # Shared data prefixes for cross-module communication
        # Everything else (including UPPERCASE_CONSTANTS) is module-private
        if self.is_library:
            shared_prefixes = (
                "lex_",  # Lexer state
                "ast_",  # AST data
                "parser_token_",  # Parser token arrays
                "parser_error",  # Parser error state
                "parser_pos",  # Parser position
                "error_",  # Error arrays
                "last_",  # Lexer string tracking
                "string_pool_",  # String pool
                "symbol_",  # Symbol table
                "scope_",  # Scope tracking
                "output_",  # Codegen output
                "reg_",  # Codegen registers
                "label_",  # Codegen labels
                "var_",  # Codegen variables
            )
            is_shared = name.startswith(shared_prefixes)
            if not is_shared:
                global_var.linkage = "internal"  # Module-private

        # Initialize with default value
        if initial_value is not None:
            global_var.initializer = initial_value
        elif ty == self.double_type:
            global_var.initializer = ir.Constant(self.double_type, 0.0)
        elif isinstance(ty, ir.PointerType):
            global_var.initializer = ir.Constant(ty, None)
        else:
            # For struct types, use zeroinitializer
            global_var.initializer = ir.Constant(ty, None)

        return global_var

    def _declare_external_global(self, name: str, ty: ir.Type) -> ir.GlobalVariable:
        """Declare an external global variable from another module.

        This creates a global variable declaration (no initializer) that
        will be resolved at link time. Used for cross-module references.

        Args:
            name: The global variable name (with module prefix)
            ty: The type of the variable

        Returns:
            The external global variable pointer
        """
        if name in self.external_globals:
            return self.external_globals[name]

        # Create external global - use the raw name for linking
        global_name = f"__eigs_global_{name}"
        global_var = ir.GlobalVariable(self.module, ty, name=global_name)
        global_var.linkage = "external"  # Will be resolved at link time

        self.external_globals[name] = global_var
        return global_var

    def _declare_external_list(self, name: str) -> ir.GlobalVariable:
        """Declare an external list variable from another module.

        This is separate from _declare_external_global because lists need
        EigenList* type for proper list operations.
        """
        # Check if already declared as a list
        list_key = f"__list__{name}"
        if list_key in self.external_globals:
            return self.external_globals[list_key]

        global_name = f"__eigs_global_{name}"
        global_var = ir.GlobalVariable(
            self.module, self.eigen_list_ptr, name=global_name
        )
        global_var.linkage = "external"

        self.external_globals[list_key] = global_var
        return global_var

    def _declare_external_function(self, name: str, num_params: int = 1) -> ir.Function:
        """Declare an external function from another module.

        This creates a function declaration that will be resolved at link time.
        Used for cross-module function calls.

        Args:
            name: The function name (may include module prefix)
            num_params: Number of parameters (default 1)

        Returns:
            The external function declaration
        """
        if name in self.external_functions:
            return self.external_functions[name]

        # Create function type: all params are i64, returns i64
        param_types = [self.int64_type] * num_params
        func_type = ir.FunctionType(self.int64_type, param_types)

        # Create function declaration
        func = ir.Function(self.module, func_type, name=name)
        func.attributes.add("nounwind")

        self.external_functions[name] = func
        return func

    def _create_eigen_on_stack(self, initial_value: ir.Value) -> ir.Value:
        """Create an EigenValue on the stack (fast, auto-freed).

        This is THE critical optimization for recursion performance:
        - alloca: O(1) stack pointer shift (1 CPU instruction)
        - eigen_init: O(1) field initialization (no memset on history array)
        - Total: ~20-30x faster than malloc + memset

        Stack allocation eliminates:
        1. malloc's heap search overhead (hundreds of instructions)
        2. memset's O(100) zeroing of history array
        3. Cache misses from scattered heap allocations

        Stack memory is "hot" in L1 cache, heap is scattered and cold.

        Args:
            initial_value: The initial double value to store

        Returns:
            Pointer to the stack-allocated EigenValue struct
        """
        # 1. Allocate EigenValue struct on stack (O(1) - just shifts stack pointer)
        #    Generates: %name = alloca %struct.EigenValue
        eigen_stack = self.builder.alloca(self.eigen_value_type, name="eigen_stack")

        # 2. Initialize in-place using eigen_init (O(1) - lazy history init)
        #    Generates: call void @eigen_init(%name, %val)
        #    This is MUCH faster than manually setting 9 fields via GEP
        self.builder.call(self.eigen_init, [eigen_stack, initial_value])

        return eigen_stack

    def _generate_cleanup(self) -> None:
        """Generate cleanup code to free all allocated EigenValues, lists, and strings.

        This should be called before any return statement to prevent memory leaks.
        """
        # Free all tracked EigenValue pointers
        for eigen_ptr in self.allocated_eigenvalues:
            self.builder.call(self.eigen_destroy, [eigen_ptr])

        # Free all tracked EigenList pointers
        for list_ptr in self.allocated_lists:
            self.builder.call(self.eigen_list_destroy, [list_ptr])

        # Free all tracked EigenString pointers
        for string_ptr in self.allocated_strings:
            self.builder.call(self.eigen_string_destroy, [string_ptr])

    def link_runtime_bitcode(
        self, llvm_module: llvm.ModuleRef, target_triple: str = None
    ) -> llvm.ModuleRef:
        """Link runtime bitcode for LTO (Link-Time Optimization).

        This merges the C runtime functions into the generated module,
        allowing LLVM to inline eigen_get_value, eigen_init, etc.

        Expected performance impact:
        - Function call overhead eliminated (~2-5 cycles per call)
        - Direct struct field access instead of function calls
        - Better register allocation across runtime boundary
        - Target: <10ms for Fibonacci(25) vs current 209ms

        Args:
            llvm_module: The parsed LLVM module from our generated IR
            target_triple: Optional target triple for cross-compilation

        Returns:
            Linked module with runtime functions inlined
        """
        # Find runtime bitcode
        runtime_dir = os.path.dirname(__file__)

        # Try target-specific bitcode first
        if target_triple:
            target_bc = os.path.join(
                runtime_dir, f"../runtime/build/{target_triple}/eigenvalue.bc"
            )
            if os.path.exists(target_bc):
                runtime_bc = target_bc
            else:
                # Fall back to default
                runtime_bc = os.path.join(runtime_dir, "../runtime/eigenvalue.bc")
        else:
            runtime_bc = os.path.join(runtime_dir, "../runtime/eigenvalue.bc")

        if not os.path.exists(runtime_bc):
            import warnings

            warnings.warn(
                f"Runtime bitcode not found at {runtime_bc}. "
                "Performance will be degraded. Run: python3 runtime/build_runtime.py",
                RuntimeWarning,
            )
            return llvm_module

        # Load runtime bitcode
        with open(runtime_bc, "rb") as f:
            bc_data = f.read()

        # Parse runtime module
        runtime_mod = llvm.parse_bitcode(bc_data)

        # Link modules (merges runtime definitions into our module)
        # This allows LLVM optimizer to see inside runtime functions
        llvm.link_modules(llvm_module, runtime_mod)

        return llvm_module

    def compile(
        self, ast_nodes: list[ASTNode], imported_modules: list[str] = None
    ) -> str:
        """Compile a list of AST nodes to LLVM IR.

        Args:
            ast_nodes: List of AST nodes to compile
            imported_modules: List of module names that were imported (for init calls)
        """

        # Reset cleanup tracking for this compilation
        # (Important: prevents stale references from previous compilations)
        self.allocated_eigenvalues = []
        self.allocated_lists = []
        self.allocated_strings = []
        self.struct_var_types = {}  # Maps variable name -> struct type name

        # Create entry function based on compilation mode
        if self.is_library:
            # Library mode: Create module_init function
            func_name = f"{self.module_prefix}init"
            func_type = ir.FunctionType(self.void_type, [])
            entry_func = ir.Function(self.module, func_type, name=func_name)
            entry_func.attributes.add("nounwind")
            block = entry_func.append_basic_block(name="entry")
            self.builder = ir.IRBuilder(block)
            self.current_function = entry_func
            self.entry_block = block
        else:
            # Program mode: Create main function with argc/argv for CLI support
            # int main(int argc, char** argv)
            char_ptr_ptr = self.string_type.as_pointer()  # char**
            main_type = ir.FunctionType(
                self.int32_type, [self.int32_type, char_ptr_ptr]
            )
            main_func = ir.Function(self.module, main_type, name="main")
            main_func.attributes.add("nounwind")  # No exceptions
            main_func.args[0].name = "argc"
            main_func.args[1].name = "argv"
            block = main_func.append_basic_block(name="entry")
            self.builder = ir.IRBuilder(block)
            self.current_function = main_func
            self.entry_block = block  # Store entry block for proper alloca placement

            # Create global variables to store argc/argv for builtin access
            self.argc_global = ir.GlobalVariable(
                self.module, self.int32_type, name="__eigs_argc"
            )
            self.argc_global.initializer = ir.Constant(self.int32_type, 0)

            self.argv_global = ir.GlobalVariable(
                self.module, char_ptr_ptr, name="__eigs_argv"
            )
            self.argv_global.initializer = ir.Constant(char_ptr_ptr, None)

            # Store argc/argv in globals at program start
            self.builder.store(main_func.args[0], self.argc_global)
            self.builder.store(main_func.args[1], self.argv_global)

            # Phase 4.4: Call module initialization functions
            # Before executing main logic, initialize all imported modules
            if imported_modules:
                for module_name in imported_modules:
                    # Declare the module's init function
                    init_func_name = f"{module_name}_init"
                    init_func_type = ir.FunctionType(self.void_type, [])
                    init_func = ir.Function(
                        self.module, init_func_type, name=init_func_name
                    )
                    init_func.attributes.add("nounwind")

                    # Call the init function
                    self.builder.call(init_func, [])

        # FIRST PASS: Declare all functions (for forward references)
        for node in ast_nodes:
            if isinstance(node, FunctionDef):
                self._declare_function(node)

        # SECOND PASS: Generate code for each statement
        for node in ast_nodes:
            self._generate(node)

        # Cleanup: free all allocated memory before return
        self._generate_cleanup()

        # Return based on compilation mode
        if self.is_library:
            # Library init functions return void
            self.builder.ret_void()
        else:
            # Main returns 0
            self.builder.ret(ir.Constant(self.int32_type, 0))

        return str(self.module)

    def _generate(self, node: ASTNode) -> ir.Value:
        """Generate LLVM IR for an AST node."""

        if isinstance(node, Literal):
            return self._generate_literal(node)
        elif isinstance(node, Identifier):
            return self._generate_identifier(node)
        elif isinstance(node, BinaryOp):
            return self._generate_binary_op(node)
        elif isinstance(node, UnaryOp):
            return self._generate_unary_op(node)
        elif isinstance(node, Assignment):
            return self._generate_assignment(node)
        elif isinstance(node, Relation):
            return self._generate_relation(node)
        elif isinstance(node, Conditional):
            return self._generate_conditional(node)
        elif isinstance(node, Loop):
            return self._generate_loop(node)
        elif isinstance(node, Interrogative):
            return self._generate_interrogative(node)
        elif isinstance(node, FunctionDef):
            return self._generate_function_def(node)
        elif isinstance(node, Return):
            return self._generate_return(node)
        elif isinstance(node, Break):
            return self._generate_break(node)
        elif isinstance(node, ListLiteral):
            return self._generate_list_literal(node)
        elif isinstance(node, Index):
            return self._generate_index(node)
        elif isinstance(node, Import):
            # Import statements are no-ops in code generation
            # Module linking is handled by compile.py during recursive compilation
            return None
        elif isinstance(node, MemberAccess):
            return self._generate_member_access(node)
        elif isinstance(node, StructDef):
            return self._generate_struct_def(node)
        elif isinstance(node, StructLiteral):
            return self._generate_struct_literal(node)
        elif isinstance(node, IndexedAssignment):
            return self._generate_indexed_assignment(node)
        else:
            raise CompilerError(
                f"Code generation for '{type(node).__name__}' not implemented",
                hint="This language feature may not be supported yet. "
                "Check the documentation or file an issue.",
                node=node,
            )

    def _generate_literal(self, node: Literal) -> ir.Value:
        """Generate code for a literal value."""
        if node.literal_type == "number":
            return ir.Constant(self.double_type, float(node.value))
        elif node.literal_type == "string":
            # String literals - create global constant C string, then wrap in EigenString
            string_val = node.value + "\0"
            string_const = ir.Constant(
                ir.ArrayType(self.int8_type, len(string_val)),
                bytearray(string_val.encode("utf-8")),
            )
            global_str = ir.GlobalVariable(
                self.module, string_const.type, name=f"str_{id(node)}"
            )
            global_str.global_constant = True
            global_str.initializer = string_const
            c_str_ptr = self.builder.bitcast(global_str, self.string_type)

            # Create EigenString* from the C string
            # This enables native string operations in compiled code
            eigen_str = self.builder.call(self.eigen_string_create, [c_str_ptr])

            # Track for cleanup (only in main scope)
            if self.current_function and self.current_function.name == "main":
                self.allocated_strings.append(eigen_str)

            return GeneratedValue(value=eigen_str, kind=ValueKind.STRING_PTR)
        else:
            raise NotImplementedError(
                f"Literal type {node.literal_type} not implemented"
            )

    def _generate_identifier(self, node: Identifier) -> ir.Value:
        """Generate code for variable access."""
        # Check if this is a boolean constant
        if node.name == "True":
            return GeneratedValue(
                value=ir.Constant(self.bool_type, 1), kind=ValueKind.SCALAR
            )
        elif node.name == "False":
            return GeneratedValue(
                value=ir.Constant(self.bool_type, 0), kind=ValueKind.SCALAR
            )

        # Check if this is a predicate
        if node.name in [
            "converged",
            "diverging",
            "oscillating",
            "stable",
            "improving",
        ]:
            # Get the last assigned variable (simplified - should be explicit in real code)
            if self.local_vars:
                last_var_name = list(self.local_vars.keys())[-1]
                var_ptr = self.local_vars[last_var_name]

                # Check if this variable is a raw double (Scalar Fast Path) or EigenValue
                if isinstance(var_ptr.type.pointee, ir.DoubleType):
                    # FAST PATH variable: No geometric tracking available
                    # Predicates always return False for unobserved variables
                    # This is semantically correct: unobserved = not tracked = assume stable
                    return GeneratedValue(
                        value=ir.Constant(self.bool_type, 0), kind=ValueKind.SCALAR
                    )

                # EigenValue variable: Load and check predicate
                eigen_ptr = self.builder.load(var_ptr)

                # Call the appropriate predicate function
                if node.name == "converged":
                    return self.builder.call(self.eigen_check_converged, [eigen_ptr])
                elif node.name == "diverging":
                    return self.builder.call(self.eigen_check_diverging, [eigen_ptr])
                elif node.name == "oscillating":
                    return self.builder.call(self.eigen_check_oscillating, [eigen_ptr])
                elif node.name == "stable":
                    return self.builder.call(self.eigen_check_stable, [eigen_ptr])
                elif node.name == "improving":
                    return self.builder.call(self.eigen_check_improving, [eigen_ptr])

        if node.name in self.local_vars:
            var_ptr = self.local_vars[node.name]
        elif node.name in self.global_vars:
            var_ptr = self.global_vars[node.name]
        elif node.name in self.external_globals:
            var_ptr = self.external_globals[node.name]
        else:
            # Check if we're in a user-defined function and this could be external
            in_user_func = (
                self.current_function
                and self.current_function.name != self.entry_function_name
            )
            # Also check if this is an imported name (from another module)
            is_import = node.name in self.imported_names
            if in_user_func or is_import:
                # Auto-declare as external global with double type (universal scalar)
                # This enables cross-module references to be resolved at link time
                # For lists, we use _declare_external_list in list-specific contexts
                var_ptr = self._declare_external_global(node.name, self.double_type)
            else:
                # Better error with suggestions
                available_vars = list(self.local_vars.keys()) + list(
                    self.global_vars.keys()
                )
                hint = "No variables defined yet"
                if available_vars:
                    # Find similar names (simple edit distance)
                    similar = [v for v in available_vars if v[0] == node.name[0]]
                    if similar:
                        hint = f"Did you mean: {', '.join(similar[:3])}?"
                    else:
                        hint = f"Available variables: {', '.join(available_vars[:5])}"

                raise CompilerError(
                    f"Undefined variable '{node.name}'", hint=hint, node=node
                )

        # OBSERVER EFFECT: Check what type of variable this is
        # Fast path variables are raw double*, slow path are EigenValue*

        # Check the pointee type to determine variable kind
        if isinstance(var_ptr.type.pointee, ir.DoubleType):
            # FAST PATH: Raw double variable (unobserved)
            # Just load the value directly - no function call overhead!
            return self.builder.load(var_ptr)

        # Handle i64 parameters (universal type for function parameters)
        # Return as PACKED_I64 to preserve potential pointer information
        # Context-specific operations (print, string_length) can interpret as pointer
        # Numeric operations will convert to double via ensure_scalar
        if var_ptr.type.pointee == self.int64_type:
            loaded_i64 = self.builder.load(var_ptr)
            return GeneratedValue(value=loaded_i64, kind=ValueKind.PACKED_I64)

        # Otherwise, load the pointer and check what it points to
        loaded_ptr = self.builder.load(var_ptr)

        # Check if it's a struct variable
        if hasattr(self, "struct_var_types") and node.name in self.struct_var_types:
            struct_name = self.struct_var_types[node.name]
            return GeneratedValue(
                value=loaded_ptr, kind=ValueKind.STRUCT_PTR, struct_name=struct_name
            )

        # Check if it's a string or list (both have 3-element struct with pointer first)
        if isinstance(loaded_ptr.type, ir.PointerType):
            pointed_type = loaded_ptr.type.pointee
            if (
                isinstance(pointed_type, ir.LiteralStructType)
                and len(pointed_type.elements) == 3
                and isinstance(pointed_type.elements[0], ir.PointerType)
            ):
                # Check if first element is char* (string) or double* (list)
                first_elem = pointed_type.elements[0]
                if (
                    isinstance(first_elem.pointee, ir.IntType)
                    and first_elem.pointee.width == 8
                ):
                    # It's a string (char* = i8*)
                    return GeneratedValue(value=loaded_ptr, kind=ValueKind.STRING_PTR)
                else:
                    # It's a list (double*)
                    return loaded_ptr

        # It's an EigenValue - get the actual value
        return self.builder.call(self.eigen_get_value, [loaded_ptr])

    def _generate_binary_op(self, node: BinaryOp) -> ir.Value:
        """Generate code for binary operations.

        Binary ops need scalar values, so we convert both operands using ensure_scalar().
        This allows mixing literals, variables, and interrogative results seamlessly.
        """
        left_gen = self._generate(node.left)
        right_gen = self._generate(node.right)

        # Convert to scalars (handles aliases from interrogatives)
        left = self.ensure_scalar(left_gen)
        right = self.ensure_scalar(right_gen)

        if node.operator == "+":
            return self.builder.fadd(left, right)
        elif node.operator == "-":
            return self.builder.fsub(left, right)
        elif node.operator == "*":
            return self.builder.fmul(left, right)
        elif node.operator == "/":
            return self.builder.fdiv(left, right)
        elif node.operator == "%":
            return self.builder.frem(left, right)
        elif node.operator == ">":
            return self.builder.fcmp_ordered(">", left, right)
        elif node.operator == "<":
            return self.builder.fcmp_ordered("<", left, right)
        elif node.operator == "=":
            return self.builder.fcmp_ordered("==", left, right)
        elif node.operator == "!=":
            return self.builder.fcmp_ordered("!=", left, right)
        elif node.operator == ">=":
            return self.builder.fcmp_ordered(">=", left, right)
        elif node.operator == "<=":
            return self.builder.fcmp_ordered("<=", left, right)
        else:
            raise CompilerError(
                f"Unsupported binary operator '{node.operator}'",
                hint="Supported operators: +, -, *, /, <, >, <=, >=, =, !=",
                node=node,
            )

    def _generate_unary_op(self, node: UnaryOp) -> ir.Value:
        """Generate code for unary operations."""
        # Check if operand is a predicate (converged, diverging, etc.)
        if isinstance(node.operand, Identifier):
            predicate_name = node.operand.name

            # Special handling for predicates - they implicitly refer to a variable
            # For now, we'll check all variables for the predicate
            # In a full implementation, predicates would be bound to specific variables

            if predicate_name in [
                "converged",
                "diverging",
                "oscillating",
                "stable",
                "improving",
            ]:
                # Get the last assigned variable (simplified - should be explicit in real code)
                if self.local_vars:
                    # Get the most recently created variable
                    last_var_name = list(self.local_vars.keys())[-1]
                    var_ptr = self.local_vars[last_var_name]
                    eigen_ptr = self.builder.load(var_ptr)

                    # Call the appropriate predicate function
                    if predicate_name == "converged":
                        result = self.builder.call(
                            self.eigen_check_converged, [eigen_ptr]
                        )
                    elif predicate_name == "diverging":
                        result = self.builder.call(
                            self.eigen_check_diverging, [eigen_ptr]
                        )
                    elif predicate_name == "oscillating":
                        result = self.builder.call(
                            self.eigen_check_oscillating, [eigen_ptr]
                        )
                    elif predicate_name == "stable":
                        result = self.builder.call(self.eigen_check_stable, [eigen_ptr])
                    elif predicate_name == "improving":
                        result = self.builder.call(
                            self.eigen_check_improving, [eigen_ptr]
                        )
                    else:
                        raise NotImplementedError(
                            f"Predicate {predicate_name} not implemented"
                        )

                    # Apply NOT operator if present
                    if node.operator == "not":
                        result = self.builder.not_(result)

                    return result

        # General unary operation
        operand = self._generate(node.operand)

        if node.operator == "not":
            # Logical NOT
            return self.builder.not_(operand)
        elif node.operator == "-":
            # Numeric negation
            return self.builder.fneg(operand)
        else:
            raise NotImplementedError(f"Unary operator {node.operator} not implemented")

    def _generate_assignment(self, node: Assignment) -> None:
        """Generate code for variable assignment.

        Handles both scalar updates and pointer aliasing (Option 2).
        If RHS is an EigenValue* (from interrogative), creates an alias.
        If RHS is a scalar, updates or creates a new EigenValue.
        """
        gen_value = self._generate(node.expression)

        # Handle backward compatibility: convert raw ir.Value to GeneratedValue
        if isinstance(gen_value, ir.Value):
            # Detect if it's a list or string (both are 3-element structs with pointer first)
            is_list = False
            is_string = False
            if isinstance(gen_value.type, ir.PointerType):
                pointed_type = gen_value.type.pointee
                if (
                    isinstance(pointed_type, ir.LiteralStructType)
                    and len(pointed_type.elements) == 3
                    and isinstance(pointed_type.elements[0], ir.PointerType)
                ):
                    # Check first element type to distinguish string vs list
                    first_elem = pointed_type.elements[0]
                    if (
                        isinstance(first_elem.pointee, ir.IntType)
                        and first_elem.pointee.width == 8
                    ):
                        # It's a string (char* = i8*)
                        is_string = True
                    else:
                        # It's a list (double*)
                        is_list = True

            if is_string:
                gen_value = GeneratedValue(value=gen_value, kind=ValueKind.STRING_PTR)
            elif is_list:
                gen_value = GeneratedValue(value=gen_value, kind=ValueKind.LIST_PTR)
            else:
                # Assume it's a scalar
                gen_value = GeneratedValue(value=gen_value, kind=ValueKind.SCALAR)

        # Determine which symbol table to use based on scope
        # In entry function (main or {module}_init), variables are global
        in_func = (
            self.current_function
            and self.current_function.name != self.entry_function_name
        )
        var_table = self.local_vars if in_func else self.global_vars

        # Check if variable already exists (check BOTH scopes)
        existing_var_ptr = None
        if node.identifier in self.local_vars:
            existing_var_ptr = self.local_vars[node.identifier]
        elif node.identifier in self.global_vars:
            existing_var_ptr = self.global_vars[node.identifier]

        # Handle list assignment
        if gen_value.kind == ValueKind.LIST_PTR:
            if existing_var_ptr is not None:
                # Update existing list variable
                self.builder.store(gen_value.value, existing_var_ptr)
            else:
                # Create new list variable
                if in_func:
                    var_ptr = self._alloca_at_entry(
                        self.eigen_list_ptr, name=node.identifier
                    )
                else:
                    var_ptr = self._create_global_variable(
                        self.eigen_list_ptr, node.identifier
                    )
                self.builder.store(gen_value.value, var_ptr)
                var_table[node.identifier] = var_ptr
            return

        # Handle string assignment (for self-hosting)
        if gen_value.kind == ValueKind.STRING_PTR:
            if existing_var_ptr is not None:
                # Update existing string variable
                self.builder.store(gen_value.value, existing_var_ptr)
            else:
                # Create new string variable
                if in_func:
                    var_ptr = self._alloca_at_entry(
                        self.eigen_string_ptr, name=node.identifier
                    )
                else:
                    var_ptr = self._create_global_variable(
                        self.eigen_string_ptr, node.identifier
                    )
                self.builder.store(gen_value.value, var_ptr)
                var_table[node.identifier] = var_ptr
            return

        # Handle struct assignment (for self-hosting)
        if gen_value.kind == ValueKind.STRUCT_PTR:
            struct_type, _ = self.struct_types.get(gen_value.struct_name, (None, None))
            if struct_type:
                if existing_var_ptr is not None:
                    # Update existing struct variable
                    self.builder.store(gen_value.value, existing_var_ptr)
                else:
                    # Create new struct variable
                    if in_func:
                        var_ptr = self._alloca_at_entry(
                            struct_type.as_pointer(), name=node.identifier
                        )
                    else:
                        var_ptr = self._create_global_variable(
                            struct_type.as_pointer(), node.identifier
                        )
                    self.builder.store(gen_value.value, var_ptr)
                    var_table[node.identifier] = var_ptr
                    # Store struct metadata for later field access
                    if not hasattr(self, "struct_var_types"):
                        self.struct_var_types = {}
                    self.struct_var_types[node.identifier] = gen_value.struct_name
            return

        # Handle EigenValue assignment (scalar or pointer)
        # Use the existing variable pointer we already looked up
        var_ptr = existing_var_ptr
        is_global_var = node.identifier in self.global_vars

        if var_ptr is not None:
            # Variable exists - update or rebind

            if gen_value.kind == ValueKind.EIGEN_PTR:
                # Aliasing: rebind to point to the same EigenValue*
                # This is the key to Option 2: "value is what is x" makes value an alias
                self.builder.store(gen_value.value, var_ptr)
            elif gen_value.kind == ValueKind.STRING_PTR:
                # String update: check if existing var is a string pointer
                if var_ptr.type.pointee == self.eigen_string_ptr:
                    # It's a string variable - just store the new string pointer
                    self.builder.store(gen_value.value, var_ptr)
                else:
                    raise TypeError(
                        f"Cannot assign string to non-string variable '{node.identifier}'"
                    )
            else:
                # Scalar update: check if it's a raw double* or EigenValue*
                scalar_val = self.ensure_scalar(gen_value)

                # Check the type of the variable pointer
                if var_ptr.type.pointee == self.double_type:
                    # Fast path: raw double*, just store the new value
                    self.builder.store(scalar_val, var_ptr)
                elif var_ptr.type.pointee == self.eigen_string_ptr:
                    # The value might be an i64-packed string pointer from a function parameter
                    # Convert it back to string pointer
                    if isinstance(gen_value, GeneratedValue):
                        if gen_value.kind == ValueKind.STRING_PTR:
                            self.builder.store(gen_value.value, var_ptr)
                        else:
                            # Try to convert from i64/double to string pointer
                            val = gen_value.value
                            if val.type == self.double_type:
                                i64_val = self.builder.bitcast(val, self.int64_type)
                                str_ptr = self.builder.inttoptr(
                                    i64_val, self.eigen_string_ptr
                                )
                                self.builder.store(str_ptr, var_ptr)
                            elif val.type == self.int64_type:
                                str_ptr = self.builder.inttoptr(
                                    val, self.eigen_string_ptr
                                )
                                self.builder.store(str_ptr, var_ptr)
                            else:
                                raise TypeError(
                                    f"Cannot assign {gen_value.kind} to string variable '{node.identifier}'"
                                )
                    elif isinstance(gen_value, ir.Value):
                        if gen_value.type == self.double_type:
                            i64_val = self.builder.bitcast(gen_value, self.int64_type)
                            str_ptr = self.builder.inttoptr(
                                i64_val, self.eigen_string_ptr
                            )
                            self.builder.store(str_ptr, var_ptr)
                        elif gen_value.type == self.int64_type:
                            str_ptr = self.builder.inttoptr(
                                gen_value, self.eigen_string_ptr
                            )
                            self.builder.store(str_ptr, var_ptr)
                        else:
                            raise TypeError(
                                f"Cannot assign to string variable '{node.identifier}'"
                            )
                    else:
                        raise TypeError(
                            f"Cannot assign scalar to string variable '{node.identifier}'"
                        )
                else:
                    # Geometric tracked: EigenValue*, call eigen_update
                    eigen_ptr = self.builder.load(var_ptr)
                    self.builder.call(self.eigen_update, [eigen_ptr, scalar_val])
        else:
            # Create new variable
            # OBSERVER EFFECT: Check if variable needs geometric tracking
            is_observed = node.identifier in self.observed_variables

            if not is_observed and gen_value.kind == ValueKind.SCALAR:
                # FAST PATH: Unobserved scalar → raw double (C-level performance!)
                scalar_val = self.ensure_scalar(gen_value)
                if in_func:
                    # In function: use stack alloca (can be promoted to register)
                    var_ptr = self._alloca_at_entry(
                        self.double_type, name=node.identifier
                    )
                    self.builder.store(scalar_val, var_ptr)
                else:
                    # In main scope: use global variable for cross-function access
                    var_ptr = self._create_global_variable(
                        self.double_type, node.identifier
                    )
                    self.builder.store(scalar_val, var_ptr)
                var_table[node.identifier] = var_ptr
                # NOTE: This is just a double*, not EigenValue*!

            elif in_func and gen_value.kind == ValueKind.SCALAR:
                # Observed variable in function: Stack-allocated EigenValue
                # IMPORTANT: Stack variables are NOT added to allocated_eigenvalues
                # They don't need cleanup - automatically freed when function returns
                scalar_val = self.ensure_scalar(gen_value)
                eigen_ptr = self._create_eigen_on_stack(scalar_val)
                var_ptr = self._alloca_at_entry(
                    self.eigen_value_ptr, name=node.identifier
                )
                self.builder.store(eigen_ptr, var_ptr)
                var_table[node.identifier] = var_ptr
                # NOTE: Stack variables are NOT tracked in allocated_eigenvalues!
            else:
                # Observed variable in main scope: Heap allocation
                # These DO need cleanup via eigen_destroy
                eigen_ptr = self.ensure_eigen_ptr(gen_value)
                if in_func:
                    var_ptr = self._alloca_at_entry(
                        self.eigen_value_ptr, name=node.identifier
                    )
                else:
                    # Main scope: use global for cross-function access
                    var_ptr = self._create_global_variable(
                        self.eigen_value_ptr, node.identifier
                    )
                self.builder.store(eigen_ptr, var_ptr)
                var_table[node.identifier] = var_ptr

    def _generate_indexed_assignment(self, node: IndexedAssignment) -> None:
        """Generate code for indexed assignment (list[index] is value).

        Uses eigen_list_set to set the value at the specified index.
        """
        # Handle external list specially
        if isinstance(node.list_expr, Identifier):
            list_name = node.list_expr.name
            # Check if it's a known local/global or needs external declaration
            if list_name not in self.local_vars and list_name not in self.global_vars:
                # Declare as external list
                list_global = self._declare_external_list(list_name)
                list_ptr = self.builder.load(list_global)
            else:
                list_gen = self._generate(node.list_expr)
                list_ptr = self._ensure_list_ptr(list_gen)
        else:
            list_gen = self._generate(node.list_expr)
            list_ptr = self._ensure_list_ptr(list_gen)

        # Generate the index expression
        index_gen = self._generate(node.index_expr)
        index_val = self._ensure_int64(index_gen)

        # Generate the value expression
        value_gen = self._generate(node.value)
        value = self.ensure_scalar(value_gen)

        # Call eigen_list_set
        self.builder.call(self.eigen_list_set, [list_ptr, index_val, value])

    def _generate_relation(self, node: Relation) -> ir.Value:
        """Generate code for relations (function calls via 'of' operator)."""
        # Check if left side is a function name
        if isinstance(node.left, Identifier):
            func_name = node.left.name

            # Check if this is a struct instantiation: StructName of [values...]
            if func_name in self.struct_types:
                # Parse the values from the right side (must be a list)
                if isinstance(node.right, ListLiteral):
                    struct_literal = StructLiteral(
                        struct_name=func_name, values=node.right.elements
                    )
                    return self._generate_struct_literal(struct_literal)
                else:
                    raise CompilerError(
                        f"Struct instantiation requires a list of values",
                        hint=f"Use: {func_name} of [value1, value2, ...]",
                        node=node,
                    )

            # Handle built-in functions
            if func_name == "print":
                arg_gen_val = self._generate(node.right)

                # Check if it's a string - print as string
                if (
                    isinstance(arg_gen_val, GeneratedValue)
                    and arg_gen_val.kind == ValueKind.STRING_PTR
                ):
                    # Get C string from EigenString and print it
                    c_str = self.builder.call(
                        self.eigen_string_cstr, [arg_gen_val.value]
                    )
                    fmt_str = "%s\n\0"
                    fmt_const = ir.Constant(
                        ir.ArrayType(self.int8_type, len(fmt_str)),
                        bytearray(fmt_str.encode("utf-8")),
                    )
                    global_fmt = ir.GlobalVariable(
                        self.module, fmt_const.type, name=f"fmt_str_{id(node)}"
                    )
                    global_fmt.global_constant = True
                    global_fmt.initializer = fmt_const
                    fmt_ptr = self.builder.bitcast(global_fmt, self.string_type)
                    return self.builder.call(self.printf, [fmt_ptr, c_str])

                # Check if it's a PACKED_I64 (function parameter) - try as string
                if (
                    isinstance(arg_gen_val, GeneratedValue)
                    and arg_gen_val.kind == ValueKind.PACKED_I64
                ):
                    # Interpret i64 as a potential string pointer
                    str_ptr = self.builder.inttoptr(
                        arg_gen_val.value, self.eigen_string_ptr
                    )
                    c_str = self.builder.call(self.eigen_string_cstr, [str_ptr])
                    fmt_str = "%s\n\0"
                    fmt_const = ir.Constant(
                        ir.ArrayType(self.int8_type, len(fmt_str)),
                        bytearray(fmt_str.encode("utf-8")),
                    )
                    global_fmt = ir.GlobalVariable(
                        self.module, fmt_const.type, name=f"fmt_str_i64_{id(node)}"
                    )
                    global_fmt.global_constant = True
                    global_fmt.initializer = fmt_const
                    fmt_ptr = self.builder.bitcast(global_fmt, self.string_type)
                    return self.builder.call(self.printf, [fmt_ptr, c_str])

                # Convert to scalar for printing (handles both raw values and aliases)
                arg_val = self.ensure_scalar(arg_gen_val)

                # Use eigen_print_f64 for WASM (avoids variadic calling convention issues)
                # For native targets, use printf with format string
                if self.target_triple and "wasm" in self.target_triple.lower():
                    return self.builder.call(self.eigen_print_f64, [arg_val])
                else:
                    # Print format string for native
                    fmt_str = "%f\n\0"
                    fmt_const = ir.Constant(
                        ir.ArrayType(self.int8_type, len(fmt_str)),
                        bytearray(fmt_str.encode("utf-8")),
                    )
                    global_fmt = ir.GlobalVariable(
                        self.module, fmt_const.type, name=f"fmt_{id(node)}"
                    )
                    global_fmt.global_constant = True
                    global_fmt.initializer = fmt_const
                    fmt_ptr = self.builder.bitcast(global_fmt, self.string_type)
                    return self.builder.call(self.printf, [fmt_ptr, arg_val])

            # ============================================================
            # String Builtin Functions (for self-hosting)
            # ============================================================

            # string_length of str -> i64 (as double for EigenScript)
            if func_name == "string_length":
                arg_gen = self._generate(node.right)
                str_ptr = self._ensure_string_ptr(arg_gen)
                length = self.builder.call(self.eigen_string_length, [str_ptr])
                # Convert i64 to double for EigenScript consistency
                return self.builder.sitofp(length, self.double_type)

            # char_at of [str, index] -> i64 (as double)
            if func_name == "char_at":
                args = self._extract_list_args(node.right, 2)
                str_ptr = self._ensure_string_ptr(args[0])
                index = self._ensure_int64(args[1])
                char_code = self.builder.call(self.eigen_char_at, [str_ptr, index])
                return self.builder.sitofp(char_code, self.double_type)

            # substring of [str, start, length] -> EigenString*
            if func_name == "substring":
                args = self._extract_list_args(node.right, 3)
                str_ptr = self._ensure_string_ptr(args[0])
                start = self._ensure_int64(args[1])
                length = self._ensure_int64(args[2])
                result = self.builder.call(
                    self.eigen_substring, [str_ptr, start, length]
                )
                if self.current_function and self.current_function.name == "main":
                    self.allocated_strings.append(result)
                return GeneratedValue(value=result, kind=ValueKind.STRING_PTR)

            # string_concat of [str1, str2] -> EigenString*
            if func_name == "string_concat":
                args = self._extract_list_args(node.right, 2)
                str1 = self._ensure_string_ptr(args[0])
                str2 = self._ensure_string_ptr(args[1])
                result = self.builder.call(self.eigen_string_concat, [str1, str2])
                if self.current_function and self.current_function.name == "main":
                    self.allocated_strings.append(result)
                return GeneratedValue(value=result, kind=ValueKind.STRING_PTR)

            # string_equals of [str1, str2] -> bool (as double: 0.0 or 1.0)
            if func_name == "string_equals":
                args = self._extract_list_args(node.right, 2)
                str1 = self._ensure_string_ptr(args[0])
                str2 = self._ensure_string_ptr(args[1])
                result = self.builder.call(self.eigen_string_equals, [str1, str2])
                return self.builder.sitofp(result, self.double_type)

            # string_compare of [str1, str2] -> i64 (as double)
            if func_name == "string_compare":
                args = self._extract_list_args(node.right, 2)
                str1 = self._ensure_string_ptr(args[0])
                str2 = self._ensure_string_ptr(args[1])
                result = self.builder.call(self.eigen_string_compare, [str1, str2])
                return self.builder.sitofp(result, self.double_type)

            # char_is_digit of char_code -> bool (as double)
            if func_name == "char_is_digit":
                arg_gen = self._generate(node.right)
                char_code = self._ensure_int64(arg_gen)
                result = self.builder.call(self.eigen_char_is_digit, [char_code])
                return self.builder.sitofp(result, self.double_type)

            # char_is_alpha of char_code -> bool (as double)
            if func_name == "char_is_alpha":
                arg_gen = self._generate(node.right)
                char_code = self._ensure_int64(arg_gen)
                result = self.builder.call(self.eigen_char_is_alpha, [char_code])
                return self.builder.sitofp(result, self.double_type)

            # char_is_alnum of char_code -> bool (as double)
            if func_name == "char_is_alnum":
                arg_gen = self._generate(node.right)
                char_code = self._ensure_int64(arg_gen)
                result = self.builder.call(self.eigen_char_is_alnum, [char_code])
                return self.builder.sitofp(result, self.double_type)

            # char_is_whitespace of char_code -> bool (as double)
            if func_name == "char_is_whitespace":
                arg_gen = self._generate(node.right)
                char_code = self._ensure_int64(arg_gen)
                result = self.builder.call(self.eigen_char_is_whitespace, [char_code])
                return self.builder.sitofp(result, self.double_type)

            # char_is_newline of char_code -> bool (as double)
            if func_name == "char_is_newline":
                arg_gen = self._generate(node.right)
                char_code = self._ensure_int64(arg_gen)
                result = self.builder.call(self.eigen_char_is_newline, [char_code])
                return self.builder.sitofp(result, self.double_type)

            # char_to_string of char_code -> EigenString*
            if func_name == "char_to_string":
                arg_gen = self._generate(node.right)
                char_code = self._ensure_int64(arg_gen)
                result = self.builder.call(self.eigen_char_to_string, [char_code])
                if self.current_function and self.current_function.name == "main":
                    self.allocated_strings.append(result)
                return GeneratedValue(value=result, kind=ValueKind.STRING_PTR)

            # number_to_string of number -> EigenString*
            if func_name == "number_to_string":
                arg_gen = self._generate(node.right)
                num_val = self.ensure_scalar(arg_gen)
                result = self.builder.call(self.eigen_number_to_string, [num_val])
                if self.current_function and self.current_function.name == "main":
                    self.allocated_strings.append(result)
                return GeneratedValue(value=result, kind=ValueKind.STRING_PTR)

            # string_to_number of str -> double
            if func_name == "string_to_number":
                arg_gen = self._generate(node.right)
                str_ptr = self._ensure_string_ptr(arg_gen)
                return self.builder.call(self.eigen_string_to_number, [str_ptr])

            # string_find of [haystack, needle, start] -> i64 (as double, -1 if not found)
            if func_name == "string_find":
                args = self._extract_list_args(node.right, 3)
                haystack = self._ensure_string_ptr(args[0])
                needle = self._ensure_string_ptr(args[1])
                start = self._ensure_int64(args[2])
                result = self.builder.call(
                    self.eigen_string_find, [haystack, needle, start]
                )
                return self.builder.sitofp(result, self.double_type)

            # string_append_char of [str, char_code] -> void (modifies in place)
            if func_name == "string_append_char":
                args = self._extract_list_args(node.right, 2)
                str_ptr = self._ensure_string_ptr(args[0])
                char_code = self._ensure_int64(args[1])
                self.builder.call(self.eigen_string_append_char, [str_ptr, char_code])
                return ir.Constant(self.double_type, 0.0)  # Void return

            # string_new of capacity -> EigenString* (create empty string)
            if func_name == "string_new":
                arg_gen = self._generate(node.right)
                capacity = self._ensure_int64(arg_gen)
                result = self.builder.call(self.eigen_string_create_empty, [capacity])
                if self.current_function and self.current_function.name == "main":
                    self.allocated_strings.append(result)
                return GeneratedValue(value=result, kind=ValueKind.STRING_PTR)

            # ============================================================
            # File I/O Builtin Functions (for self-hosting)
            # ============================================================

            # file_read of filename -> EigenString* (read entire file)
            if func_name == "file_read":
                arg_gen = self._generate(node.right)
                filename_ptr = self._ensure_string_ptr(arg_gen)
                result = self.builder.call(self.eigen_file_read, [filename_ptr])
                return GeneratedValue(value=result, kind=ValueKind.STRING_PTR)

            # file_write of [filename, contents] -> i64 (1=success, 0=failure)
            if func_name == "file_write":
                args = self._extract_list_args(node.right, 2)
                filename_ptr = self._ensure_string_ptr(args[0])
                contents_ptr = self._ensure_string_ptr(args[1])
                result = self.builder.call(
                    self.eigen_file_write, [filename_ptr, contents_ptr]
                )
                return self.builder.sitofp(result, self.double_type)

            # file_append of [filename, contents] -> i64 (1=success, 0=failure)
            if func_name == "file_append":
                args = self._extract_list_args(node.right, 2)
                filename_ptr = self._ensure_string_ptr(args[0])
                contents_ptr = self._ensure_string_ptr(args[1])
                result = self.builder.call(
                    self.eigen_file_append, [filename_ptr, contents_ptr]
                )
                return self.builder.sitofp(result, self.double_type)

            # ============================================================
            # CLI Argument Builtin Functions (for self-hosting)
            # ============================================================

            # get_argc of 0 -> number of command line arguments
            if func_name == "get_argc":
                # Declare external argc global if not in main module
                if not hasattr(self, "argc_global"):
                    char_ptr_ptr = self.string_type.as_pointer()
                    self.argc_global = ir.GlobalVariable(
                        self.module, self.int32_type, name="__eigs_argc"
                    )
                    self.argc_global.linkage = "external"
                argc_val = self.builder.load(self.argc_global)
                return self.builder.sitofp(argc_val, self.double_type)

            # get_arg of index -> EigenString* (get argument at index)
            if func_name == "get_arg":
                # Declare external argv global if not in main module
                if not hasattr(self, "argv_global"):
                    char_ptr_ptr = self.string_type.as_pointer()
                    self.argv_global = ir.GlobalVariable(
                        self.module, char_ptr_ptr, name="__eigs_argv"
                    )
                    self.argv_global.linkage = "external"

                arg_gen = self._generate(node.right)
                index = self._ensure_int64(arg_gen)
                # Truncate to i32 for array indexing
                index_i32 = self.builder.trunc(index, self.int32_type)

                # Load argv pointer
                argv_ptr = self.builder.load(self.argv_global)
                # Get pointer to argv[index]
                arg_ptr = self.builder.gep(argv_ptr, [index_i32])
                # Load the char* at that position
                c_str = self.builder.load(arg_ptr)
                # Convert to EigenString*
                result = self.builder.call(self.eigen_string_create, [c_str])
                return GeneratedValue(value=result, kind=ValueKind.STRING_PTR)

            # ============================================================
            # List Builtin Functions
            # ============================================================

            # append list of value -> void (modifies in place)
            # Usage: append array of value (appends value to array)
            if func_name == "append":
                if isinstance(node.right, Relation):
                    # node.right is Relation(list, value)
                    # Handle external list specially
                    list_expr = node.right.left
                    if isinstance(list_expr, Identifier):
                        list_name = list_expr.name
                        # Check if it's a known local/global or needs external declaration
                        if (
                            list_name not in self.local_vars
                            and list_name not in self.global_vars
                        ):
                            # Declare as external list
                            list_ptr = self._declare_external_list(list_name)
                            list_gen = self.builder.load(list_ptr)
                        else:
                            list_gen = self._generate(list_expr)
                    else:
                        list_gen = self._generate(list_expr)

                    value_gen = self._generate(node.right.right)

                    # Ensure we have a list pointer
                    list_ptr = self._ensure_list_ptr(list_gen)
                    # Ensure we have a scalar value
                    value = self.ensure_scalar(value_gen)

                    self.builder.call(self.eigen_list_append, [list_ptr, value])
                    return ir.Constant(self.double_type, 0.0)  # Void return
                else:
                    raise CompilerError(
                        "append requires 'append list of value' syntax",
                        hint="Usage: append mylist of 42",
                    )

            # length of list -> i64 (as double)
            # Usage: length of mylist
            if func_name == "length":
                arg_gen = self._generate(node.right)
                list_ptr = self._ensure_list_ptr(arg_gen)
                length_val = self.builder.call(self.eigen_list_length, [list_ptr])
                # Convert i64 to double for EigenScript consistency
                return self.builder.sitofp(length_val, self.double_type)

            # Handle user-defined functions (local or external)
            func = None
            if func_name in self.functions:
                func = self.functions[func_name]
            elif func_name in self.external_functions:
                func = self.external_functions[func_name]
            else:
                # Auto-declare as external function for cross-module calls
                # Count arguments to determine parameter count
                if isinstance(node.right, ListLiteral):
                    num_params = len(node.right.elements)
                else:
                    num_params = 1
                func = self._declare_external_function(func_name, num_params)

            # Get the argument expression and collect arguments
            call_args = []

            # Check if the argument is a list literal (for multi-param functions)
            if isinstance(node.right, ListLiteral):
                # Multiple arguments passed as list: func of [a, b, c]
                for elem in node.right.elements:
                    gen_arg = self._generate(elem)
                    call_args.append(self._pack_to_i64(gen_arg))
            else:
                # Single argument: func of x
                gen_arg = self._generate(node.right)
                call_args.append(self._pack_to_i64(gen_arg))

            # Ensure we have the right number of arguments
            expected_args = len(func.args)
            if len(call_args) != expected_args:
                # Pad with zeros if not enough args
                while len(call_args) < expected_args:
                    call_args.append(ir.Constant(self.int64_type, 0))
                # Truncate if too many args
                call_args = call_args[:expected_args]

            # Call the function (returns i64)
            result_i64 = self.builder.call(func, call_args)
            # Unpack result back to double (default interpretation)
            return self.builder.bitcast(result_i64, self.double_type)

        elif isinstance(node.left, MemberAccess):
            # Handle module.function calls (cross-module function calls)
            # Extract module and member names
            module_name = node.left.object.name
            member_name = node.left.member
            mangled_name = f"{module_name}_{member_name}"

            if mangled_name not in self.functions:
                raise CompilerError(
                    f"Function '{mangled_name}' not found",
                    hint=f"Make sure module '{module_name}' is imported and compiled first",
                    node=node,
                )

            func = self.functions[mangled_name]

            # Get the argument expression and collect arguments
            call_args = []

            # Check if the argument is a list literal (for multi-param functions)
            if isinstance(node.right, ListLiteral):
                # Multiple arguments passed as list: func of [a, b, c]
                for elem in node.right.elements:
                    gen_arg = self._generate(elem)
                    call_args.append(self.ensure_scalar(gen_arg))
            else:
                # Single argument: func of x
                gen_arg = self._generate(node.right)
                call_args.append(self.ensure_scalar(gen_arg))

            # Ensure we have the right number of arguments
            expected_args = len(func.args)
            if len(call_args) != expected_args:
                while len(call_args) < expected_args:
                    call_args.append(ir.Constant(self.double_type, 0.0))
                call_args = call_args[:expected_args]

            # Call the function
            result = self.builder.call(func, call_args)
            return result

        raise NotImplementedError(
            f"Relation {node.left} of {node.right} not implemented"
        )

    def _generate_conditional(self, node: Conditional) -> None:
        """Generate code for if-else statements."""
        raw_cond = self._generate(node.condition)

        # FIX: Ensure we have a boolean for the branch
        cond = self.ensure_bool(raw_cond)

        # Create basic blocks
        then_block = self.current_function.append_basic_block(name="if.then")
        else_block = (
            self.current_function.append_basic_block(name="if.else")
            if node.else_block
            else None
        )
        merge_block = self.current_function.append_basic_block(name="if.end")

        # Branch based on condition
        if else_block:
            self.builder.cbranch(cond, then_block, else_block)
        else:
            self.builder.cbranch(cond, then_block, merge_block)

        # Generate then block
        self.builder.position_at_end(then_block)
        then_terminated = False
        for stmt in node.if_block:
            self._generate(stmt)
            if isinstance(stmt, (Return, Break)):
                then_terminated = True
                break
        if not then_terminated:
            self.builder.branch(merge_block)

        # Generate else block if present
        else_terminated = False
        if else_block:
            self.builder.position_at_end(else_block)
            for stmt in node.else_block:
                self._generate(stmt)
                if isinstance(stmt, (Return, Break)):
                    else_terminated = True
                    break
            if not else_terminated:
                self.builder.branch(merge_block)

        # Continue at merge block
        self.builder.position_at_end(merge_block)

    def _generate_loop(self, node: Loop) -> None:
        """Generate code for loops with break support."""
        # Create basic blocks
        loop_cond = self.current_function.append_basic_block(name="loop.cond")
        loop_body = self.current_function.append_basic_block(name="loop.body")
        loop_end = self.current_function.append_basic_block(name="loop.end")

        # Push loop_end onto stack for break statements
        self.loop_end_stack.append(loop_end)

        # Jump to condition check
        self.builder.branch(loop_cond)

        # Generate condition check
        self.builder.position_at_end(loop_cond)
        raw_cond = self._generate(node.condition)

        # FIX: Ensure we have a boolean for the branch
        cond = self.ensure_bool(raw_cond)

        self.builder.cbranch(cond, loop_body, loop_end)

        # Generate loop body
        self.builder.position_at_end(loop_body)
        body_terminated = False
        for stmt in node.body:
            self._generate(stmt)
            # Check if body is already terminated (return or break)
            if isinstance(stmt, (Return, Break)):
                body_terminated = True
                break
        if not body_terminated:
            self.builder.branch(loop_cond)

        # Pop loop context
        self.loop_end_stack.pop()

        # Continue after loop
        self.builder.position_at_end(loop_end)

    def _generate_interrogative(self, node: Interrogative) -> GeneratedValue:
        """Generate code for interrogatives (what, who, why, how, when, where).

        Only 'what is' returns EIGEN_PTR for aliasing (Option 2).
        Other interrogatives extract specific fields and return scalars.
        This preserves the is/of duality while maintaining correct semantics.
        """
        # Interrogative has 'interrogative' field and 'expression' field
        target_expr = node.expression

        if not isinstance(target_expr, Identifier):
            raise NotImplementedError(
                "Interrogatives only support simple identifiers for now"
            )

        target_name = target_expr.name
        if target_name not in self.local_vars and target_name not in self.global_vars:
            raise NameError(f"Undefined variable: {target_name}")

        var_ptr = self.local_vars.get(target_name) or self.global_vars.get(target_name)

        # Check if this is a fast-path variable (raw double*) or EigenValue*
        is_fast_path = var_ptr.type.pointee == self.double_type

        if is_fast_path:
            # Fast-path variable: just a raw double, not an EigenValue*
            # Interrogatives don't make sense for untracked variables
            # For "what is", just return the scalar value
            if node.interrogative == "what":
                scalar_val = self.builder.load(var_ptr)
                return GeneratedValue(value=scalar_val, kind=ValueKind.SCALAR)
            else:
                # Other interrogatives (why/how/when) don't make sense for scalars
                # Return default values
                if node.interrogative == "why":
                    # No gradient tracking, return 0.0
                    return GeneratedValue(
                        value=ir.Constant(self.double_type, 0.0), kind=ValueKind.SCALAR
                    )
                elif node.interrogative == "how":
                    # No stability tracking, return 1.0 (perfectly stable)
                    return GeneratedValue(
                        value=ir.Constant(self.double_type, 1.0), kind=ValueKind.SCALAR
                    )
                elif node.interrogative == "when":
                    # No iteration tracking, return 0.0
                    return GeneratedValue(
                        value=ir.Constant(self.double_type, 0.0), kind=ValueKind.SCALAR
                    )
                else:
                    raise NotImplementedError(
                        f"Interrogative {node.interrogative} not implemented"
                    )

        # EigenValue* variable: full geometric tracking available
        eigen_ptr = self.builder.load(var_ptr)

        # Special case: 'what is' returns the pointer for aliasing
        if node.interrogative == "what":
            # Return EigenValue* pointer - enables aliasing
            # "value is what is x" makes value an alias to x
            return GeneratedValue(value=eigen_ptr, kind=ValueKind.EIGEN_PTR)

        # Other interrogatives extract specific fields and return scalars
        elif node.interrogative == "why":
            scalar_val = self.builder.call(self.eigen_get_gradient, [eigen_ptr])
            return GeneratedValue(value=scalar_val, kind=ValueKind.SCALAR)
        elif node.interrogative == "how":
            scalar_val = self.builder.call(self.eigen_get_stability, [eigen_ptr])
            return GeneratedValue(value=scalar_val, kind=ValueKind.SCALAR)
        elif node.interrogative == "when":
            # Returns i64, convert to double for consistency
            iter_count = self.builder.call(self.eigen_get_iteration, [eigen_ptr])
            scalar_val = self.builder.sitofp(iter_count, self.double_type)
            return GeneratedValue(value=scalar_val, kind=ValueKind.SCALAR)
        else:
            raise NotImplementedError(
                f"Interrogative {node.interrogative} not implemented"
            )

    def _generate_member_access(self, node: MemberAccess) -> GeneratedValue:
        """Generate code for member access (module.function or struct.field).

        Handles:
        1. Module function access: module.function -> module_function
        2. Struct field access: struct_instance.field -> load field value
        """
        # First, try to evaluate the object to see if it's a struct
        if isinstance(node.object, Identifier):
            # Check if it's a variable that might hold a struct
            var_name = node.object.name
            if var_name in self.local_vars or var_name in self.global_vars:
                # Load the variable value
                gen_obj = self._generate_identifier(node.object)

                # Check if it's a struct
                if (
                    isinstance(gen_obj, GeneratedValue)
                    and gen_obj.kind == ValueKind.STRUCT_PTR
                ):
                    struct_name = gen_obj.struct_name
                    if struct_name and struct_name in self.struct_types:
                        struct_type, field_names = self.struct_types[struct_name]

                        # Find field index
                        field_name = node.member
                        if field_name not in field_names:
                            raise CompilerError(
                                f"Struct '{struct_name}' has no field '{field_name}'",
                                hint=f"Available fields: {', '.join(field_names)}",
                                node=node,
                            )

                        field_idx = field_names.index(field_name)

                        # Get pointer to field
                        struct_ptr = gen_obj.value
                        field_ptr = self.builder.gep(
                            struct_ptr,
                            [
                                ir.Constant(self.int32_type, 0),
                                ir.Constant(self.int32_type, field_idx),
                            ],
                            inbounds=True,
                        )

                        # Load the field value (stored as i8*)
                        ptr_val = self.builder.load(field_ptr)

                        # Convert the pointer back to double
                        # (We stored double bits as pointer, now reverse it)
                        int_val = self.builder.ptrtoint(ptr_val, self.int64_type)
                        double_val = self.builder.bitcast(int_val, self.double_type)

                        return double_val

        # Fall back to module.function pattern
        if not isinstance(node.object, Identifier):
            raise CompilerError(
                "Member access only supported for module.function or struct.field pattern",
                hint="Example: control.apply_damping or token.type",
                node=node,
            )

        module_name = node.object.name
        member_name = node.member

        # Create mangled name: module_function
        mangled_name = f"{module_name}_{member_name}"

        # Return as an identifier that can be used in function calls
        # Create a synthetic Identifier node
        synthetic_id = Identifier(name=mangled_name)
        return self._generate_identifier(synthetic_id)

    def _generate_struct_def(self, node: StructDef) -> None:
        """Generate code for struct type definition.

        Creates an LLVM struct type and registers it for later use.
        Structs are essential for self-hosting (tokens, AST nodes, etc.)

        Example:
            struct Token:
                type      # field 0: double
                value     # field 1: EigenString*
                line      # field 2: double
        """
        # For simplicity, struct fields are generic pointers (i8*)
        # This allows storing any type (double, string, nested struct)
        # The actual type is determined at access time
        field_types = []
        for field_name in node.fields:
            # Use i8* (generic pointer) for all fields for flexibility
            # This is similar to how dynamic languages handle struct fields
            field_types.append(self.string_type)  # i8* for generic storage

        # Create named struct type
        struct_type = ir.LiteralStructType(field_types)

        # Register the struct type
        self.struct_types[node.name] = (struct_type, node.fields)

        # No runtime code generation needed - struct definition is compile-time only
        return None

    def _generate_struct_literal(self, node: StructLiteral) -> GeneratedValue:
        """Generate code for struct instantiation.

        Creates a struct instance with provided field values.

        Example:
            Token of [1, "hello", 10]
        """
        if node.struct_name not in self.struct_types:
            raise CompilerError(
                f"Unknown struct type '{node.struct_name}'",
                hint=f"Define the struct first with 'struct {node.struct_name}:'",
                node=node,
            )

        struct_type, field_names = self.struct_types[node.struct_name]

        if len(node.values) != len(field_names):
            raise CompilerError(
                f"Struct '{node.struct_name}' has {len(field_names)} fields, "
                f"but {len(node.values)} values provided",
                hint=f"Expected fields: {', '.join(field_names)}",
                node=node,
            )

        # Allocate struct on heap
        struct_size = ir.Constant(
            self.int64_type, len(field_names) * 8
        )  # 8 bytes per pointer
        struct_ptr = self.builder.call(self.malloc, [struct_size])
        struct_ptr = self.builder.bitcast(struct_ptr, struct_type.as_pointer())

        # Initialize each field
        for i, (value_node, field_name) in enumerate(zip(node.values, field_names)):
            # Generate the value
            gen_value = self._generate(value_node)

            # Get pointer to field
            field_ptr = self.builder.gep(
                struct_ptr,
                [ir.Constant(self.int32_type, 0), ir.Constant(self.int32_type, i)],
                inbounds=True,
            )

            # Store value (convert to pointer if needed)
            if isinstance(gen_value, GeneratedValue):
                if gen_value.kind == ValueKind.STRING_PTR:
                    # Store string pointer directly
                    ptr_val = self.builder.bitcast(gen_value.value, self.string_type)
                    self.builder.store(ptr_val, field_ptr)
                elif gen_value.kind == ValueKind.STRUCT_PTR:
                    # Store nested struct pointer
                    ptr_val = self.builder.bitcast(gen_value.value, self.string_type)
                    self.builder.store(ptr_val, field_ptr)
                else:
                    # Scalar value - box it
                    scalar = self.ensure_scalar(gen_value)
                    # Store as pointer (cast double bits to pointer)
                    ptr_val = self.builder.inttoptr(
                        self.builder.bitcast(scalar, self.int64_type), self.string_type
                    )
                    self.builder.store(ptr_val, field_ptr)
            elif isinstance(gen_value, ir.Value):
                if gen_value.type == self.double_type:
                    # Scalar value - box it
                    ptr_val = self.builder.inttoptr(
                        self.builder.bitcast(gen_value, self.int64_type),
                        self.string_type,
                    )
                    self.builder.store(ptr_val, field_ptr)
                elif isinstance(gen_value.type, ir.PointerType):
                    # Pointer value - store directly
                    ptr_val = self.builder.bitcast(gen_value, self.string_type)
                    self.builder.store(ptr_val, field_ptr)
                else:
                    raise CompilerError(
                        f"Cannot store {gen_value.type} in struct field"
                    )

        return GeneratedValue(
            value=struct_ptr, kind=ValueKind.STRUCT_PTR, struct_name=node.struct_name
        )

    def _declare_function(self, node: FunctionDef) -> None:
        """Declare a function without generating its body (for forward references)."""
        # Skip if already declared
        if node.name in self.functions:
            return

        # Apply name mangling for library modules to prevent symbol collisions
        mangled_name = f"{self.module_prefix}{node.name}"

        # Create function signature based on parameter count
        # Use i64 as the universal parameter type - can hold both:
        # - doubles (via bitcast)
        # - pointers (via ptrtoint)
        param_count = len(node.parameters) if node.parameters else 1
        if param_count == 0:
            param_count = 1

        param_types = [self.int64_type] * param_count
        func_type = ir.FunctionType(self.int64_type, param_types)

        func = ir.Function(self.module, func_type, name=mangled_name)
        func.attributes.add("nounwind")
        self.functions[node.name] = func

    def _generate_function_def(self, node: FunctionDef) -> None:
        """Generate code for function definitions."""
        # Get the already-declared function (or declare it if not done in first pass)
        if node.name not in self.functions:
            self._declare_function(node)

        mangled_name = f"{self.module_prefix}{node.name}"
        func = self.functions[node.name]

        # Create entry block
        block = func.append_basic_block(name="entry")

        # Save current context
        prev_function = self.current_function
        prev_builder = self.builder
        prev_local_vars = self.local_vars
        prev_entry_block = self.entry_block

        # Set up new context for function
        self.current_function = func
        self.builder = ir.IRBuilder(block)
        self.entry_block = block  # Store entry block for proper alloca placement
        self.local_vars = {}

        # Register parameters with their actual names
        # Parameters are i64 (universal type that can hold doubles or pointers)
        if node.parameters:
            for i, param_name in enumerate(node.parameters):
                param_ptr = self._alloca_at_entry(self.int64_type, name=param_name)
                self.builder.store(func.args[i], param_ptr)
                self.local_vars[param_name] = param_ptr
        else:
            # Legacy behavior: single parameter named 'n'
            param_ptr = self._alloca_at_entry(self.int64_type, name="n")
            self.builder.store(func.args[0], param_ptr)
            self.local_vars["n"] = param_ptr

        # Generate function body
        function_terminated = False
        for stmt in node.body:
            if isinstance(stmt, Return):
                self._generate(stmt)  # This will emit the ret instruction
                function_terminated = True
                break
            else:
                self._generate(stmt)

        # If no explicit return, return 0 (as i64 for user functions)
        if not function_terminated:
            self.builder.ret(ir.Constant(self.int64_type, 0))

        # Restore previous context
        self.current_function = prev_function
        self.builder = prev_builder
        self.local_vars = prev_local_vars
        self.entry_block = prev_entry_block

    def _generate_return(self, node: Return) -> ir.Value:
        """Generate code for return statements."""
        # Check if we're in a user-defined function (returns i64) or main (returns i32)
        is_user_func = (
            self.current_function
            and self.current_function.name != "main"
            and self.current_function.ftype.return_type == self.int64_type
        )

        if node.expression:
            return_val = self._generate(node.expression)
            if is_user_func:
                # Pack return value as i64 for user-defined functions
                packed = self._pack_to_i64(return_val)
                self.builder.ret(packed)
                return packed
            else:
                self.builder.ret(return_val)
                return return_val
        else:
            if is_user_func:
                zero = ir.Constant(self.int64_type, 0)
            else:
                zero = ir.Constant(self.double_type, 0.0)
            self.builder.ret(zero)
            return zero

    def _generate_break(self, node: Break) -> None:
        """Generate code for break statements.

        Break jumps to the end of the current loop.
        """
        if not self.loop_end_stack:
            raise CompilerError(
                "'break' statement outside loop",
                hint="'break' can only be used inside a 'loop while' body",
                node=node,
            )

        # Jump to the end of the current loop
        loop_end = self.loop_end_stack[-1]
        self.builder.branch(loop_end)

    def _generate_list_literal(self, node: ListLiteral) -> ir.Value:
        """Generate code for list literals."""
        # Create list with length
        length = len(node.elements)
        length_val = ir.Constant(self.int64_type, length)
        list_ptr = self.builder.call(self.eigen_list_create, [length_val])
        # Only track allocations in main scope (not in functions)
        if self.current_function and self.current_function.name == "main":
            self.allocated_lists.append(list_ptr)

        # Set each element
        for i, elem in enumerate(node.elements):
            elem_val = self._generate(elem)
            # Convert to double for list storage
            scalar_val = self.ensure_scalar(elem_val)
            index_val = ir.Constant(self.int64_type, i)
            self.builder.call(self.eigen_list_set, [list_ptr, index_val, scalar_val])

        return GeneratedValue(value=list_ptr, kind=ValueKind.LIST_PTR)

    def _generate_index(self, node: Index) -> ir.Value:
        """Generate code for list indexing."""
        # Handle external list specially
        if isinstance(node.list_expr, Identifier):
            list_name = node.list_expr.name
            # Check if it's a known local/global or needs external declaration
            if list_name not in self.local_vars and list_name not in self.global_vars:
                # Declare as external list
                list_global = self._declare_external_list(list_name)
                list_ptr = self.builder.load(list_global)
            else:
                list_gen = self._generate(node.list_expr)
                list_ptr = self._ensure_list_ptr(list_gen)
        else:
            list_gen = self._generate(node.list_expr)
            list_ptr = self._ensure_list_ptr(list_gen)

        # Get the index
        index_expr = self._generate(node.index_expr)

        # Convert index to i64 if it's a double
        if isinstance(index_expr, GeneratedValue):
            index_expr = self.ensure_scalar(index_expr)
        if isinstance(index_expr.type, ir.DoubleType):
            index_val = self.builder.fptosi(index_expr, self.int64_type)
        else:
            index_val = index_expr

        # Call eigen_list_get
        result = self.builder.call(self.eigen_list_get, [list_ptr, index_val])
        return result

    def get_llvm_ir(self) -> str:
        """Get the generated LLVM IR as a string."""
        return str(self.module)

    def save_ir(self, filename: str):
        """Save LLVM IR to a file."""
        with open(filename, "w") as f:
            f.write(str(self.module))

    def compile_to_object(self, output_file: str):
        """Compile LLVM IR to object file."""
        llvm_ir = str(self.module)
        mod = llvm.parse_assembly(llvm_ir)
        mod.verify()

        target = llvm.Target.from_default_triple()
        target_machine = target.create_target_machine()

        with open(output_file, "wb") as f:
            f.write(target_machine.emit_object(mod))
