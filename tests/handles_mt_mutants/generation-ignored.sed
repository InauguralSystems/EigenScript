# file: src/eigenscript.c
# #1146 (2): handle_claim stops comparing the generation, so a STALE handle
# claims whatever now owns its slot. That is the ABA the round-robin id
# recycling makes reachable after 255 spawn/join cycles.
/^void\* handle_claim(/,/^}$/ {
  s|^    } else if (sl->gen != gen) {$|    } else if (0) {   /* mutant: generation ignored */|
}
