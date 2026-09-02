#ifndef EIGS_ENV_FLAG_H
#define EIGS_ENV_FLAG_H
#include <stdlib.h>

/* #1032: ONE convention for boolean environment flags. A flag is ON when
 * set to a non-empty value other than "0": FLAG=1 / FLAG=yes enable,
 * FLAG=0 and FLAG= (empty) disable, unset disables. Before this, half the
 * tree read booleans by PRESENCE (`if (getenv(...))`), so EIGS_JIT_OFF=0
 * turned the JIT OFF and EIGS_OBS_FORCE=0 forced the observer gate open
 * (#915). Value-carrying variables (paths, thresholds, prefixes) keep
 * plain getenv -- choosing between the two at the call site IS the
 * decision, so do not re-derive the test inline. */
static inline int eigs_env_flag(const char *name) {
    const char *s = getenv(name);
    return (s && s[0] && s[0] != '0') ? 1 : 0;
}

#endif
