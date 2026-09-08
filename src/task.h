/*
 * The VM <-> cooperative-scheduler seam (#744).
 *
 * `TaskScheduler`, the ready queue, the virtual clock and the #846 trace are
 * private to task.c. This header is the only surface between it and the VM,
 * in BOTH directions, so the split cannot quietly re-entangle: anything new
 * that crosses has to be written down here.
 *
 * The task_* builtin interface (task_spawn / task_join / task_send / ...)
 * is NOT here — it is in vm.h alongside the `Task` struct, unchanged, because
 * builtins.c is its caller and always was.
 */

#ifndef EIGENSCRIPT_TASK_H
#define EIGENSCRIPT_TASK_H

#include "eigenscript.h"
#include "vm.h"   /* Task, TaskState */

/* ---- task.c -> called by the VM ---------------------------------------- */

/* Copying-stack slice save/restore around a suspend/resume. The dispatch loop
 * calls these at CASE(CALL) and at the resume entry; memory is proportional to
 * a task's LIVE depth, not to a whole VM per task. */
void  task_save_slice(Task *t);
void  task_restore_slice(Task *t);
/* The running task (main's task 0 when nothing has spawned; NULL with no
 * scheduler at all). */
Task *task_current_running(void);
/* Fill the placeholder a blocked task_join / task_recv left on the stack top,
 * on the resume that unblocks it. No-ops when the task was not blocked there. */
void  task_apply_join_result(Task *t);
void  task_apply_recv_result(Task *t);
/* Drive the scheduler after the OUTERMOST vm_run returned `r`; returns the
 * program's result. Returns `r` unchanged when no scheduler is armed, which
 * is every program that never spawns. */
Value *task_sched_after_outermost(Value *r);

/* ---- vm.c -> called by the scheduler ------------------------------------
 * Three thin wrappers over the dispatch loop. They exist so vm_run_ex (the
 * 3131-line interpreter loop) and vm_take_error_value stay `static` in vm.c:
 * the scheduler needs two ways in and one error accessor, not the loop's
 * address. */
Value *vm_task_run_entry(EigsChunk *chunk, Env *env, int call_argc);
Value *vm_task_resume(Task *t);
Value *vm_task_take_error(void);

#endif /* EIGENSCRIPT_TASK_H */
