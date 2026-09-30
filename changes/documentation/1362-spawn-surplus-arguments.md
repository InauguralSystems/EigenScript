- `docs/BUILTINS.md`: the `spawn` row said surplus arguments are ignored. They follow the direct-call rule: a callee
  of two or more parameters raises `call passes 3 arguments but the callee takes 2` at the spawn site, and a
  1-parameter callee receives the whole list (#1362).
