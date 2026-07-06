/*
 * EigenScript REPL (CLI-only, like main.c — never part of the embeddable
 * runtime: it pulls termios/isatty, which the freestanding profile bans).
 */
#ifndef EIGENSCRIPT_REPL_H
#define EIGENSCRIPT_REPL_H

#include "eigenscript.h"

void eigenscript_repl(Env *env);

#endif
