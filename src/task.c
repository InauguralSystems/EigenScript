/*
 * The cooperative task scheduler (#408), split out of vm.c by #744.
 *
 * Self-contained by construction: `TaskScheduler` and every scheduler static
 * live in THIS file and nothing outside it names them. The seam with the VM
 * is task.h and is a handful of functions wide in each direction — the
 * dispatch loop's slice hooks and `task_sched_after_outermost` going in, and
 * `vm_task_run_entry` / `vm_task_resume` / `vm_task_take_error` coming back
 * out. Those three are wrappers in vm.c, deliberately: the dispatch function
 * they call stays `static` there.
 *
 * The scheduler is DETERMINISTIC — no tape records; the interleaving is a
 * pure function of program order (or of the installed seed, #535). Nothing
 * about that changes here: this file is the same statements at a new address.
 */

#include "eigenscript.h"
#include "vm.h"
#include "task.h"
#include "trace.h"

/* Forward decls for the file's own statics that are used before definition
 * (these sat at the top of vm.c's dispatch loop before the split). */
static void task_reap(Task *t);   /* #530 */

/* ===== #408 cooperative task scheduler ==================================
 * A trampoline just above the OUTERMOST vm_execute drives every task —
 * including task 0 (the main program) — so C-stack depth stays flat
 * (vm_execute → scheduler → one vm_run) no matter how often tasks ping-pong.
 * A task suspends by a builtin setting g_task_suspend_request; the CASE(CALL)
 * site saves its live stack+frame slice (the copying-stack model: memory =
 * live depth, not a full 1.28 MB VM per task) and returns here, which runs
 * the next ready task. Deterministic by construction — no tape records; the
 * interleaving is a pure function of program order.
 * ======================================================================== */

#define TASK_READY_MAX HANDLE_TABLE_SIZE

/* #846: one scheduler-trace entry — a resume. `seq` is the entry's index. */
typedef struct {
    double  tick;    /* virtual clock (task_now) at the resume */
    int     task;    /* resumed task id (0 = main) */
    uint8_t cause;   /* SCAUSE_* below */
} SchedTraceEntry;

typedef struct {
    int   ready[TASK_READY_MAX];  /* circular FIFO of runnable task ids (0=main) */
    int   rhead, rcount;
    int   current;                /* running task id; 0 = main */
    int   live;                   /* spawned tasks not yet DONE/DEAD */
    int   active;                 /* armed on first spawn */
    int   dead_letters;           /* inc 2: sends to finished/unknown tasks */
    int   detached_err_count;     /* #530: reaped detached tasks that died unobserved (#493 gate) */
    uint64_t spawn_counter;       /* #535: monotonically increasing; stamps Task.spawn_seq */
    double now;                   /* inc 3: virtual clock (logical, starts 0) */
    int   seeded;                 /* inc 4: 1 once task_sched_seed installs a seed */
    uint64_t rng_state;           /* inc 4: splitmix64 state for the seeded pick */
    /* #846: WHY each ready entry became runnable, kept in lockstep with
     * `ready` (same index, moved by the same compaction). A property of the
     * queue entry, not of the task: the cause is fixed at enqueue time and
     * consumed by the pop that resumes the task. Always maintained — it is
     * one byte store per enqueue — so arming the trace mid-run changes
     * nothing about the schedule, only whether a pop is written down. */
    uint8_t ready_cause[TASK_READY_MAX];
    int   pop_cause;              /* #846: cause of the most recent sched_ready_pop */
    /* #846: the recorded history — one entry per trampoline resume while
     * g_task_trace_on. Freed in task_sched_thread_free. Unbounded by design:
     * a silent cap would make a long run's trace lie about its tail. */
    SchedTraceEntry *trace;
    int   trace_count, trace_cap;
    Task  main_task;              /* task 0 — save-buffer only, never "started" */
} TaskScheduler;

/* #846: the cause vocabulary, enumerated from the enqueue sites below — every
 * sched_ready_push names one. A resumed task was enqueued by exactly one of:
 *   spawn         task_sched_on_spawn — its first run (task_start)
 *   yield         a task_yield re-enqueue (trampoline / main's first suspend)
 *   sleep-wake    sched_wake_sleepers advanced the virtual clock to its wake_at
 *   join-release  the task it was joined on finished (sched_finish)
 *   kill-release  the task it was joined on was task_kill'ed (task_do_kill)
 *   recv-wake     task_send delivered to its empty mailbox (task_deliver)
 *   deadlock      main re-enqueued to receive the catchable deadlock (#509)
 * Names are the .eigs-visible contract (docs/CONCURRENCY.md). */
enum {
    SCAUSE_SPAWN = 0, SCAUSE_YIELD, SCAUSE_SLEEP_WAKE, SCAUSE_JOIN_RELEASE,
    SCAUSE_KILL_RELEASE, SCAUSE_RECV_WAKE, SCAUSE_DEADLOCK, SCAUSE__COUNT
};
static const char *const sched_cause_name[SCAUSE__COUNT] = {
    "spawn", "yield", "sleep-wake", "join-release", "kill-release",
    "recv-wake", "deadlock"
};

static TaskScheduler *sched_get(void) { return (TaskScheduler *)g_task_sched; }

