- Package manifests can declare `requires` runtime variants (`http`, `gfx`,
  `zlib`, or `net`); install, verify, and import now reject unmet requirements
  with the package name and the `make` target that supplies the variant.
