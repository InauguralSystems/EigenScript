# Shared dev + CI image for EigenScript.
#
# Single source of truth: this is the image `.devcontainer/devcontainer.json`
# opens in Codespaces AND the image `ci.yml`'s Linux legs run inside
# (`container:`). So "builds in my Codespace" and "passes CI" cannot drift —
# they execute the same toolchain on the same base OS.
#
# NOTE: this is a *dev/build* environment, not a runtime image. The runtime
# image (a slim, artifact-only release) is the separate top-level `Dockerfile`
# published by `.github/workflows/docker.yml`. Keep the two distinct.
#
# Base mirrors the runtime image family (debian stable). Built linux/amd64 so
# the copy-and-patch JIT (src/jit.c is __x86_64__-gated) is actually exercised
# rather than silently falling back to the interpreter.
FROM debian:stable

ENV DEBIAN_FRONTEND=noninteractive

# Dep union across every CI leg:
#   build-essential  -> gcc, make, binutils (objdump for JIT disassembly)
#   clang            -> the second compiler in the build matrix
#   libpq-dev        -> `make full` / build.sh full (ext_db.c, -lpq)
#   postgresql-client-> psql, for poking the devcontainer's db sidecar
#   python3          -> tests/test_doc_examples.py (suite section [89])
#   python3-yaml     -> tools/workflow_yaml_check.sh arm (b), the REAL YAML
#                       loader behind suite section [99zd]. Without it that arm
#                       SKIPs BY NAME and two of the gate's planted faults
#                       cannot go red: on 538288c that took linux/gcc, macOS
#                       and ASan shard 2/3 red at once (CI run 35599371704).
#                       A gate whose second arm never runs on the lane is the
#                       round-1 "a lane that never ran" failure in a new hat.
#   gdb              -> the JIT debugging workflow (see CLAUDE.md)
#   curl             -> exercising the http extension by hand
# SDL2 is deliberately absent: `make gfx` dlopen's it at runtime and compiles
# against typedefs only, so no -dev headers are needed to build it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        clang \
        ca-certificates \
        git \
        libpq-dev \
        zlib1g-dev \
        postgresql-client \
        python3 \
        python3-yaml \
        gdb \
        curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /workspaces/EigenScript
