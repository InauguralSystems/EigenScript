"""
Module Resolver for EigenScript
Locates source files for imported modules.
"""

import os
from typing import List, Optional
from pathlib import Path


class ModuleResolver:
    """
    Resolves module names to file paths.

    Implements the search strategy:
    1. Current working directory (local modules)
    2. Standard Library path (system modules)
    """

    def __init__(self, root_dir: str = None):
        """
        Initialize the resolver.

        Args:
            root_dir: The root directory of the main program.
                      Defaults to current working directory.
        """
        self.search_paths: List[str] = []

        # 1. Add local directory (priority)
        if root_dir:
            self.search_paths.append(os.path.abspath(root_dir))
        else:
            self.search_paths.append(os.getcwd())

        # 2. Add Standard Library Path
        # Check environment variable first, then fall back to package stdlib
        stdlib_path = os.environ.get("EIGEN_PATH")
        if stdlib_path and os.path.exists(stdlib_path):
            self.search_paths.append(stdlib_path)
        else:
            # Auto-detect stdlib path relative to this file
            # resolver.py is in src/eigenscript/compiler/analysis/
            # stdlib is in src/eigenscript/stdlib/
            this_file = Path(__file__).resolve()
            stdlib_dir = this_file.parent.parent.parent / "stdlib"
            if stdlib_dir.exists():
                self.search_paths.append(str(stdlib_dir))

    def resolve(self, module_name: str) -> str:
        """
        Find the file path for a given module name.

        Args:
            module_name: The name of the module (e.g., "physics")

        Returns:
            Absolute path to the .eigs file

        Raises:
            ImportError: If the module cannot be found
        """
        # Convert "physics" -> "physics.eigs"
        filename = f"{module_name}.eigs"

        for path in self.search_paths:
            file_path = os.path.join(path, filename)
            if os.path.exists(file_path):
                return file_path

        # Not found in any search path
        raise ImportError(
            f"Could not find module '{module_name}'. \n"
            f"Searched in: {', '.join(self.search_paths)}"
        )

    def get_output_path(self, source_path: str, target_triple: str = None) -> str:
        """
        Determine where the compiled object file should go.

        Logic:
        physics.eigs -> physics.o (Native)
        physics.eigs -> physics.wasm (WASM)
        """
        base = os.path.splitext(source_path)[0]

        # Determine extension based on architecture (Phase 3 logic)
        is_wasm = target_triple and "wasm" in target_triple

        # Modules are always compiled to Object Files (.o) first
        # They are linked into the final .exe/.wasm later
        return f"{base}.o"
