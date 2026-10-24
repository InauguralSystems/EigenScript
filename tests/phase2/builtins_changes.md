# Builtin bar changes

## Author-applied rulings, second import

The first import d2437d6d is unchanged. This second import copies the author-applied rulings byte for byte. The orchestrator ruled:

> R1.6a-D1: read_text gets a row: class other, round c, profile release, no R1.6 change, and no over-cap REPLAY case (open bug #1890). Its pre/tag were recorded before #1841; re-record pre on 1fd4422c because #1668 changed it upstream; changes_vs_pre then reads no.

> R1.6a-D2: net_port compares instead of printing an ephemeral port; net_listen, net_dial and net_accept likewise avoid socket handles. exec_capture prints the TYPE of its answer because pre-R1.6 (time_t)1e300 overflow made it nondeterministic. Re-record the changed probes on matched builds.

| File | Ruling |
|---|---|
| `BAR.md` | R1.6a-D1 and R1.6a-D2 |
| `RULINGS.draft.md` | R1.6a-D1 and R1.6a-D2 |
| `builtins/exec_capture.eigs` | R1.6a-D2 |
| `builtins/exec_capture.pre` | R1.6a-D2 |
| `builtins/exec_capture.tag` | R1.6a-D2 |
| `builtins/net_accept.eigs` | R1.6a-D2 |
| `builtins/net_dial.eigs` | R1.6a-D2 |
| `builtins/net_listen.eigs` | R1.6a-D2 |
| `builtins/net_port.eigs` | R1.6a-D2 |
| `builtins/read_text.branch` | R1.6a-D1 |
| `builtins/read_text.eigs` | R1.6a-D1 |
| `builtins/read_text.pre` | R1.6a-D1 |
| `builtins/read_text.tag` | R1.6a-D1 |
| `builtins.tsv` | R1.6a-D1 and R1.6a-D2 |
| `cases.tsv` | R1.6a-D1 and R1.6a-D2 |
| `determinism.sh` | R1.6a-D2 |
| `make_table.py` | R1.6a-D1 and R1.6a-D2 |
| `plants.sh` | R1.6a-D1 and R1.6a-D2 |
| `rowmeta.tsv` | R1.6a-D1 and R1.6a-D2 |

## R1.6a implementation after the author-applied rulings

No `.branch` expectation is changed. The five D2 deterministic probe bodies
and the author's determinism.sh remain unchanged; exercise metadata is appended
to existing first comment lines, preserving all executable source line numbers.
All 37 author plants remain, with the four implementation controls named G1-G4.
P18 explicitly plants a pending record so that it remains live after recording.
Normal table checking reads the current tree. P28 explicitly archives 4ac31e67
and still fails on its missing read_text population, using the shared inventory
parser from that revision. The default checker does not rewrite the TSV.

| File | Change and authority |
|---|---|
| `tests/phase2/builtins/make_table.py` | Shared inventory parser; check-only TSV membership/class validation, explicit --write, anchored class consistency, declared landed rounds and retained explicit-revision P28; brief 2, RULINGS A1-A5, R1.6a-D1/D2. |
| `tests/phase2/builtins/run_probes.sh` | Same runner for recording and branch checks; --kind and --check, moved shim and automatic B6 capture fixture; brief 2.3, RULINGS A3-A5/B6. |
| `tests/phase2/builtins/plants.sh` | Preserve P1-P28/T1/R1-R8; keep P18 live and add G1-G4 TSV/class calibration; brief 3, principle 5, R1.6a-D1/D2. |
| `tests/phase2/builtins/http_capture.py` | One loopback HTTP request; echo exact X-Number bytes and preserve request on failure; RULINGS B6. |
| `tests/phase2/builtins/builtins/audio_pause.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/zeros.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/random_int.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/list_slice.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/task_kill.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/audio_open.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/eigen_generate.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/audio_capture_open.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/sign_extend.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/gather.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/gfx_rrect.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/audio_music_play.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/set_at.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/bit_or.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/bit_shr.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/exec_capture.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/audio_sweep.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/gfx_rect.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/task_join.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/close_channel.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/net_port.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/net_close.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/state_at.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/chr.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/audio_music_volume.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/proc_read_buf.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/audio_stream_open.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/gfx_clear.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/bit_shl.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/hex.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/gfx_fb.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/net_send.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/http_early_bind.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/write_bytes.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/bit_xor.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/buf_get.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/audio_noise.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/audio_stop.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/gfx_text_width.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/gfx_clip.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/native_train_step_builtin.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/gfx_open.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/http_serve.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/inflate.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/task_send.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/reshape.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/buffer.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/store_collections.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/gfx_read.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/audio_square.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/channel_closed.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/list_truncate.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/audio_sine.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/bit_not.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/seed_random.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/audio_envelope.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/task_detach.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/token_name.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/store_count.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/str_from_bytes.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/dispatch.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/gfx_text.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/net_dial.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/buf_to_pcm16le.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/get_at.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/store_drop.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/sandbox_run.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/audio_stream_push.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/ppu_render_frame.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/thread_join.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/stream_open.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/store_get.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/gfx_point.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/substr.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/store_delete.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/read_bytes_buf.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/gfx_delay.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/store_close.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/build_corpus.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/audio_saw.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/recv.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/usleep.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/copy_into.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/net_listen.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/gfx_line.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/buf_deinterleave.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/buf_copy.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/audio_volume.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/gfx_text_height.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/f64_from_bytes.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/audio_play_loop.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/buf_set.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/net_accept.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/task_sched_seed.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/buf_from_pcm16le.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/random_hex.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/exit.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/fill.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/net_recv.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/char_at.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/task_alive.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/gfx_circle.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/recv_timeout.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/send.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/try_recv.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/bit_and.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/audio_play.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/list_insert_at.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/list_remove_at.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tests/phase2/builtins/builtins/vm_run_bytecode.eigs` | Identify the existing integral-float success stdout line (or exit status) and Q7 exercises; R1.6a brief 2.2, blind-review F3, RULINGS B1-B5/C1-C10. |
| `tools/phase2_builtins.sh` | Dispatch the authoritative table checker/runner; brief 2 and principle 5. |
| `tests/phase2/builtins_landed.txt` | Explicit landed-sub-round declaration; brief §9.4 amendment (c). |
| `tests/phase2/observation_hooks.c` | Move the author shim byte-for-byte to its sole repository target; RULINGS A4 and BAR handoff. |
| `tests/phase2/builtins/builtins/_hooks/observation_hooks.c` | Remove the previous shim location after the byte-identical move; RULINGS A4. |

## Recorded observations after the rulings

RULINGS A3/B6 and BAR handoff authorize replacing the 25 profile placeholders with matched make server, make zlib and make server-db observations of 4ac31e67 and v0.46.0, with PostgreSQL. R1.6a-D2 authorizes re-recording the five revised probes; R1.6a-D1 / #1668 authorizes read_text.pre on 1fd4422c. All .pre records were then observed on the in-scope 1fd4422c builds and determinism.sh re-observed matched 1fd4422c/tag three times. Only read_text differs between the old and current baselines. No .branch changes.

| Recorded file | Authority |
|---|---|
| `builtins/db_execute.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/db_execute.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/db_query_json.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/db_query_json.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/db_query_value.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/db_query_value.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/eigen_eval_loss.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/eigen_eval_loss.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/eigen_generate.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/eigen_generate.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/eigen_model_load.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/eigen_model_load.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/exec_capture.pre` | R1.6a-D2; RULINGS A3/B6 and BAR handoff |
| `builtins/exec_capture.tag` | R1.6a-D2; RULINGS A3/B6 and BAR handoff |
| `builtins/http_early_bind.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/http_early_bind.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/http_post.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/http_post.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/http_route.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/http_route.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/http_route_authed.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/http_route_authed.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/http_serve.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/http_serve.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/http_static.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/http_static.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/inflate.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/inflate.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/model_load_weights.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/model_load_weights.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/native_train_step_builtin.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/native_train_step_builtin.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/net_accept.pre` | R1.6a-D2; RULINGS A3/B6 and BAR handoff |
| `builtins/net_accept.tag` | R1.6a-D2; RULINGS A3/B6 and BAR handoff |
| `builtins/net_close.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/net_close.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/net_dial.pre` | R1.6a-D2; RULINGS A3/B6 and BAR handoff |
| `builtins/net_dial.tag` | R1.6a-D2; RULINGS A3/B6 and BAR handoff |
| `builtins/net_listen.pre` | R1.6a-D2; RULINGS A3/B6 and BAR handoff |
| `builtins/net_listen.tag` | R1.6a-D2; RULINGS A3/B6 and BAR handoff |
| `builtins/net_port.pre` | R1.6a-D2; RULINGS A3/B6 and BAR handoff |
| `builtins/net_port.tag` | R1.6a-D2; RULINGS A3/B6 and BAR handoff |
| `builtins/net_recv.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/net_recv.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/net_send.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/net_send.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/shared_delete.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/shared_delete.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/shared_incr.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/shared_incr.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/shared_size.pre` | RULINGS A3/B6 and BAR handoff |
| `builtins/shared_size.tag` | RULINGS A3/B6 and BAR handoff |
| `builtins/read_text.pre` | R1.6a-D1 / #1668: current baseline 1fd4422c |
| `builtins.tsv` | Derived changes columns refreshed by the sole checker after authorized recordings; R1.6a-D1/D2 and RULINGS A1/A3 |

## Frozen .branch amendments

The shared table checker compares every `.branch` path and byte against the
pinned author-ruled import in `make_table.py`. Only orchestrator rulings may
amend that bar. Add one row per changed path, with its complete repository path,
the new bytes' lowercase SHA-256, ruling id and reason. An authorized deletion
uses `DELETED` in the SHA-256 column. Unchanged or stale amendments fail.
Historical import records above are already included in the pin.

| Path | SHA-256 | Ruling | Reason |
|---|---|---|---|
| `tests/phase2/builtins/builtins/max.branch` | `540ee7840bf80662918b4d4189add017778d08c503488529c6fec539d0e6bb8a` | R1.6b-D2 | an empty `max` raises `value` in both call forms, `max of []` and `max of ([])` (#1895) |
| `tests/phase2/builtins/builtins/min.branch` | `f45bde7acd9b053b3379e15b35c9e06f2ba11243437f5a5926b62aad588d2118` | R1.6b-D2 | an empty `min` raises `value` in both call forms, `min of []` and `min of ([])` (#1895) |
| `tests/phase2/builtins/builtins/sign_extend.branch` | `bfc48781e0e0ab7eb480899c9975ccdbb810c36cbd2b297fd62231b41ee03bdf` | R1.6b-D1 | the subtraction is checked int64 arithmetic under rule (A): `sign_extend of [-9223372036854775553, 8]` raises `value` (#1894) |
| `tests/phase2/builtins/builtins/set_exit_code.branch` | `6e6f540c7b879ca35185d74c3840327c3f14ef37c5eb74c5d60531aef340620b` | R1.6-S2 | new int-requiring round-c builtin; main already rejects fractions and values outside 0..255; matched main and merged output agree |

| `tests/phase2/builtins/builtins/fround.branch` | `12ca1750befb2a38111ec77d9ff236e9dada8e5c7d297aa5cf4f489c2c1f22fa` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i16_checked_add.branch` | `0d1db8055bba756521c06186282a8e52dea9a69497170c24307c4963f642c52d` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i16_checked_mul.branch` | `e3364392ccc01620ab16d1f686af6e6b32c23fff34c307e87953f9e3ed9752c1` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i16_checked_sub.branch` | `83430b1d05a7910f3cb358019d96be745ae4ecff96738583cb1098c11c21fb2c` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i16_saturating_add.branch` | `6b035f5465db3f45f1418185a495ec931982d0f86f711febb0ea8db7374b9dfc` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i16_saturating_mul.branch` | `0febd6e720fa27afe0f310e5a65a1211282721173f8bdc6fdf17eb5b3107a87c` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i16_saturating_sub.branch` | `0a092d049b2e5398489a1de775a0a16224eeb9bd1682bc671f45b43a5e5c8149` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i16_wrapping_add.branch` | `7e22d2083657f9924f9aba86ae4b6117527149530059200231d9b6b77bc950d0` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i16_wrapping_mul.branch` | `6e81c2cc8fa19ffbcfaf4191eb9744edd0d8f1ae4f3472a21ac330ad9bd3e954` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i16_wrapping_sub.branch` | `98a7b4a0d47b7f67eea180af8895a15667753a93fc2149a8c6ab9e80a260dc37` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i32_checked_add.branch` | `0d1db8055bba756521c06186282a8e52dea9a69497170c24307c4963f642c52d` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i32_checked_mul.branch` | `e3364392ccc01620ab16d1f686af6e6b32c23fff34c307e87953f9e3ed9752c1` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i32_checked_sub.branch` | `83430b1d05a7910f3cb358019d96be745ae4ecff96738583cb1098c11c21fb2c` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i32_saturating_add.branch` | `2572384f77eeff69d3cc3a0b59c9f7b22dcb15ae3cf88c51f1496bee4077310f` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i32_saturating_mul.branch` | `0e736cdfa52e267cf5ce42823980e12b6ea2f71aacb5a3895bcd1c693bf6eeda` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i32_saturating_sub.branch` | `0dc9dce3bc6fd11f47a5722c4014fd95cdfd5c5368e8c1f8244107b4b4fa2c69` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i32_wrapping_add.branch` | `a8ffdc1d47645b8b337ce3f61683ca12e1f510a9954ed7a225101df8ef5caefa` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i32_wrapping_mul.branch` | `dae6aca4e1951a14146168a9e770c20880f1bca0a3d4a725fac999f1dcb68b66` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i32_wrapping_sub.branch` | `57dcfce2cc49056cfd5fa8445772c69cbaefc9589d994b32f8f80d9d3675e0d2` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i64_checked_add.branch` | `5e0363e573dae39234b80d31ae6107b60f6ea16385b994c7d96a2fd8b0ec0eb2` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i64_checked_mul.branch` | `4ceeef9b3b74172c9cb80a74d88766e7cc94d013ab6aea9ea4fc4419180a3613` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i64_checked_sub.branch` | `feca116df0e225630c8507d10d1c70a9842581b7c93432257042e0430002fe17` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i64_saturating_add.branch` | `d0af407460555f1215daca9e46b2e33e61daa5c6cecc6ff5eeefa36652fc8b91` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i64_saturating_mul.branch` | `5b9f38b6498e4e70bf98fd9eefb884bacab98ef89787a9c5e7deee369f1c2746` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i64_saturating_sub.branch` | `c18e190adab6ab52d6d15d22ec8f41ea1aab74e619229aef15deaecbb40adff0` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i64_wrapping_add.branch` | `6d67bf2d16362b4d150ea67f3be55879975c0a509a880084092afb7f11f19033` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i64_wrapping_mul.branch` | `480b829133ec0479736254d9f2451b85bd885abf6f754264a003af3d4b8ad120` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i64_wrapping_sub.branch` | `362647afce351af193cd556572bd40dd23ea3bab88525a2516d3da95a8296ee2` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i8_checked_add.branch` | `0d1db8055bba756521c06186282a8e52dea9a69497170c24307c4963f642c52d` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i8_checked_mul.branch` | `e3364392ccc01620ab16d1f686af6e6b32c23fff34c307e87953f9e3ed9752c1` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i8_checked_sub.branch` | `83430b1d05a7910f3cb358019d96be745ae4ecff96738583cb1098c11c21fb2c` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i8_saturating_add.branch` | `bbaaa6e6a0f01240d5886bb5bfe8820f07d807da7a63e4265747a8b9c0f8b062` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i8_saturating_mul.branch` | `3f186a952f7b2f7145ec2b570d2254988d209e2634efc71f57b5b4cb95231094` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i8_saturating_sub.branch` | `0f2a53fa0c690ea451d134b54a9ebd4dfc22fe7b1d1e7629eb4ab0627dc4af96` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i8_wrapping_add.branch` | `f341a27c110eafc22f067bc59894177092207ded479b047add487cec4d4bfcac` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i8_wrapping_mul.branch` | `ef437e51787f6e26733aec215b06c95ffc4d0951e84a8fe116f10462ee8305cf` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/i8_wrapping_sub.branch` | `72c257561dd7188fcb87c412cd5c8eec03f3a1d3c4ea85d45e8d988899d534d8` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u16_checked_add.branch` | `07559104e693662984ec9c4b4800ea919e8a2c9eeb6fababb15ef72d09da999c` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u16_checked_mul.branch` | `afaa117cff8ee24629cdd9c87dffd6784960e00de6f5a7747df592c208a9dc2b` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u16_checked_sub.branch` | `83430b1d05a7910f3cb358019d96be745ae4ecff96738583cb1098c11c21fb2c` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u16_saturating_add.branch` | `44384bee6cdcec41195ca4455b996d350f058293d40ee790b76c10caf068d910` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u16_saturating_mul.branch` | `4e12ed15428cbbabeff4066b5c73916184f9e35bb1e8b2eec1f36a045ae7d02b` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u16_saturating_sub.branch` | `209468fecd6822d2ccb329bf95a21b842fad859b481fc9864ef5a7bdd62e995e` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u16_wrapping_add.branch` | `dc311d0bac5980796200806862c231f38cba5bbae9ed68addba3fdf6631ee469` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u16_wrapping_mul.branch` | `63fdaa6bd49c73bf07639bef4d630b6d63bddab490edb46cc40dbaaa151a8b73` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u16_wrapping_sub.branch` | `0d697502cd63149fc6ec33913dc1cd8b91e17d68f787c865d8c7af8308c759e6` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u32_checked_add.branch` | `07559104e693662984ec9c4b4800ea919e8a2c9eeb6fababb15ef72d09da999c` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u32_checked_mul.branch` | `afaa117cff8ee24629cdd9c87dffd6784960e00de6f5a7747df592c208a9dc2b` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u32_checked_sub.branch` | `83430b1d05a7910f3cb358019d96be745ae4ecff96738583cb1098c11c21fb2c` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u32_saturating_add.branch` | `18ea283a52dd090a3ab9f4d6513ef37fa7527aa10707264b1c1370d262cb5734` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u32_saturating_mul.branch` | `3ac8fbaca67cc8e3202e33861096657a43f4dd6a29979dd399a41a6ef7ae24a9` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u32_saturating_sub.branch` | `209468fecd6822d2ccb329bf95a21b842fad859b481fc9864ef5a7bdd62e995e` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u32_wrapping_add.branch` | `dc311d0bac5980796200806862c231f38cba5bbae9ed68addba3fdf6631ee469` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u32_wrapping_mul.branch` | `393238e5aa7084fa222aab2477c5841b506133d1f40ff57367a0f3dc5682a146` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u32_wrapping_sub.branch` | `82b539b692c6198addeca7f9e90e6b0cca35d6264bb9d3d7e109e2774d59c56d` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u64_checked_add.branch` | `862b3c5f81afcf7ede2398f0e549fb0d1bb96fdb230028775f038739be862421` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u64_checked_mul.branch` | `fdfbeb2e9c9b5c511b9d07124610df9d11d96c43ed995dd3b8940aed988e4689` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u64_checked_sub.branch` | `feca116df0e225630c8507d10d1c70a9842581b7c93432257042e0430002fe17` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u64_compare.branch` | `957356d1ec2e6a7ac931dd78f8d96ef5528e129ce3006a657b8c5f6d44954fad` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u64_div.branch` | `0b8e9ea05c3e1fe1f40fe04797207534bb0b76c2eddac3ec3a5a96a189949bcc` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u64_rem.branch` | `c251912fc484ad1da3363a23750edea74cefd9430c565829ba016bd37a607419` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u64_saturating_add.branch` | `b5544aa426e8f99bebc1aacd8173bd4e790929cf45856fe1fd2010e13d73c787` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u64_saturating_mul.branch` | `f60d80adccc7e5e3570cc3d47639755e01fd7dd471dc9983bc6aa420f730c76e` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u64_saturating_sub.branch` | `385d6f2e1651a6c2b71e514df0455f028060ef10274b695fec8c2f34929b9f60` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u64_to_string.branch` | `1a73fea2beeb610e651dbe0bc0d089e6c45eb60b9bd09c97980caa70a7e4987d` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u64_wrapping_add.branch` | `d10cd314a93b160387b82573c1c918f7f6a470a7210430aa80b65926fecdf6cf` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u64_wrapping_mul.branch` | `67d21a30b5e6a5c96790cf60855c3ad1bb85ed7489f27fd403053e7c97d5cb93` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u64_wrapping_sub.branch` | `8c65ea11ad10c34268117f56b3d72a5cf1bc044186cbd4d058f00c70aeae3910` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u8_checked_add.branch` | `07559104e693662984ec9c4b4800ea919e8a2c9eeb6fababb15ef72d09da999c` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u8_checked_mul.branch` | `afaa117cff8ee24629cdd9c87dffd6784960e00de6f5a7747df592c208a9dc2b` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u8_checked_sub.branch` | `83430b1d05a7910f3cb358019d96be745ae4ecff96738583cb1098c11c21fb2c` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u8_saturating_add.branch` | `99267c28b402c43f6f0b0235cd323f0993e245882bd35ecc288169807c48e000` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u8_saturating_mul.branch` | `b3e07c6535b21886115efc30fc1ffa04f40870af7edec7d1f210e9248ed023bf` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u8_saturating_sub.branch` | `209468fecd6822d2ccb329bf95a21b842fad859b481fc9864ef5a7bdd62e995e` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u8_wrapping_add.branch` | `dc311d0bac5980796200806862c231f38cba5bbae9ed68addba3fdf6631ee469` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u8_wrapping_mul.branch` | `60da423dcf7c733566c6dc8786eacdfca47f445b4c545a692a33b2c2fdbbfb7d` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |
| `tests/phase2/builtins/builtins/u8_wrapping_sub.branch` | `f6caf9ca2c493a27eced40c47c9a000e8d0ac95b70fd12de204823880b55e686` | R1.6g-D1 | new N9 builtin; Rust std plus the brief operand/shape rules |

## R1.6b bar amendments

The orchestrator ruled on R1.6b's two stops (issues #1894 and #1895):

> R1.6b-D1: sign_extend's subtraction is checked int64 arithmetic, under #1758's rule (A), "overflow raises, no wraparound". So sign_extend of [-9223372036854775553, 8] raises value, naming sign_extend.

> R1.6b-D2: an empty min/max raises value, in both call forms (min of [] with zero arguments, and min of ([]) with one empty list), and likewise for max.

Each new case is appended after its probe's last line, so every existing
executable line number and stdout line number is unchanged (sign_extend's
integral-float success stays stdout line 5). The three probes' `.pre` and
`.tag` were re-recorded on the R1.5-tip and v0.46.0 release binaries; their
earlier lines are byte-identical to the previous records, and only the new
lines were added.

| File | Ruling |
|---|---|
| `tests/phase2/builtins/BAR.md` | R1.6b-D1 and R1.6b-D2 |
| `tests/phase2/builtins/builtins/max.eigs` | R1.6b-D2 |
| `tests/phase2/builtins/builtins/max.pre` | R1.6b-D2 |
| `tests/phase2/builtins/builtins/max.tag` | R1.6b-D2 |
| `tests/phase2/builtins/builtins/min.eigs` | R1.6b-D2 |
| `tests/phase2/builtins/builtins/min.pre` | R1.6b-D2 |
| `tests/phase2/builtins/builtins/min.tag` | R1.6b-D2 |
| `tests/phase2/builtins/builtins/sign_extend.eigs` | R1.6b-D1 |
| `tests/phase2/builtins/builtins/sign_extend.pre` | R1.6b-D1 |
| `tests/phase2/builtins/builtins/sign_extend.tag` | R1.6b-D1 |
| `tests/phase2/builtins_changes.md` | R1.6b-D1 and R1.6b-D2 |


## R1.6b-D3 — http_post historical LOSS and staging

The orchestrator ruled on #1758, comment 6320170738: `http_post` is a LOSS
row and lands in R1.6b. Its pre-R1.6 header path rounds 9007199254740993 to
9007199254740992 (B6); §6's `-` loss mark was an error. The shared N14 JSON
decoder fixes that loss. The class remains `other`; `round_of` assigns every
LOSS row to b. Planned counts become b 46 and f 19.

The probe, `.pre`, `.tag` and `.branch` are unchanged. The frozen `.branch`
pin and its three D1/D2 SHA-256 amendments above are unchanged.

| File | Ruling and change |
|---|---|
| `docs/design/phase2-numbers.md` | R1.6b-D3: correct §6 loss/note and b/f counts |
| `docs/design/phase2-inventory.txt` | R1.6b-D3: mirror the corrected http_post LOSS classification |
| `tests/phase2/builtins/make_table.py` | R1.6b-D3: planned b/f counts 46/19 |
| `tests/phase2/builtins/builtins.tsv` | R1.6b-D3: generator assigns http_post to b |
| `tests/phase2/builtins_changes.md` | R1.6b-D3: record ruling and complete amendment scope |

## Main sync #5 — R1.6-S1 and R1.6-S2

R1.6-S1 (re-scoped): take main's rm deletion and remove_file bridge. rm
had no frozen table row, so no row is removed. The N5.store-key-fraction-raises
MAP cleanup now calls remove_file; MAP source files have no SHA pin, and its
assertion/output remain unchanged.

R1.6-S2: set_exit_code is int-requiring, round c, release profile, closed_in
R1.6-S2 because main already has its final fractional/range refusal. Its .pre
is the merged output; .branch is independently recorded on exact main; they
match. Its .tag is recorded on matched v0.46.0, which lacks the builtin.
The new frozen amendment above authorizes only the added .branch. The pin
remains unchanged; current totals are 233 rows, c=77, and 235 cases.

The probe header identifies fractional and integral-float-success exercises
and rc=3. The checker now accepts that process-status witness for exit and
set_exit_code only, keeping the precise called symbol and recorded rc check.

Files: docs/design/phase2-numbers.md; tests/phase2/builtins/{BAR.md,make_table.py,
rowmeta.tsv,cases.tsv,builtins.tsv,builtins/set_exit_code.eigs,
builtins/set_exit_code.pre,builtins/set_exit_code.branch,builtins/set_exit_code.tag};
tests/phase2/rows/N5.store-key-fraction-raises.eigs; this amendment record.

## R1.6e-D1 — audio channels (pre-registration)

Ruling #1922 comment 6355101247: audio_open, audio_capture_open and
audio_stream_open require N5 channels in 1..255 before SDL/device/tape
side effects. Zero is excluded because SDL substitutes its default. Frequency
remains C int. Counts within the channel domain pass to SDL without a duplicated
support table. MAP N5.audio-channel-domain pre-registers 0, 256, 257, -1, 1.5
refusal and 255/1 reader success before migration. No frozen expectation changes.
The three design notes are corrected with their behavior migration commit.


## R1.6e — legacy audio suite expectation

The ordinary `tests/test_audio.eigs` assertion for `audio_play_loop` with
`1e20` loops now catches `value`: N5 and the existing §6 C-int range require
refusal before the mixer, in both strict modes. The former zero stand-in
assertion predates the numeric readers. The in-range legacy 10000-loop
ceiling stays unchanged. No frozen probe or expectation is amended.

## R1.6f-D1 — shared store handle reader (pre-registration)

#1924 comment 6367017285 assigns get_store_why → store_arg to f for all nine callers: store_close, store_collections, store_count, store_drop, store_get, store_put, store_delete, store_query, store_update. Every caller refuses non-exact, non-finite or out-of-range numeric id/generation fields with value before store access. MAP N5.store-handle-fraction-raises pre-registers both fractional fields in every caller before migration. No frozen .branch changes; already-b rows retain their expectations.

## R1.6g-D1 — N9 pre-registration

The R1.6g brief authorizes 77 new Rust-derived branch expectations and five MAP rows before builtins_int.c exists. No existing .branch changes. Table membership follows when the builtins exist. Oracle inputs, sources and verbatim results are in oracle/n9*.
