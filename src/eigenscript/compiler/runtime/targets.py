"""
Shared target configuration for EigenScript runtime cross-compilation.

This module defines the mapping between LLVM target triples and build target names,
ensuring consistency between the build system and compiler.
"""

# Map full LLVM target triples to short target names for the build script
TARGET_TRIPLE_MAP = {
    "host": "host",
    "wasm32-unknown-unknown": "wasm32",
    "aarch64-apple-darwin": "aarch64",
    "arm-linux-gnueabihf": "arm",
    "x86_64-unknown-linux-gnu": "x86_64",
}


def infer_target_name(target_triple: str) -> str:
    """Infer build target name from LLVM target triple.

    Args:
        target_triple: Full LLVM target triple (e.g., "wasm32-unknown-unknown")

    Returns:
        Short target name for build script (e.g., "wasm32")

    Examples:
        >>> infer_target_name("wasm32-unknown-unknown")
        'wasm32'
        >>> infer_target_name("aarch64-apple-darwin")
        'aarch64'
        >>> infer_target_name("custom-wasm32-target")
        'wasm32'
    """
    # Try exact match first
    if target_triple in TARGET_TRIPLE_MAP:
        return TARGET_TRIPLE_MAP[target_triple]

    # Infer from triple components
    triple_lower = target_triple.lower()

    if "wasm32" in triple_lower:
        return "wasm32"
    elif "aarch64" in triple_lower or "arm64" in triple_lower:
        return "aarch64"
    elif triple_lower.startswith("arm-") or "arm-" in triple_lower:
        return "arm"
    elif "x86_64" in triple_lower:
        return "x86_64"
    else:
        # Default to host for unknown triples
        return "host"
