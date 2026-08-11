#!/bin/bash
# The lint split must not leak a generic helper symbol into an embedding
# archive.  A host can legitimately have its own json_escape helper; the
# archive link must remain collision-free.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="${CC:-gcc}"
WORK=$(mktemp -d /tmp/eigs_lint_linkage_XXXXXX)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/collision.c" <<'EOF'
#include <stddef.h>
void json_escape(const char *s, char *out, size_t outsz) {
    (void)s; (void)out; (void)outsz;
}
EOF
cat > "$WORK/probe.c" <<'EOF'
typedef struct ASTNode ASTNode;
typedef struct LintDiag LintDiag;
extern int lint_collect(ASTNode *, const char *, const char *, LintDiag *, int);
int lint_linkage_probe(void) {
    return lint_collect(0, 0, 0, 0, 0);
}
EOF

if [ -n "${LINT_OBJECT:-}" ]; then
    cp "$LINT_OBJECT" "$WORK/lint.o"
else
    "$CC" -std=gnu11 -O0 -w -I"$ROOT/src" -c "$ROOT/src/lint.c" -o "$WORK/lint.o"
fi
"$CC" -std=gnu11 -O0 -w -c "$WORK/collision.c" -o "$WORK/collision.o"
"$CC" -std=gnu11 -O0 -w -c "$WORK/probe.c" -o "$WORK/probe.o"
ar rcs "$WORK/liblint.a" "$WORK/lint.o"

if "$CC" -r -o "$WORK/linked.o" "$WORK/probe.o" "$WORK/collision.o" "$WORK/liblint.a"; then
    echo "PASS: lint archive keeps json escaping internal"
else
    echo "FAIL: lint archive exports a colliding json_escape symbol"
    exit 1
fi