static TaskScheduler *sched_ensure(void) {
    TaskScheduler *s = sched_get();
    if (!s) {
        s = xcalloc(1, sizeof(TaskScheduler));
        s->main_task.id = 0;
        s->main_task.state = TASK_RUNNING;
        s->current = 0;
        g_task_sched = s;
    }
    return s;
}

void task_sched_thread_free(void) {
    TaskScheduler *s = sched_get();
    if (!s) return;
    Task *m = &s->main_task;
    /* #483: main is USUALLY run-to-completion here (empty slice). But a fatal
     * exit while main is still SUSPENDED — a `deadlock`, or main blocked on a
     * join/recv that never resolves — leaves a live saved slice whose counted
     * refs would otherwise leak: the base module frame owns a chunk ref (the
     * script chunk, see vm_run's frame push), and the operand stack owns value
     * refs. Release them, mirroring task_free's worker-slice teardown, before
     * freeing the arrays. (owns_env is 0 for the module frame — the global env
     * is dropped separately in main.c/eigs_close — so only chunk_decref here.) */
    if (m->saved_stack) {
        for (int i = 0; i < m->saved_stack_len; i++) slot_decref(m->saved_stack[i]);
        free(m->saved_stack);
    }
    if (m->saved_frames) {
        for (int i = 0; i < m->saved_frame_count; i++)
            callframe_release(&m->saved_frames[i]);
        free(m->saved_frames);
    }
    if (m->mbox) {
        for (int i = 0; i < m->mbox_count; i++)
            val_decref(m->mbox[(m->mbox_head + i) % m->mbox_cap]);
        free(m->mbox);
    }
    if (m->result) val_decref(m->result);
    if (m->error_value) val_decref(m->error_value);
    free(s->trace);   /* #846 */
    free(s);
    g_task_sched = NULL;
}

static Task *sched_lookup(TaskScheduler *s, int id) {
    if (id == 0) return &s->main_task;
    return (Task *)handle_lookup(id, HANDLE_TASK);
}

/* #493: does any worker still carry an uncaught-error death that no task_join
 * ever observed? Scanned once at process exit (before handle_table_drain frees
 * the tasks) so a fire-and-forget worker's death makes the process exit
 * non-zero instead of silently returning 0. */
int task_any_unobserved_error(void) {
    if (!g_task_sched) return 0;
    /* #530: reaped detached tasks that died unobserved are counted, not held. */
    if (((TaskScheduler *)g_task_sched)->detached_err_count > 0) return 1;
    for (int i = 1; i < HANDLE_TABLE_SIZE; i++) {
        Task *t = (Task *)handle_lookup(i, HANDLE_TASK);
        if (t && t->err_unobserved) return 1;
    }
    return 0;
}

Task *task_current_running(void) {
    TaskScheduler *s = sched_get();
    return s ? sched_lookup(s, s->current) : NULL;
}

static void sched_ready_push(TaskScheduler *s, int id, int cause) {
    if (s->rcount >= TASK_READY_MAX) return;   /* ids are table-bounded; can't overflow */
    int slot = (s->rhead + s->rcount) % TASK_READY_MAX;
    s->ready[slot] = id;
    s->ready_cause[slot] = (uint8_t)cause;   /* #846: rides with the entry */
    s->rcount++;
}

/* #530: drop tid's pending ready-queue entry. A task killed while READY (or
 * woken but not yet run) used to leave its entry behind; the trampoline
 * skips stale ids, but enough of them FILL the fixed queue and
 * sched_ready_push silently drops real wakeups — a spurious "deadlock".
 * A task has at most one entry (recv-wake is idempotent and a task must be
 * popped before it can re-enqueue), so one compacting pass suffices. */
static void sched_ready_remove(TaskScheduler *s, int tid) {
    int w = 0;
    for (int k = 0; k < s->rcount; k++) {
        int from = (s->rhead + k) % TASK_READY_MAX;
        int id = s->ready[from];
        if (id != tid) {
            int to = (s->rhead + w) % TASK_READY_MAX;
            s->ready[to] = id;
            s->ready_cause[to] = s->ready_cause[from];   /* #846: lockstep */
            w++;
        }
    }
    s->rcount = w;
}

/* Inc 4: splitmix64 — a deterministic, platform-independent integer PRNG for
 * the seeded scheduling strategy. Pure integer arithmetic (no float, no OS
 * entropy), so the pick sequence is a reproducible function of the installed
 * seed + program order — the seeded schedule replays byte-identically and
 * records no tape nondeterminism. */
