#!/bin/bash
set -e

cd "$(dirname "$0")"

# Nix store paths are content-addressed and stable for a given package version.
# If Replit updates the Nix environment (e.g. libpq 17.5 -> 17.6), these hashes
# will change. To fix: run `ldd eigenscript` or `nix-store -qR` in the dev
# environment to find the new paths, then update these two lines.
LIBPQ_INC="/nix/store/frrk8i0xkrs1y52qaygvf7d8gqzwwh2a-libpq-17.5-dev/include"
LIBPQ_LIB="/nix/store/931zxim0z7ilbnr6pnhpl69cxbhbb7wz-libpq-17.5/lib"

gcc -O2 -o eigenscript eigenscript.c \
    -I"$LIBPQ_INC" \
    -L"$LIBPQ_LIB" \
    -Wl,-rpath,"$LIBPQ_LIB" \
    -lm -lpthread -lpq

rm -rf libs
mkdir -p libs
ldd ./eigenscript | grep "=> /" | awk '{print $3}' | xargs -I{} cp {} libs/
ldd ./eigenscript | grep "ld-linux" | awk '{print $1}' | xargs -I{} cp {} libs/ld-linux-x86-64.so.2

printf '#!/bin/bash\nDIR="$(cd "$(dirname "$0")" && pwd)"\nexec "$DIR/libs/ld-linux-x86-64.so.2" --library-path "$DIR/libs" "$DIR/eigenscript" "$@"\n' > run.sh
chmod +x run.sh

echo "Build complete. Binary: $(du -sh eigenscript | cut -f1), Libs: $(du -sh libs | cut -f1)"
