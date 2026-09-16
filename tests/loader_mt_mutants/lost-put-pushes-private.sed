# file: src/vm.c
# Revert the #1144 G0 fix: on a LOST module-cache put, keep pushing this
# thread's own private dict/env instead of adopting the winner's instance.
# That is the silent split brain — two live modules for one path, the loser's
# writes unreachable, a reader that lost the race stuck on the stale value.
s|^        if (!eigs_module_cache_put(abs_path, mod_dict, mod_env)) {$|        eigs_module_cache_put(abs_path, mod_dict, mod_env);\n        if (0) {|