static uint64_t sched_rng_next(TaskScheduler *s) {
    uint64_t z = (s->rng_state += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

/* task_sched_seed: install a seed and switch the scheduler from FIFO
 * round-robin to a seeded pseudo-random pick of the next ready task. Ensures
 * the scheduler exists so the seed sticks even when set before the first
 * task_spawn. The interleaving stays deterministic — a DST varies the seed to
 * explore different interleavings, each fully reproducible. */
void task_sched_set_seed(double seed) {
    TaskScheduler *s = sched_ensure();
    s->rng_state = (uint64_t)(int64_t)seed;   /* integer seeds; fractions truncate */
    s->seeded = 1;
}

static int sched_ready_pop(TaskScheduler *s) {
    if (s->rcount == 0) return -1;
    if (!s->seeded || s->rcount == 1) {
        /* Default FIFO: O(1) head pop — the fast path, unchanged. */
        int id = s->ready[s->rhead];
        s->pop_cause = s->ready_cause[s->rhead];   /* #846 */
        s->rhead = (s->rhead + 1) % TASK_READY_MAX;
        s->rcount--;
        return id;
    }
    /* Seeded strategy: pick a pseudo-random ready task, then compact the hole
     * by shifting the suffix down one (order-preserving among the rest). O(n)
     * in the ready count, which is tiny and only paid in DST/seeded mode. */
    int idx = (int)(sched_rng_next(s) % (uint64_t)s->rcount);
    int id  = s->ready[(s->rhead + idx) % TASK_READY_MAX];
    s->pop_cause = s->ready_cause[(s->rhead + idx) % TASK_READY_MAX];   /* #846 */
    for (int k = idx; k < s->rcount - 1; k++) {
        int to = (s->rhead + k) % TASK_READY_MAX, from = (s->rhead + k + 1) % TASK_READY_MAX;
        s->ready[to] = s->ready[from];
        s->ready_cause[to] = s->ready_cause[from];   /* #846: lockstep */
    }
    s->rcount--;
    return id;
}

/* ---- #846: the scheduler trace ------------------------------------------
 * Pure reader: called from the trampoline AFTER the pick is made and BEFORE
 * the task runs, with nothing but scheduler state as input. No tape record —
 * the schedule is a pure function of program order (+ seed), so a replayed
 * run re-derives the identical history; a tape-recorded trace would be a
 * second, redundant source of truth that could disagree with the first. */
static void sched_trace_record(TaskScheduler *s, int id, int cause) {
    if (s->trace_count == s->trace_cap) {
        int nc = s->trace_cap ? s->trace_cap * 2 : 64;
        s->trace = xrealloc(s->trace, sizeof(SchedTraceEntry) * (size_t)nc);
        s->trace_cap = nc;
    }
    SchedTraceEntry *e = &s->trace[s->trace_count++];
    e->tick  = s->now;
    e->task  = id;
    e->cause = (uint8_t)cause;
}

Value *task_sched_trace_read(void) {
    TaskScheduler *s = sched_get();
    if (!s) return make_list(0);
    Value *out = make_list(s->trace_count);
    for (int i = 0; i < s->trace_count; i++) {
        const SchedTraceEntry *e = &s->trace[i];
        Value *d = make_dict(4);
        dict_set_owned(d, "seq",   make_num((double)i));
        dict_set_owned(d, "tick",  make_num(e->tick));
        dict_set_owned(d, "task",  make_num((double)e->task));
        dict_set_owned(d, "cause", make_str(e->cause < SCAUSE__COUNT
                                            ? sched_cause_name[e->cause] : "?"));
        list_append_owned(out, d);
    }
    return out;
}

void task_sched_trace_clear(void) {
    TaskScheduler *s = sched_get();
    if (s) s->trace_count = 0;   /* keep the buffer; re-arming reuses it */
}

/* Copying-stack save: memcpy the running task's live slice [0,fc)/[0,sp) into
 * its right-sized save-buffer, then retreat the VM to empty. Refs move WITH
 * the bytes (the saved slots/frames own the same counted refs that were on
 * the stack), so sp/frame_count just retreat — no incref/decref, no walk. */
void task_save_slice(Task *t) {
    if (!t) return;
    int fc = g_vm.frame_count, sp = g_vm.sp;
    free(t->saved_frames);
    free(t->saved_stack);
    t->saved_frames = fc ? xmalloc(sizeof(CallFrame) * fc) : NULL;
    t->saved_stack  = sp ? xmalloc(sizeof(EigsSlot) * sp)  : NULL;
    if (fc) memcpy(t->saved_frames, g_vm.frames, sizeof(CallFrame) * fc);
    if (sp) memcpy(t->saved_stack,  g_vm.stack,  sizeof(EigsSlot) * sp);
    t->saved_frame_count  = fc;
    t->saved_stack_len    = sp;
    t->saved_current_line = g_vm.current_line;
    g_vm.frame_count = 0;
    g_vm.sp = 0;
    t->state = TASK_SUSPENDED;
}

/* Copying-stack restore: memcpy a suspended task's slice back onto the empty
 * VM. Symmetric with save — refs move back with the bytes. */
void task_restore_slice(Task *t) {
    int fc = t->saved_frame_count, sp = t->saved_stack_len;
    if (fc) memcpy(g_vm.frames, t->saved_frames, sizeof(CallFrame) * fc);
    if (sp) memcpy(g_vm.stack,  t->saved_stack,  sizeof(EigsSlot) * sp);
    g_vm.frame_count  = fc;
    g_vm.sp           = sp;
    g_vm.current_line = t->saved_current_line;
    free(t->saved_frames); t->saved_frames = NULL;
    free(t->saved_stack);  t->saved_stack  = NULL;
    t->saved_frame_count = 0;
    t->saved_stack_len   = 0;
    t->state = TASK_RUNNING;
}

/* task_spawn (builtins.c) hands a freshly registered task here. */
void task_sched_on_spawn(int id) {
    TaskScheduler *s = sched_ensure();
    s->active = 1;
    s->live++;
    /* #535: stamp spawn order. Handle IDs come from a rotating cursor, so
     * they encode the process's WHOLE allocation history; any id-ordered
     * tie-break makes the interleaving history-dependent. Spawn order is a
     * pure function of the run. Main is 0 (spawn_counter starts at 1). */
    Task *t = sched_lookup(s, id);
    if (t) t->spawn_seq = ++s->spawn_counter;
    sched_ready_push(s, id, SCAUSE_SPAWN);
}

/* task_yield: mark the current task for suspension; the trampoline re-enqueues
 * it at the tail (round-robin) after the save. */
void task_request_yield(void) { g_task_suspend_request = 1; }

/* task_join: block the current task on `target`. Returns 0 for a bad target
 * (main, self, or unknown) so the builtin can fall back; 1 to suspend. A
 * target that is already finished is handled in the builtin (returns its
 * result without suspending). */
int task_request_join(int target) {
    TaskScheduler *s = sched_get();
    if (!s || target == 0 || target == s->current) return 0;
    Task *tt = sched_lookup(s, target);
    if (!tt) return 0;
    Task *cur = sched_lookup(s, s->current);
    cur->join_target = target;
    g_task_suspend_request = 1;
    return 1;
}

/* ---- Inc 2: mailboxes -------------------------------------------------- */

/* Append msg (ownership transferred in) to task `tid`'s FIFO mailbox and wake
 * it if it is blocked in task_recv. Returns 1 if delivered, 0 if dropped
 * because the target is gone (finished/unknown) — send-to-dead is a silent
 * drop plus a dead-letter count (Akka dead-letters / Erlang cast), NOT an
 * error: an error path here would be a nondeterminism magnet. */
int task_deliver(int tid, Value *msg_owned) {
    TaskScheduler *s = sched_get();
    Task *t = s ? sched_lookup(s, tid) : NULL;
    if (!t || t->state == TASK_DONE || t->state == TASK_DEAD) {
        if (s) s->dead_letters++;
        return 0;
    }
    if (t->mbox_count >= t->mbox_cap) {
        int nc = t->mbox_cap ? t->mbox_cap * 2 : 8;
        Value **nb = xmalloc(sizeof(Value *) * nc);
        for (int i = 0; i < t->mbox_count; i++)
            nb[i] = t->mbox[(t->mbox_head + i) % t->mbox_cap];
        free(t->mbox);
        t->mbox = nb; t->mbox_cap = nc; t->mbox_head = 0;
    }
    t->mbox[(t->mbox_head + t->mbox_count) % t->mbox_cap] = msg_owned;
    t->mbox_count++;
    /* Wake a recv-blocked receiver on the FIRST message that arrives while it
     * waits on an empty mailbox (mbox_count just became 1). recv_blocked stays
     * set so the resume path (task_apply_recv_result) delivers this message and
     * clears it; the mbox_count==1 guard makes the enqueue idempotent — a
     * second send before the receiver resumes finds count>1 and does not
     * re-enqueue (which would put the task in the ready queue twice). */
    if (t->recv_blocked && t->state == TASK_SUSPENDED && t->mbox_count == 1)
        sched_ready_push(s, tid, SCAUSE_RECV_WAKE);
    return 1;
}

int task_mbox_has(void) {
    Task *t = task_current_running();
    return (t && t->mbox_count > 0) ? 1 : 0;
}

Value *task_mbox_pop(void) {
    Task *t = task_current_running();
    if (!t || t->mbox_count == 0) return make_null();
    Value *v = t->mbox[t->mbox_head];
    t->mbox_head = (t->mbox_head + 1) % t->mbox_cap;
    t->mbox_count--;
    return v;   /* owned ref transfers to caller */
}

void task_request_recv(void) {
    Task *t = task_current_running();
    if (t) t->recv_blocked = 1;
    g_task_suspend_request = 1;
}

/* ---- Inc 3: virtual time ---------------------------------------------- */

/* task_sleep: the current task becomes runnable again when the virtual clock
 * reaches now + ticks. The trampoline advances the clock only when nothing is
 * runnable (see sched_wake_sleepers), so time is a pure function of program
 * order + sleep durations — no tape records, no wall clock. A negative sleep
 * is clamped to 0 (a same-tick yield to everything currently ready). */
void task_request_sleep(double ticks) {
    TaskScheduler *s = sched_get();
    Task *t = task_current_running();
    if (!s || !t) return;
    double dt = ticks > 0 ? ticks : 0;
    t->wake_at = s->now + dt;
    t->sleeping = 1;
    g_task_suspend_request = 1;
}

double task_virtual_now(void) {
    TaskScheduler *s = sched_get();
    return s ? s->now : 0;
}

/* task_self (builtins.c): the running task's id, in the same integer space
 * task_spawn returns — 0 for the main task, including before any scheduler
 * exists. Pure scheduler state, so no tape participation. */
int task_current_id(void) {
    TaskScheduler *s = sched_get();
    return s ? s->current : 0;
}

/* When the ready queue is empty, advance the virtual clock to the earliest
 * sleeper's wake time and make every task due at (or before) that instant
 * runnable. Returns 1 if any sleeper was woken (the trampoline then loops),
 * 0 if there are no sleepers (genuine idle → done or deadlock). Ties at the
 * same wake_at are broken by ascending task id (main = 0 first), so the
 * interleaving stays deterministic. The clock only ever moves forward:
 * wake_at = now + dt >= now, so the min is never behind the current now. */
static int sched_wake_sleepers(TaskScheduler *s) {
    double best = 0; int have_best = 0;
    if (s->main_task.state == TASK_SUSPENDED && s->main_task.sleeping) {
        best = s->main_task.wake_at; have_best = 1;
    }
    for (int i = 1; i < HANDLE_TABLE_SIZE; i++) {
        Task *t = (Task *)handle_lookup(i, HANDLE_TASK);
        if (t && t->state == TASK_SUSPENDED && t->sleeping &&
            (!have_best || t->wake_at < best)) {
            best = t->wake_at; have_best = 1;
        }
    }
    if (!have_best) return 0;
    s->now = best;
    /* Wake main first, then tasks in ascending SPAWN order (#535) — NOT id
     * order: ids come from a rotating next-fit cursor, so id order encodes
     * the process's whole allocation history and two identical seeded runs
     * in one process could interleave differently once slots recycle
     * (surfaced by liferaft's in-sweep fault verify failing to reproduce
     * standalone). Spawn order is a pure function of the run itself. */
    if (s->main_task.state == TASK_SUSPENDED && s->main_task.sleeping &&
        s->main_task.wake_at <= s->now) {
        s->main_task.sleeping = 0;
        sched_ready_push(s, 0, SCAUSE_SLEEP_WAKE);
    }
    for (;;) {
        Task *next = NULL;
        for (int i = 1; i < HANDLE_TABLE_SIZE; i++) {
            Task *t = (Task *)handle_lookup(i, HANDLE_TASK);
            if (t && t->state == TASK_SUSPENDED && t->sleeping && t->wake_at <= s->now &&
                (!next || t->spawn_seq < next->spawn_seq))
                next = t;
        }
        if (!next) break;
        next->sleeping = 0;
        sched_ready_push(s, next->id, SCAUSE_SLEEP_WAKE);
    }
    return 1;
}

/* Deterministic teardown of a task mid-run (task_kill): drop its mailbox and
 * saved slice, wake any joiner with an `interrupt` error, mark it DEAD. The
 * handle entry stays (task_alive → 0, joiners see DEAD); handle_table_drain
 * frees the struct at exit. Returns 0 for a bad/self/finished target. */
int task_do_kill(int tid) {
    TaskScheduler *s = sched_get();
    if (!s || tid == 0 || tid == s->current) return 0;
    Task *t = sched_lookup(s, tid);
    if (!t || t->state == TASK_DONE || t->state == TASK_DEAD) return 0;
    /* #530: a READY/woken victim holds a ready-queue entry — remove it so
     * dead ids can never fill the queue and starve real wakeups. */
    sched_ready_remove(s, tid);
    /* Drain the mailbox. */
    while (t->mbox_count > 0) {
        val_decref(t->mbox[t->mbox_head]);
        t->mbox_head = (t->mbox_head + 1) % t->mbox_cap;
        t->mbox_count--;
    }
    free(t->mbox); t->mbox = NULL; t->mbox_cap = 0; t->mbox_head = 0;
    /* Release the suspended slice's counted refs (mirror task_free's slice
     * teardown) so a killed suspended task doesn't leak. */
    if (t->saved_stack) {
        for (int i = 0; i < t->saved_stack_len; i++) slot_decref(t->saved_stack[i]);
        free(t->saved_stack); t->saved_stack = NULL; t->saved_stack_len = 0;
    }
    if (t->saved_frames) {
        for (int i = 0; i < t->saved_frame_count; i++) {
            CallFrame *f = &t->saved_frames[i];
            /* A task killed while suspended INSIDE a try never runs the
             * matching TRY_ENDs, and g_try_depth is a process global, not
             * per-task: leaving it elevated makes rt_error's `g_try_depth == 0`
             * gate suppress the diagnostic of every later uncaught error in
             * the process — confirmed, the program exits 1 in silence (#726). */
            g_try_depth -= f->try_count;
            callframe_release(f);
        }
        if (g_try_depth < 0) g_try_depth = 0;
        free(t->saved_frames); t->saved_frames = NULL; t->saved_frame_count = 0;
    }
    if (t->run_env) { env_decref(t->run_env); t->run_env = NULL; }
    t->has_error = 1;
    t->state = TASK_DEAD;
    s->live--;
    /* Wake joiners with an interrupt: on resume task_apply_join_result sees
     * has_error and re-raises. Give them an error payload. */
    if (!t->error_value) {
        Value *ev = make_dict(3);
        dict_set_owned(ev, "kind", make_str(err_kind_name(EK_INTERRUPT)));
        dict_set_owned(ev, "message", make_str("task was killed"));
        dict_set_owned(ev, "line", make_num(0));
        t->error_value = ev;
    }
    for (int i = 1; i < HANDLE_TABLE_SIZE; i++) {
        Task *w = (Task *)handle_lookup(i, HANDLE_TASK);
        if (w && w->state == TASK_SUSPENDED && w->join_target == tid)
            sched_ready_push(s, w->id, SCAUSE_KILL_RELEASE);
    }
    if (s->main_task.state == TASK_SUSPENDED && s->main_task.join_target == tid)
        sched_ready_push(s, 0, SCAUSE_KILL_RELEASE);
    /* #530: kill of a detached task is an explicit discard — reap now. (Kill
     * is a deliberate teardown, never an uncaught error: no #493 counting.) */
    if (t->detached) task_reap(t);
    return 1;
}

/* On resuming a recv-blocked task, fill the placeholder the task_recv builtin
 * left on the stack top with the next mailbox message. */
void task_apply_recv_result(Task *t) {
    /* Only a task that suspended INSIDE task_recv has a placeholder to fill.
     * A task resuming from a plain task_yield/task_join must NOT have its
     * mailbox drained here, even if a message arrived meanwhile. */
    if (!t->recv_blocked) return;
    t->recv_blocked = 0;
    if (g_vm.sp > 0) {
        slot_decref(g_vm.stack[g_vm.sp - 1]);
        Value *msg;
        if (t->mbox_count > 0) {
            msg = t->mbox[t->mbox_head];
            t->mbox_head = (t->mbox_head + 1) % t->mbox_cap;
            t->mbox_count--;
        } else {
            msg = make_null();   /* woken without a message (killed sender race) */
        }
        g_vm.stack[g_vm.sp - 1] = slot_from_heap(msg);
    }
}

/* Start a never-run spawned task: bind its deep-copied args into a fresh env
 * from the entry closure (the base frame borrows it — the Task owns run_env
 * across suspend/resume), then run at base 0 so it is suspendable. Mirrors
 * call_eigs_fn's param binding, but does not run to completion. */
static Value *task_start(Task *t) {
    Value *fn = t->entry_fn;
    if (fn->type == VAL_BUILTIN) {          /* builtins never suspend — run direct */
        Value *a = t->argc == 1 ? t->args[0] : make_null();
        return fn->data.builtin(a);
    }
    Env *call_env = env_new(fn->data.fn.closure);
    /* #989: same re-collect carve-out as every other entry point — a
     * 1-parameter callee binds the WHOLE argument list (`one of [5, 6]` gives
     * `a = [5, 6]`). This loop bound args[0] and silently dropped the rest.
     * Over-arity on 2+-param callees is refused in builtin_task_spawn. */
    if (fn->data.fn.param_count == 1 && t->argc > 1) {
        Value *collected = make_list(t->argc);
        for (int i = 0; i < t->argc; i++)
            list_append(collected, t->args[i]);
        env_set_local_owned(call_env, fn->data.fn.params[0], collected);
    } else {
        for (int i = 0; i < fn->data.fn.param_count && i < t->argc; i++)
            env_set_local(call_env, fn->data.fn.params[i], t->args[i]);
    }
    t->run_env = call_env;                  /* Task owns it; base frame borrows */
    t->started = 1;
    EigsChunk *chunk = (EigsChunk *)fn->data.fn.body;
    /* #997: pass the REAL argc. vm_task_run_entry's default of chunk->param_count
     * marks every slot as caller-supplied, so every OP_DEFAULT_PARAM in the
     * callee's prologue skipped and a defaulted parameter silently arrived as
     * null — `d of 1` gives [1, 3] but `task_spawn of [d, 1]` gave [1, null].
     * A re-collected single slot counts as one supplied argument. */
    int supplied = (fn->data.fn.param_count == 1 && t->argc > 1) ? 1 : t->argc;
    return vm_task_run_entry(chunk, call_env, supplied);
}

/* Record a task that just finished (returned or errored) and wake any joiner
 * blocked on it. `r` is the value vm_run returned (NULL on suspend — not this
 * path). g_has_error distinguishes a normal end from an uncaught error. */
/* #530: release a task's handle slot and free the struct. Only for tasks
 * nobody will join (detached) — a reaped id reads as unknown afterwards
 * (task_alive 0, task_join null) and the slot is immediately reusable. */
static void task_reap(Task *t) {
    int id = t->id;
    task_free(t);
    handle_release(id);
}

/* #530: mark `tid` fire-and-forget. A detached task is reaped the moment it
 * finishes — or immediately here if it already has — so its handle slot
 * returns to the pool instead of holding the table until process exit. An
 * already-dead unobserved error moves to the scheduler-level counter so the
 * #493 exit gate survives the reap. The RUNNING task may detach itself.
 * Returns 1 on success, 0 for main (task 0) or an unknown id. */
int task_do_detach(int tid) {
    TaskScheduler *s = sched_get();
    if (!s || tid == 0) return 0;
    Task *t = sched_lookup(s, tid);
    if (!t) return 0;
    if (t->state == TASK_DONE || t->state == TASK_DEAD) {
        if (t->err_unobserved) s->detached_err_count++;
        task_reap(t);
        return 1;
    }
    t->detached = 1;
    return 1;
}

static void sched_finish(TaskScheduler *s, Task *t, Value *r) {
    /* A task that ended (returned OR died) while its per-thread arena is still
     * active — arena_mark with no matching arena_reset, e.g. the arena-suspend
     * guard raised inside the scope — must not leave the arena active: (1) its
     * error dict / result below outlive the task and cross to the joiner, so
     * they must be heap, not arena (a later arena_reset would dangle them); and
     * (2) the next task must start from a clean arena baseline. The suspend
     * guard guarantees a task never *yields* with the arena active, so the only
     * way it's active here is an ending task that leaked the scope. */
    g_arena.active = 0;
    if (g_has_error) {
        t->has_error = 1;
        t->error_value = vm_task_take_error();  /* the {kind,message,line} dict */
        g_has_error = 0;
        /* #493: a worker that dies of an uncaught error must fail the process
         * if nothing ever joins it. Main (task 0) already propagates its own
         * error via the trampoline's return, so only mark workers here; a
         * later task_join on this task clears the flag. */
        if (t->id != 0) t->err_unobserved = 1;
        if (r) val_decref(r);
        t->result = NULL;
    } else {
        t->result = r ? val_clone_for_send(r) : NULL;   /* share-nothing result */
        if (r) val_decref(r);
    }
    t->state = t->has_error ? TASK_DEAD : TASK_DONE;
    if (t->id != 0) s->live--;
    if (t->run_env) { env_decref(t->run_env); t->run_env = NULL; }
    /* Wake every task blocked on this one: enqueue it; on resume the join
     * builtin's placeholder gets overwritten with our result (or re-raise). */
    for (int i = 1; i < HANDLE_TABLE_SIZE; i++) {
        Task *w = (Task *)handle_lookup(i, HANDLE_TASK);
        if (w && w->state == TASK_SUSPENDED && w->join_target == t->id)
            sched_ready_push(s, w->id, SCAUSE_JOIN_RELEASE);
    }
    if (s->main_task.state == TASK_SUSPENDED && s->main_task.join_target == t->id)
        sched_ready_push(s, 0, SCAUSE_JOIN_RELEASE);
    /* #530: a detached task's outcome is nobody's to consume — reap the slot
     * now so task-per-message workloads aren't bounded by lifetime spawns.
     * An uncaught death still fails the process: the #493 flag moves to the
     * scheduler counter before the slot frees (the trace already printed). */
    if (t->id != 0 && t->detached) {
        if (t->err_unobserved) s->detached_err_count++;
        task_reap(t);
    }
}

/* On resuming a task that was blocked in task_join, replace the placeholder
 * null the builtin left on the stack top with the joinee's result — or, if
 * the joinee died, re-raise its error in the joiner. Called from the dispatch loop's
 * resume path (after the stack is restored). */
void task_apply_join_result(Task *t) {
    TaskScheduler *s = sched_get();
    if (!s || t->join_target == 0) return;
    Task *jt = sched_lookup(s, t->join_target);
    t->join_target = 0;
    if (!jt) return;
    if (jt->has_error) {
        jt->err_unobserved = 0;   /* #493: observed by this join (caught or not) */
        /* Re-raise: restore the error payload so the joiner's CHECK_ERROR
         * catches/propagates it as if the throw happened at the join. */
        if (jt->error_value) {
            g_error_value = jt->error_value;
            val_incref(g_error_value);
            g_error_kind = (int)EK_USER;
        }
        snprintf(g_error_msg, sizeof(g_error_msg), "joined task %d failed", jt->id);
        g_has_error = 1;
        return;
    }
    /* Overwrite TOS placeholder with the joinee's (already deep-copied) result. */
    if (g_vm.sp > 0) {
        slot_decref(g_vm.stack[g_vm.sp - 1]);
        Value *res = jt->result ? jt->result : make_null();
        val_incref(res);
        g_vm.stack[g_vm.sp - 1] = slot_from_heap(res);
    }
}

/* The trampoline. Entered from the outermost vm_execute once main (task 0)
 * has first suspended. Drives tasks round-robin until the ready queue drains,
 * then returns main's result. All-tasks-blocked = deadlock (loud, not a hang).
 * Task 0 finishing kills outstanding tasks (kill-outstanding ruling). */
static Value *scheduler_trampoline(TaskScheduler *s) {
    for (;;) {
        int id = sched_ready_pop(s);
        if (id < 0) {
            /* Nothing runnable now. Sleepers waiting on the virtual clock are
             * not a deadlock — advance time to the earliest wake and retry
             * before deciding anything is stuck. */
            if (sched_wake_sleepers(s)) continue;
            /* Genuinely nothing runnable. If main already finished, we're done.
             * If tasks remain live (blocked on joins that can't resolve), that's
             * a deadlock — raise it loudly rather than hang. */
            if (s->main_task.state == TASK_DONE || s->main_task.state == TASK_DEAD) {
                if (s->main_task.has_error) {
                    g_error_value = s->main_task.error_value;
                    s->main_task.error_value = NULL;
                    g_has_error = 1;
                    return make_null();
                }
                Value *r = s->main_task.result;
                s->main_task.result = NULL;
                return r ? r : make_null();
            }
            /* #509: deadlock is a normal runtime error, not a hang — make it
             * CATCHABLE. main is guaranteed SUSPENDED here (the DONE/DEAD case
             * returned above), blocked at a task_join/recv. Build the structured
             * error at main's blocked line (vm_take_error_value later lazily
             * turns g_error_kind/raw/line into a {kind,message,line} dict, so
             * e.kind == "deadlock"). We drive the print/handling ourselves and
             * do NOT go through rt_error's g_try_depth-gated print: g_try_depth
             * is a global, not part of a task's saved slice, so a suspended
             * worker's still-open try can leave it non-zero here. */
            Task *m = &s->main_task;
            int catchable = 0;
            for (int i = 0; i < m->saved_frame_count; i++)
                if (m->saved_frames[i].try_count > 0) { catchable = 1; break; }
            g_error_kind = (int)EK_DEADLOCK;
            g_error_line = m->saved_current_line;
            snprintf(g_error_raw, sizeof(g_error_raw),
                     "all tasks are blocked — deadlock");
            snprintf(g_error_msg, sizeof(g_error_msg),
                     "Error line %d: all tasks are blocked — deadlock", g_error_line);
            g_has_error = 1;
            eigs_clear_error_value();
            if (catchable) {
                /* Deliver at main's blocked site: clear the block reason so the
                 * resume doesn't fill a normal join/recv result, then re-enqueue
                 * main. The loop resumes it with g_has_error set → CHECK_ERROR
                 * unwinds to the handler (which reads e.kind == "deadlock"). */
                m->join_target = 0;
                m->recv_blocked = 0;
                m->sleeping = 0;
                sched_ready_push(s, 0, SCAUSE_DEADLOCK);
                continue;
            }
            /* No handler in main → terminal: print loudly, exit non-zero. (No
             * stack trace: between tasks g_vm has no live frames.) */
            fprintf(stderr, "%s\n", g_error_msg);
            return make_null();
        }
        Task *t = sched_lookup(s, id);
        if (!t || t->state == TASK_DONE || t->state == TASK_DEAD) continue;
        s->current = id;
        /* #846: one entry per resume, written AFTER the pick (the pick is
         * untouched) and only while armed — off, this is one load + branch. */
        if (g_task_trace_on) sched_trace_record(s, id, s->pop_cause);

        Value *r;
        if (t->state == TASK_SUSPENDED) {
            /* Resume (the join placeholder, if any, is filled inside the
             * resume path via task_apply_join_result). */
            r = vm_task_resume(t);   /* resume: frame already exists */
        } else {
            r = task_start(t);   /* never-run task: bind args + run at base 0 */
        }

        if (t->state == TASK_SUSPENDED) {
            /* It suspended again. task_yield → re-enqueue; task_join → stay
             * blocked (woken by sched_finish); task_recv on an empty mailbox →
             * stay blocked (woken by task_deliver); task_sleep → stay blocked
             * (woken by sched_wake_sleepers when the clock reaches wake_at). */
            if (t->join_target == 0 && !t->recv_blocked && !t->sleeping)
                sched_ready_push(s, id, SCAUSE_YIELD);
        } else {
            sched_finish(s, t, r);
            /* kill-outstanding: main ending tears the rest down deterministically. */
            if (id == 0) break;
        }
    }
    /* main finished with tasks still outstanding → reap them (kill-outstanding). */
    if (s->main_task.has_error) {
        g_error_value = s->main_task.error_value;
        s->main_task.error_value = NULL;
        g_has_error = 1;
        return make_null();
    }
    Value *r = s->main_task.result;
    s->main_task.result = NULL;
    return r ? r : make_null();
}
/* The one seam the VM hands control to (#744): called by vm_execute_common
 * after the OUTERMOST vm_run returns. Verbatim the tail that used to sit in
 * vm.c — moved here so `TaskScheduler` stays private to this file. With no
 * scheduler armed it returns `r` unchanged.
 *
 * main (task 0) either finished (no task ever blocked) or suspended. If it
 * suspended, its slice is saved; drive the trampoline. If it finished but
 * tasks are still live, drive them too (kill-outstanding at main's end). */
Value *task_sched_after_outermost(Value *r) {
    TaskScheduler *s = sched_get();
    if (!s || !s->active) return r;
    if (s->main_task.state == TASK_SUSPENDED) {
        /* main's first suspension happened in the initial vm_run, outside the
         * trampoline — enqueue it now so it resumes round-robin, UNLESS it
         * blocked on a join (sched_finish wakes it), a recv (task_deliver
         * wakes it), or a sleep (sched_wake_sleepers wakes it). Mirrors the
         * trampoline's re-enqueue guard. */
        if (s->main_task.join_target == 0 && !s->main_task.recv_blocked &&
            !s->main_task.sleeping)
            sched_ready_push(s, 0, SCAUSE_YIELD);
        return scheduler_trampoline(s);
    }
    /* main ran to completion without ever suspending. Record its result and,
     * if any spawned task is still runnable, drive them (kill-outstanding). */
    if (s->live > 0 && s->rcount > 0) {
        s->main_task.state = TASK_DONE;
        s->main_task.result = r ? val_clone_for_send(r) : NULL;
        if (r) val_decref(r);
        Value *mr = scheduler_trampoline(s);
        return mr;
    }
    return r;
}
