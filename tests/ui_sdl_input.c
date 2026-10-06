/* Actual SDL queue -> public gfx_poll acceptance (#1263).
 * The authoritative SDL header owns fixture layout; production keeps its
 * optional dlopen interface. No private decoder or synthetic EigenScript dict.
 */
#include <SDL.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "eigs_embed.h"

static int eval_ok(const char *source) {
    EigsValue *v = eigs_eval_string(source);
    if (!v) {
        fprintf(stderr, "ui SDL input FAIL: %s\n", eigs_last_error_message());
        return 0;
    }
    eigs_value_release(v);
    return 1;
}
static int drain_events(void) {
    SDL_Event event;
    SDL_PumpEvents();
    /* PollEvent's cycle sentinel can report empty before a newly queued warp
     * event. Preparation drains the queue directly; the test still consumes
     * the injected event only through public gfx_poll. */
    for (int i = 0; i < 256; i++) {
        int n = SDL_PeepEvents(&event, 1, SDL_GETEVENT, SDL_FIRSTEVENT, SDL_LASTEVENT);
        if (n == 0) return 1;
        if (n < 0) return 0;
    }
    fprintf(stderr, "ui SDL input FAIL: unexpected continuous event source\n");
    return 0;
}

int main(void) {
    alarm(20);
    EigsState *state = eigs_open();
    if (!state) return 2;
    int passed = 0;
    int ok = eval_ok("assert of [(gfx_open of [80, 60, \"ui-input-1263\"]) == true, \"open\"]\n");
    const char *checks[] = {
        "e.type == \"keydown\" and e.key == \"up\" and e.scancode == 82 and e.shift == true and e.ctrl == false and e.alt == false",
        "e.type == \"keyup\" and e.key == \"a\" and e.scancode == 4 and e.shift == false and e.ctrl == true and e.alt == true",
        "e.type == \"mousemove\" and e.x == 321 and e.y == 654 and e.shift == false and e.ctrl == true and e.alt == true",
        "e.type == \"mousedown\" and e.button == 3 and e.x == 111 and e.y == 222 and e.shift == false and e.ctrl == true and e.alt == true",
        "e.type == \"mouseup\" and e.button == 3 and e.x == 112 and e.y == 223 and e.shift == false and e.ctrl == true and e.alt == true",
        "e.type == \"wheel\" and e.x == -2 and e.y == 5 and e.mx == 17 and e.my == 23 and e.shift == false and e.ctrl == true and e.alt == true",
        "e.type == \"resize\" and e.w == 640 and e.h == 480",
        "e.type == \"quit\""
    };
    const int declared = (int)(sizeof(checks) / sizeof(checks[0]));
    for (int i = 0; ok && i < declared; i++) {
        SDL_Event event;
        memset(&event, 0, sizeof(event));
        SDL_SetModState((SDL_Keymod)(KMOD_CTRL | KMOD_ALT));
        if (i == 5) {
            /* This process owns its only, first SDL window. Check identity
             * before the warp and the actual mouse-state result afterward. */
            SDL_Window *window = SDL_GetWindowFromID(1);
            if (!window) { ok = 0; break; }
            SDL_WarpMouseInWindow(window, 17, 23);
            SDL_PumpEvents();
            int x = -1, y = -1;
            SDL_GetMouseState(&x, &y);
            if (x != 17 || y != 23) { ok = 0; break; }
        }
        if (!drain_events()) { ok = 0; break; }
        switch (i) {
        case 0:
            event.key.type = SDL_KEYDOWN;
            event.key.keysym.scancode = SDL_SCANCODE_UP;
            event.key.keysym.mod = KMOD_SHIFT;
            break;
        case 1:
            event.key.type = SDL_KEYUP;
            event.key.keysym.scancode = SDL_SCANCODE_A;
            event.key.keysym.mod = KMOD_CTRL | KMOD_ALT;
            break;
        case 2:
            event.motion.type = SDL_MOUSEMOTION;
            event.motion.state = SDL_BUTTON_LMASK;
            event.motion.x = 321; event.motion.y = 654;
            break;
        case 3: case 4:
            event.button.type = i == 3 ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
            event.button.button = SDL_BUTTON_RIGHT;
            event.button.x = i == 3 ? 111 : 112;
            event.button.y = i == 3 ? 222 : 223;
            break;
        case 5:
            event.wheel.type = SDL_MOUSEWHEEL;
            event.wheel.x = -2; event.wheel.y = 5;
            break;
        case 6:
            event.window.type = SDL_WINDOWEVENT;
            event.window.event = SDL_WINDOWEVENT_SIZE_CHANGED;
            event.window.data1 = 640; event.window.data2 = 480;
            break;
        case 7: event.type = SDL_QUIT; break;
        }
        if (SDL_PushEvent(&event) != 1) {
            fprintf(stderr, "ui SDL input FAIL: push case %d: %s\n", i, SDL_GetError());
            ok = 0; break;
        }
        char source[768];
        int n = snprintf(source, sizeof(source),
                         "e is gfx_poll of null\nprint of (json_encode of e)\nassert of [%s, \"SDL event case %d\"]\n", checks[i], i);
        if (n < 0 || (size_t)n >= sizeof(source)) { ok = 0; break; }
        ok = eval_ok(source);
        if (ok) passed++;
    }
    eigs_clear_error();
    if (!eval_ok("gfx_close of null\n")) ok = 0;
    eigs_close(state);
    printf("ui SDL queue: %d/%d event cases passed\n", passed, declared);
    return ok && declared > 0 && passed == declared ? 0 : 1;
}
