- Fixed cooperative tasks whose entry is a callback-running builtin (such as
  `sort_by`) deadlocking when the builtin invokes its user function.
