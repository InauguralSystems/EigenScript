#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/libs/ld-linux-x86-64.so.2" --library-path "$DIR/libs" "$DIR/eigenscript" "$@"
