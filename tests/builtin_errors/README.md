# Executed error rows (#2550)

Each JSON line is one call, run separately with EIGS_STRICT unset, 0 and 1.
The argument columns are `<slot>_kind`, `<slot>_shape` and `<slot>` (the actual
EigenScript expression). Runtime type and shape observations validate those
labels. `@FILE@` is the runner's isolated fixture path. `setup` runs before
the arguments are evaluated. Header words are in native fixed-width order;
`payload_bytes` and `observer_bytes` describe the exact fixture bytes.

`order` lists checks; `errors` maps each applicable failing check to its `kind`
and diagnostic `message` fragment. The first applicable check determines both
the expected kind and message. `ok` means no error. A three-element
kind/message/written array is indexed by unset/0/1.
The explicit `expected_kind` must agree with that first check and the run.
`written` compares final parameter cell bits and numeric kinds, and the
fixture filesystem, before and after the call. `result` pins a success value.
`populations.json` pins the declared line counts; every slot must cover all
seven kinds. Changing a population requires reviewing that declaration too.

Every `tensor_load` row requires a boolean `tape`: true exactly when all three
states select a file-error check. Cap and nonfinite verdicts replay at the
file-read boundary instead, so their rows declare false, as do successful calls
and invalid path arguments. True rows require one record and byte-identical
replay after removing the input. The runner prints completed `tape pairs`.

Only the exact tested cases are documented. Generated blocks identify them;
they make no statement about inputs outside these finite populations.

Music rows with `device_unavailable` declare an explicit false answer if an
independent ctypes probe cannot load SDL/mixer or open the dummy device. The
probe uses the loader names and device arguments in ext_gfx.c; it does not
ask the builtin to classify itself. Each row still executes in all three
strict states. The no-device and decode-no-device rows force unavailable
audio as controls. Generated descriptions retain both declared conditions.
