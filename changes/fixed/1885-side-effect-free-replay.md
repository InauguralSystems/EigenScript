Filesystem replay now follows a side-effect-free rr model: module source and
filesystem mutation outcomes come from the tape, with no live module reads or
mutations. Over-cap `read_text` and `read_bytes` tapes now replay their recorded
`io` errors and cap messages instead of failing return-kind validation (#1885,
#1890).
