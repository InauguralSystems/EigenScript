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
