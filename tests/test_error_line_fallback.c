/* #1082: a builtin's line-0 raise with no live VM frame reports the trace
 * stamp, not 0. A native (AOT) binary calls the linked builtins directly:
 * there is no interpreter frame, but g_trace_current_line is stamped per
 * statement. Before the fix rt_error resolved line 0 through the VM's live
 * line and printed "Error line 0: ..."; the AOT's own helpers, which pass
 * the stamp, printed the right line -- two different lines for one
 * program. This test raises from outside any frame with the stamp set and
 * requires the recorded message to carry it; then, with the stamp cleared,
 * requires 0 (no invented line). */
#include <stdio.h>
#include <string.h>

#include "eigs_embed.h"
#include "eigenscript.h"
#include "state.h"
#include "vm.h"
#include "trace.h"

static int fail = 0;
static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) fail = 1;
}

int main(void) {
    EigsState *st = eigs_open();
    if (!st) { printf("FAIL: eigs_open\n"); return 1; }
    g_try_depth = 1;                      /* record only, as the AOT runs */

    g_trace_current_line = 42;
    g_has_error = 0;
    rt_error(EK_VALUE, 0, "probe %d", 1);
    check(strncmp(g_error_msg, "Error line 42: probe 1", 22) == 0,
          "line-0 raise outside any frame reports the trace stamp (42)");
    check(vm_current_line() == 42, "vm_current_line answers the stamp with no live frame");

    g_has_error = 0;
    g_trace_current_line = 0;
    rt_error(EK_VALUE, 0, "probe %d", 2);
    check(strncmp(g_error_msg, "Error line 0: probe 2", 21) == 0,
          "with the stamp clear the line stays 0 (nothing invented)");

    g_has_error = 0;
    rt_error(EK_VALUE, 7, "probe %d", 3);
    check(strncmp(g_error_msg, "Error line 7: probe 3", 21) == 0,
          "an explicit line is untouched");
    return fail;
}
