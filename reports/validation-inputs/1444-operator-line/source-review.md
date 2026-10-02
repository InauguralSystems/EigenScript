CLEAN — SOURCE-ONLY REVIEW

Exact artifact: 3a8582ff4b54d4a70cc72f9943fb02b9a66d2696
Base main: 5cb91de8354d49340976ba085e6e6ddd3fe6b927
Original PR head: 97c0eb57cc4c5358ec1d06870324016a1ccb74ec
Immutable patch SHA256 independently checked:
d439f2fd961c0d45588afe6e6628bab0072f89adc748ae90f7f3161a57ceed8c

No concrete introduced P0/P1 found against issue #1425's adopted contract.
This is source-clean, not runtime PASS or a substitute for the release, sanitizer, JIT/OSR, and tape gates. No builds, tests, program execution, worktree edits, remote mutations, or builder self-review consultation occurred. Only this separate report directory was written.

Review basis

Read the actual worktree CLAUDE.md and C runtime/test-suite rules; applied eigenscript-extend-vm, eigenscript-jit, eigenscript-trace-tape-engineer, and mechanical-gates. Reviewed the full base-to-tree source/test/doc delta and relevant surrounding execution code. Principles used: No silent wrong answers; Determinism is a guarantee with a stated boundary; Checks are anchored outside the system, narrow, and few.

Compiler and parser

- compiler.c:556-575 opens the runtime scope only after RHS compilation. Nested binary expressions finish their own scopes before the enclosing scope begins. The requested-line window includes deduplicated emit_line requests; short-circuit joins invalidate last_line, so both taken and skipped paths get a runtime save/restore when needed. If every request is the operator line, scope elision is consistent with the existing caller-line restoration contract.
- Both caches restore to actual runtime values, not the last textually emitted line. Successful operations therefore preserve enclosing unary/index/call attribution. Error dispatch occurs before the closing marker and retains the operator line.
- parser.c:1178-1183 carries lexer synthesis identity only for synthesized addition; lexer interpolation splicing preserves each written token's own synth bit. AST allocation zeroes the new field. Written binary operators retain their operator columns; plain-name compound desugaring now uses the compound token's line and column. Dedicated field/index compound paths are unchanged.
- Assignment restamping remains at the statement's first line. No new AST kind or AST child edge was introduced, so existing capture/prepass walkers retain their coverage.

Bytecode and execution

- vm.h appends 95/96 after existing 94; old opcode numbers and operand widths do not change. test_opcode_abi.c pins all three. A bytecode ABI revision bump is not required for append-only opcodes.
- Audited in-tree consumers: computed-goto handlers/table, disassembler/name switch, compiler stack accounting, verifier operand/stack/CFG passes, temporal arming/shared-temporal walk, leaf scanner/executor, static-load bytecode stepping/skipping, and native scanner/emitter.
- chunk.c:759-766 constrains each new scope to exactly one non-calling arithmetic/comparison opcode followed by END. Pass 2 rejects jump and handler entry into either interior instruction. This makes one scalar save slot sufficient for verified descriptors too. The supported binary handlers do not suspend or invoke user functions.
- Native binary guard bailout retains the saved caches and resumes at the binary opcode. All native invocation paths resynchronize current_line from VM state; interpreter completion then executes END, or error dispatch retains the operator line. No scratch state needs CallFrame initialization or task-slice persistence under these adjacency constraints.

Native ABI, thread state, and tapes

- jit.c:1256-1266 resolves the attached thread's trace address while executing the thunk, not at compilation. rcx survives the helper call, stack alignment follows the existing push/pop convention, and eax is loaded after the call when its value is needed. rdx is scratch; persistent VM/frame/env/advance registers remain callee-saved. New line stores use 32-bit widths and VM layout offsets.
- Scope markers are scanner/emitter last_imm pass-throughs. Existing control-flow join reset remains effective. New emitted sequences fit the existing per-byte size budget.
- Scope begin shares ordinary LINE stamping/tape behavior. Scope end restores VM and trace caches and emits the restored tape line in both interpreter and native execution. Under the existing MT native gate, interpreter save uses current_line where trace cache updates are disabled, avoiding a stale/zero worker restore.
- Tape record encoding is unchanged; the additional L events and their successful restoration are documented. Exact cross-tier byte equality still needs runtime evidence.

Tests and witnesses

- The new uniquely named section is sourced by the existing sections/*.sh loader; its helper is defined before fragment sourcing. It gates ordinary fixtures on rc_ok and test_summary, and uncaught fixtures on rc=1, no sanitizer diagnostic, exact header/excerpt/caret/traceback lines.
- Fixtures cover written arithmetic/comparison/bitwise operators, chained and call-valued operands, operator-on-following-line syntax, plain-name compound assignment, written interpolation operators, temporal filing, successful enclosing unary/index/call errors, both short-circuit branches, and explicitly unchanged compound field/index cases.
- Named parent and compound native rows supplement the aggregate JIT witness; separate parent OSR chunks prevent one loop's OSR slot from standing in for another. Hot fixture counts cross default entry/back-edge thresholds by construction, but source review does not prove execution.
- New descriptor rows cover valid scoped arithmetic/restoration and refusal of malformed scopes/interior jumps. They use the normal verifier entry point and assertion summary.
- tests/jit_tape/binary_scope.eigs is enrolled by tools/jit_tape_diff.sh's existing corpus glob; the tool compares stdout, stderr, and full tape bytes against an interpreter run for default-JIT and forced-OSR arms. Its existing harness does not itself report per-fixture native execution; do not treat corpus enrollment alone as that witness.
- The worker trace test adds a positive-line restoration assertion while retaining its N-record and structural counts.

Scope

No separately actionable out-of-contract P0/P1 identified. No speculative rewrite is requested. Runtime gate results and red-before-green witness evidence remain the owning lane's responsibility.
