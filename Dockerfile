# EigenScript runtime image.
#
# Two-stage build: a builder stage compiles the binary + LSP against the
# Debian toolchain, the runtime stage ships only the artifacts + stdlib
# on debian:stable-slim. The image mirrors `make install PREFIX=/usr/local`
# so paths line up with the Homebrew tap and the manual install path.
#
# Default build is the slim release (no HTTP / net / db extensions),
# matching the `eigenscript-linux-x86_64` release artifact.

FROM debian:stable-slim@sha256:13e0a2e78aa0554ad5ff66e4e260c6dbcdff807eb1f39d43b9fb0288aae88b04 AS builder

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

RUN make install PREFIX=/out CC=gcc

FROM debian:stable-slim@sha256:13e0a2e78aa0554ad5ff66e4e260c6dbcdff807eb1f39d43b9fb0288aae88b04

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --shell /bin/bash eigen

COPY --from=builder /out/bin/eigenscript  /usr/local/bin/eigenscript
COPY --from=builder /out/bin/eigenlsp     /usr/local/bin/eigenlsp
COPY --from=builder /out/lib/eigenscript  /usr/local/lib/eigenscript

USER eigen
WORKDIR /work

ENTRYPOINT ["/usr/local/bin/eigenscript"]
CMD ["--version"]
