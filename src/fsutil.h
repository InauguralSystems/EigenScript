/*
 * Filesystem utilities — reading a source file and resolving a module
 * request (#744). Implemented in fsutil.c.
 *
 * A leaf: no Value, no Env, nothing from the builtins layer. It is a separate
 * header rather than another block of the 1253-line eigenscript.h umbrella
 * because the consumers are specific and nameable — the VM's OP_IMPORT, the
 * compiler's observer-gate load pre-pass, main.c, fmt.c, lint_host.c, the
 * embedding API and load_file — and a TU that reads files should have to say
 * so.
 *
 * PROFILE: the whole implementation is gated (builtins_host.c's pattern).
 * With no filesystem the three resolvers are linkable stubs that resolve
 * nothing and `read_file_util` DOES NOT EXIST — guard its call sites on
 * `#if !EIGENSCRIPT_FREESTANDING`, callees included (compiler.c records what
 * happens when the guard covers the helper but not the callee: the release
 * and ASan suites stay green and the LINK step of `make freestanding-check`
 * breaks).
 */

#ifndef EIGENSCRIPT_FSUTIL_H
#define EIGENSCRIPT_FSUTIL_H

#include <stddef.h>
#include "eigenscript.h"   /* EIGENSCRIPT_FREESTANDING, eigs_current_file_dir */

#if !EIGENSCRIPT_FREESTANDING
/* Whole file into a NUL-terminated heap buffer; NULL on any failure,
 * including a non-regular file (#314). Caller frees. Hosted only. */
char* read_file_util(const char *path, long *out_size);
/* Canonical containing directory of `path`. Hosted; caller frees. */
char *eigs_file_directory(const char *path);
/* Raise EK_IO naming every root the chain tried. Hosted. */
void eigs_file_resolve_error(const char *operation, const char *base,
                            const char *path, int line);
#endif

/* One chain for import/load_file; base is the containing file's directory. */
int resolve_eigenscript_file_from(const char *base, const char *path,
                                   char *resolved, size_t resolved_cap);
/* Same chain, based at the executing chunk's directory. */
int resolve_eigenscript_file(const char *path, char *resolved, size_t resolved_cap);
/* #904: which half of the chain answered. The chain's tail steps are the
 * installed stdlib roots (`<prefix>/lib/eigenscript/`, `~/.local/lib/
 * eigenscript/`), and they answer a bare `<name>.eigs` request as well as
 * `lib/<name>.eigs` — so a STDLIB_ROOT hit on a bare request is the stdlib
 * itself, not a project file shadowing it. */
#define EIGS_RESOLVE_PROJECT       0
#define EIGS_RESOLVE_STDLIB_ROOT   1
int resolve_eigenscript_file_from_ex(const char *base, const char *path,
                                      char *resolved, size_t resolved_cap,
                                      int *origin);
/* #1046: the ONE `import NAME` resolver -- project-first, then stdlib --
 * shared by OP_IMPORT (vm.c) and the observer gate's compile-time pass
 * (compiler.c). `shadowed` (optional) receives the stdlib path a distinct
 * project file shadows, else "". Hosted; the freestanding stub resolves
 * nothing. */
int eigs_import_resolve(const char *base, const char *name,
                        char *resolved, size_t resolved_cap,
                        char *shadowed, size_t shadowed_cap);

#endif /* EIGENSCRIPT_FSUTIL_H */
