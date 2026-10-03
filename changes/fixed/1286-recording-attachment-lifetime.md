- Recording stream identity follows an attachment's lifetime across state
switches. Detach releases its recording binding; a replacement attachment
receives a distinct identity. Line, scope and emitted observer configuration
caches now belong to each stream and tape session, including native callbacks
that record before a source-line event.
