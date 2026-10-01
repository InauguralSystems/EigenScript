/* Canonical class-2 registry: registration and lint metadata expand this. */
#ifndef EIGS_CONCURRENCY_BUILTINS_H
#define EIGS_CONCURRENCY_BUILTINS_H
#define EIGS_CONCURRENCY_BUILTINS(X) \
    X("spawn", builtin_spawn) \
    X("task_spawn", builtin_task_spawn) \
    X("task_alive", builtin_task_alive) \
    X("task_self", builtin_task_self) \
    X("task_detach", builtin_task_detach) \
    X("task_yield", builtin_task_yield) \
    X("must_not_yield", builtin_must_not_yield) \
    X("task_join", builtin_task_join) \
    X("task_send", builtin_task_send) \
    X("task_recv", builtin_task_recv) \
    X("task_try_recv", builtin_task_try_recv) \
    X("task_kill", builtin_task_kill) \
    X("task_sleep", builtin_task_sleep) \
    X("task_now", builtin_task_now) \
    X("task_sched_seed", builtin_task_sched_seed) \
    X("task_sched_trace", builtin_task_sched_trace) \
    X("thread_join", builtin_thread_join) \
    X("channel", builtin_channel) \
    X("send", builtin_send) \
    X("recv", builtin_recv) \
    X("try_recv", builtin_try_recv) \
    X("recv_timeout", builtin_recv_timeout) \
    X("close_channel", builtin_close_channel) \
    X("channel_closed", builtin_channel_closed)
#define EIGS_CONCURRENCY_BUILTIN_COUNT 24
#endif
