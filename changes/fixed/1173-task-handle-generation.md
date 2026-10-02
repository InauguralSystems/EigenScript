- Cooperative task IDs now carry their handle-slot generation, so using an ID
after `task_detach` recycles its slot raises a catchable stale-handle error
instead of observing or controlling the replacement task.
