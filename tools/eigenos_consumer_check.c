/* Link-only EigenOS consumer check.  This TU intentionally uses no hosted
 * entry point or libc API: tools/freestanding_check.sh compiles it with
 * -ffreestanding and links it with the freestanding runtime plus mini-libc.
 * Keeping the call externally visible prevents optimization from erasing the
 * public symbol reference that this check exists to verify. */
#include "../src/eigs_embed.h"

void eigenos_configure_eigs_state(EigsState *state, int strict) {
    eigs_state_set_strict(state, strict);
}
