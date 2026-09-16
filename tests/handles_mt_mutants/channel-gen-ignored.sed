# file: src/eigenscript.c
# A BLIND CRITIC'S OWN MUTANT, enrolled because it SURVIVED the round-1 oracle
# 10/10: the generation is still bumped on every register, but handle_lookup
# skips the generation compare for CHANNEL handles only. Round 1 had no live
# row that presented a channel handle with a wrong generation, and
# construction_gen only counts call-site arity — a grep cannot witness
# execution. Measured symptom on the critic's probe: forged-generation `recv`
# returned the real message, stripped-generation `recv` HUNG (rc 124).
#
# Ported from the critic's `fable-channel-gen-ignored.sed`, which was written
# against round 1's `&&`-chained handle_lookup; round 2 split that condition
# into a three-way diagnosis, so the same intent lands on the STALE arm.
/^void\* handle_lookup(int id, uint32_t gen, HandleType type, int \*why) {$/,/^}$/ {
  s|^    } else if (sl->gen != gen) {$|    } else if (sl->gen != gen \&\& type != HANDLE_CHANNEL) {   /* mutant */|
}
