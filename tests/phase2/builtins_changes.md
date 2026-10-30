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
| `tests/phase2/builtins/builtins/max.branch` | `1ca8c1c885cd796015304677d87b4782642d0a79026bd63fd28b67632b25ed9c` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/min.branch` | `eee02d9e7cd24809addb54e3c2df45f401134d5c279a7971a87fea26848781bc` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/sign_extend.branch` | `bfc48781e0e0ab7eb480899c9975ccdbb810c36cbd2b297fd62231b41ee03bdf` | R1.6b-D1 | the subtraction is checked int64 arithmetic under rule (A): `sign_extend of [-9223372036854775553, 8]` raises `value` (#1894) |
| `tests/phase2/builtins/builtins/set_exit_code.branch` | `6e6f540c7b879ca35185d74c3840327c3f14ef37c5eb74c5d60531aef340620b` | R1.6-S2 | new int-requiring round-c builtin; main already rejects fractions and values outside 0..255; matched main and merged output agree |

| `tests/phase2/builtins/builtins/fround.branch` | `0eef9c22f27663cb7b9cffcc4704039adacba202777e3b4eb254c5462d851118` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
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
| `tests/phase2/builtins/builtins/str.branch` | `0c399d98c18da266dc150e39e78e616faadc324cca6e7c6c62ceb270e867913f` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/json_encode.branch` | `2ae19e560a3ea73c416cce1162049d723037f5b529e06806bc605c33fcdc2133` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/json_build.branch` | `c2b8bacb39eb6eef288670e99b3ba01d46c7cab2f94f7c05f47724c1488d9cb1` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/acos.branch` | `5958e4ae7fcc01a39f99fdd66c0a9618a9fad69c6e1d470d948f9129c1f6f4cd` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/add.branch` | `fe0387ddfdd246a088888fd214fed1abb2503f3e06a3b57cc6ea610bc0b578ec` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/asin.branch` | `5958e4ae7fcc01a39f99fdd66c0a9618a9fad69c6e1d470d948f9129c1f6f4cd` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/atan.branch` | `f242d5c6ac68248384bda8aa073f2ff5d23bb74e6fced26ba5ad2ac391d98ee6` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/audio_gain.branch` | `b7839145f6b8b9f413311bb0f984dad297356c9d7407628ba2e93a2f6c317c19` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/audio_mix.branch` | `512a7308c426e7ed94676d4c96400d79920afab58c39da9ea68270d8906de059` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/buf_copy.branch` | `9ea81eba48f5b1b9e1f9799c9d8e8f275a0c805a082190eb7a683003a5e4ebb2` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/buf_deinterleave.branch` | `2c8c419b85c034fbd529fd396fb0854d2982be71c29358c171e162c2b9721808` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/buf_dot.branch` | `f9b37d961e959be8c731c30a43a007defa5fa16d3e5e60260bb3c356dbc51c00` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/buf_fill.branch` | `38e227a7b6ada697071d60d8460bab5de95d9a4cdedcae32ccbc987be5e1752c` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/buf_from_list.branch` | `e4a3b6623dd3f422e5712cdaf9f6b32133970df10636edb40f0e2143cbb889e1` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/buf_from_pcm16le.branch` | `036cc08edd6d3a419692c4b1a85ac42d9a891591f55bc5fb806c4d7c8628dff8` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/buf_get.branch` | `077ba41e4a2f93aeb44f20cb2928a585d7bc05cc158087e54aec2d097592081e` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/buf_mix.branch` | `c78a105cdb9774cbbae3417e4aacb73742cdace27313acc705733b80b109d75b` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/buf_peak.branch` | `b69875ae508284a12270c6791980349f86ff7d6ae32f9dfb29a05abccdc8e970` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/buf_resample_linear.branch` | `e37904ae42856ac5a70eaea9fb9e29dd6fd35c5a17a6b31a846bc1e25c23c22d` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/buf_scale_range.branch` | `c8f7e9898eb8c72ffa1bbed04503e8b4867f112300c617db3829aa67981e1d18` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/buf_set.branch` | `b8c58d0a2f26c3baa094a66d073b236ae89d5e12ae0330a4afe75c85728be0a9` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/buf_to_pcm16le.branch` | `63e6df418a4e5f7f819bef3ee88186fd6548d13c06a9073b803868961e01c4e4` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/copy_into.branch` | `a46c24a542bf109a46c4c71890100268ffcfe361b97d42781df51080c27cd7b4` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/cos.branch` | `cf5baf9404a28aab2b4f931c9273949f0072ba197c2bdc27fa58d3d21b54ef0f` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/divide.branch` | `a23f3e073d81fba8891829bb4b4457f39f3b7fb1017bf46a25ef07487d441352` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/dot.branch` | `02946f430ffc9d87a7939a1a2fc200d8367fbcb42feaf973ca0a784500c78966` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/exp.branch` | `a61898dfe0d5ce58736cacff6a0c5ca15e39b3f3aecd198990cb9fd611786479` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/f64_from_bytes.branch` | `731e864c5cb1cb1d39f14554a42eaa605d14019315acedcfacfc332b0fffb172` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/gather.branch` | `824cd2ba031d256ef19a25fe1eedae6cad151a9f7791cd52aa38c717ce599461` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/get_at.branch` | `447670d74eca66707e4805343956d16e27c37428081713849ca3c1c9d1f6889a` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/join.branch` | `4e2dd8e15a945d27912c461362bb70083cabdaf0b4e31a18eac4fa5c5980d557` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/json_decode.branch` | `c0057af18be5254f0f9d1131b02b0d0cbf3594f3d277a9ed153d80463ebfab12` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/leaky_relu.branch` | `ef90cedf931e7e04a61ae277ac5ac010bf33cfca9e5213ea0082221651f34896` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/log.branch` | `b02e0dada2cf9a63f5086fbf5e8501f85dba7cf73b6eda01029647865e8c2986` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/matmul.branch` | `14616b915a5fcfdb5de37ee29ba8d6c547c90e14f0139940b3e313afadab0865` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/matmul_at.branch` | `70bae5f918939bebaf25f312aade4592af6172b2eb587dea09d6f3076a38c050` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/matmul_bt.branch` | `ba1e66cb245a46a025f5d6ee5bf6dce760552982acef6a4ec2599848c6c73569` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/mean.branch` | `ce229cfb4718fca2a9b298d927c341ea796ed6f961db2c4360b25e802c1b5225` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/norm.branch` | `d044f83f1db49f9968c9db1f30f1beafb2b8d39e4c7f162cadcc1474ddaa84ba` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/num.branch` | `7fb58551b9d82163c6703111cf84f5de26bb191de8a66d7fc5102ef8b8688162` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/numerical_grad.branch` | `4500785a3c9519176df2ab02f77fcad440fbf11f26227b29cb52496fd640e005` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/numerical_grad_cols.branch` | `2743a0bc2cabf3858d33ccd68cfab234c86adedc9665a0dbfc477f96aeb7a849` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/numerical_grad_rows.branch` | `0f8312d184ac73b4eeaeec5dfc903859353e0a783dd350c32c73a2855f0e2a03` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/observe.branch` | `1e0ee913120a78b044cf7b567cda8b1672e18fdb5faaa1af94ebb6db1193813a` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/pow.branch` | `68ab07f20b3ee61e305f67fa87230fd2c8a7730bbd4954642fd45136b37b9081` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/ppu_render_frame.branch` | `79f74efe5a437cbb3097669f3da297fb55c36d5682be19c74ba615679d486a47` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/print.branch` | `d2eaac663b00862a70c3ecd6d5f29aaaf9b793021e433025fb403ac65d6d6f01` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/nearest_in_range_all.branch` | `fa6f30b2af6cebed9c244889683a356120916ba20cd5b364579b21010f50634e` | S10-D2 | Issue #1888 comment 6402855103 expressly assigns next main-to-phase2 sync: nearest OTHER active entity, only first index 1 to 0; source and type witnesses frozen |
| `tests/phase2/builtins/builtins/proc_read_buf.branch` | `DELETED` | S10-D2 | Main #1691 retires the zero-consumer builtin; explicit frozen-case retirement, prior bank hashes recorded below |
| `tests/phase2/builtins/builtins/proc_read_buf.hi.branch` | `DELETED` | S10-D2 | Main #1691 retires the zero-consumer builtin; supersedes this path's R1.7-D6 text amendment, prior bank hashes recorded below |
| `tests/phase2/builtins/builtins/read_bytes_buf.branch` | `0b52c1d8294591447cc198a3e8eb027ff8990555c52bf12fbdf93c912428ca84` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/relu.branch` | `24ae0c94c3ef3adf70443d1c90ab71b51e6212e09a7794c2dfc6d44c1a934601` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/scatter_add.branch` | `6efe02323a3891ed6ea11712c44546913ea92f4d0a064f1c5ec8daaaedc8a92d` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/set_at.branch` | `c90f8b78b48c20fae416587af85cc8277342614fa8935a3019ac814e3ac946c1` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/sgd_update.branch` | `42c640c625a2ea086262edc98062262e808ecfc56a0e700970575d9b4c5c10fd` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/sgd_update_cols.branch` | `74b47ef7f49936afc57f2858c3ead68863dd07091681bb275499ad4698237cce` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/sgd_update_rows.branch` | `9ab519ac1c069e9ba1b13cee49b34569bd3da3a72fdf6efe541e92d6e64a3379` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/sin.branch` | `e85163cfbb1a56ed2e29fc5ae75307f2a914acde489f6053e8e16ad55401d4bd` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/sqrt.branch` | `d02ec73520e2db4aa636bed3abe146241425f4b02141efce7a13e0b38ad22639` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/stream_write.branch` | `33b3dae3eecb631329b1c727730d240df187e9c7b7e5bb4cbe737d0d561803e0` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/tan.branch` | `1390b34eb629f519c834cd599144878efae95d3d6a8e1f80a51694a1d051ebad` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/tensor_load.branch` | `ba6c76c1208e36214edb1aadaddf6bc0507f2163720ad681a11ca9d0d39c1fa3` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/tensor_save.branch` | `be16c42b1944c56fbfad22e242be1472004e60995d31735a08237d9ca4d0b975` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/text_builder_append.branch` | `264d7aac65f70767b435d80e1c3a301a2025121d6fa39503c01b0ef0cc7d6ad5` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/write.branch` | `d646570e76559c96769f89afa8d1160cde5e12bed99a3b36f2fb7d6bb7ca7b7b` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/zeros.branch` | `2530cd624a068d1882816dec67cdb9848c1011f5307c0c27fb514cc108b18160` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |
| `tests/phase2/builtins/builtins/zeros_like.branch` | `8d3e0cdb2aee733291b724abd3f038bd9cdf2a90288d24072b87838c538a130c` | R1.7-D6 | N6 Python repr only; source-bound kinds and per-line bit proof; prior numeric/value rulings retained |

| `tests/phase2/builtins/builtins/read_text.branch` | `fd9b265f1a9a5e33c8f9d225b8c0befc1f78a536c43a28cf3cb0ccfbde996cd9` | S10-D3 | Main e0d49159 closes2076: same raise message naming the escape; only over-cap diagnostic text, original sizes/kinds/result/status unchanged |

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

## R1.7-D2 float text amendments

R1.7-D2 authorizes only the N6 Python `repr` re-render of numeric float payloads.
Seven frozen probes were examined: str, fround, json_encode, json_build,
json_path, min and max. Six are amended; json_path already has the N6 spelling
`2.5` and stays byte-identical. The checker compares each line with the
pre-N6 commit b6f9db3879be5578de787ad6cf0d235b809f0e7c: numeric positions,
bit-identical doubles, exact integer spellings, and every non-float byte.
Source-bound runtime kind witnesses disambiguate old integral float spellings;
old text such as `3` cannot itself establish a kind. For json_path the numeric
payload has the JSON input's lexical kind, before raw-text extraction.

The historical R1.6b-D2 ruling still establishes min/max empty-call errors
(#1895), and R1.6g-D1 still establishes fround's N9 semantics. The accepted
rows above now pin their D2-rendered bytes; the prior byte hashes and probe-source
hashes remain recorded in `r17_float_text.json`. No earlier value or kind ruling
is superseded.

Run `python3 tools/phase2_float_amend.py --baseline-binary BASE --binary TIP`
to check the delivered amendments and their source-bound kind witnesses.
Its one-time `--self-test` calibration rejects changed values, kinds, integers,
non-float text, positions and missing/extra tokens or files.

## R1.7-D5 — table metadata after the D2 re-render

Ruling R1.7-D5 on #1758 scopes A2 to earlier closures and records the final
float text deferred by the design to R1.7. In both rowmeta.tsv and the derived
builtins.tsv, json_build and json_encode change closed_in from R1.2/R1.3 to
R1.7. In builtins.tsv, changes_vs_pre changes from no to yes for json_build,
json_encode and str. These are all five changed table cells; no other cell
changes. The other D2 rows already derive yes; json_path was not amended.

The R1.7 closure check reuses phase2_float_amend.py's source-bound kind
metadata and check_pair on each .pre/.branch pair: same line/token positions,
bit-identical doubles, identical integer spellings and non-float bytes, and
the complete Python repr re-render. It refuses an R1.7 closure without D2
kind provenance. Every other closed row retains A2's .pre == .branch check.
No expectation or probe source changes in this amendment.

builtins_landed.txt now declares R1.7, which make_table.py's shared parser
accepts. run_probes.sh checks a row closed in R1.7 against .branch whenever
R1.7 is declared, independently of the row's original R1.6 migration group.
The public tools/phase2_builtins.sh entry point retains all profile, hook,
stdin, frozen-bar, membership and accounting checks. This follows principle
5, Checks are anchored outside the system, narrow, and few: the D2 comparator
has one implementation, and the two fault plants are one-time calibration.

Continuation 4's plants run through that public entry point in isolated
clones. json_build.pre changes a non-float key (a to z) while leaving the
frozen .branch hash intact; D5 must reject it. abs.pre changes an integer
spelling to a float spelling with its derived flag synchronized to yes;
the pre-R1.6 A2 closure must still reject it. Each plant must produce only
its named closure diagnostic, rather than a neighboring metadata/hash error.
Checkpoint ownership and exact run receipts are in the continuation handoff.

## R1.7-D6 — derived float re-render population

The expanded proof prints each amendment's SHA. Flush the parent checker's
stdout before starting the probe runner, so these records and the child's
`ran=` summary remain complete lines. The final profile receipts require
exactly one complete runner summary; the earlier spliced logs are retained
as calibration evidence, superseded by the final reruns.

The population is the union of the gate's live comparisons over release, server, server-db and zlib. Every frozen row is examined on each profile. D6 adds 62 rows to the six already amended under D2; the cumulative population is 68. The unchanged json_path control is outside the amendment set. Exact per-profile observations, commands and hashes: continue5-population.json in the R1.7 handoff.

The checker retains D2's per-line, bit-identical double comparison, integer spelling and all other bytes. All numeric tokens have source-bound kinds executed on the pre-N6 binary and all four candidate profiles. Numeric-looking strings echoed by num are source-bound string witnesses and remain byte-identical; only num's numeric results are re-rendered. The original frozen programs are unchanged; the R17-D2-KINDS marker and witnesses are appended only to temporary copies, using the registered stdin fixture where present.

Metadata is derived after amendment. Previously closed amended rows close in R1.7 under D5; every other pre-R1.6 closure retains A2 pre == branch. The existing R1.7 closures are unchanged in this continuation. Derived changes_vs_pre cells and all prior amendment records are detailed below.

| Path | SHA-256 | Profiles | Metadata |
|---|---|---|---|
| `tests/phase2/builtins/builtins/acos.branch` | `5958e4ae7fcc01a39f99fdd66c0a9618a9fad69c6e1d470d948f9129c1f6f4cd` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/add.branch` | `fe0387ddfdd246a088888fd214fed1abb2503f3e06a3b57cc6ea610bc0b578ec` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/asin.branch` | `5958e4ae7fcc01a39f99fdd66c0a9618a9fad69c6e1d470d948f9129c1f6f4cd` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/atan.branch` | `f242d5c6ac68248384bda8aa073f2ff5d23bb74e6fced26ba5ad2ac391d98ee6` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/audio_gain.branch` | `b7839145f6b8b9f413311bb0f984dad297356c9d7407628ba2e93a2f6c317c19` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/audio_mix.branch` | `512a7308c426e7ed94676d4c96400d79920afab58c39da9ea68270d8906de059` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/buf_copy.branch` | `9ea81eba48f5b1b9e1f9799c9d8e8f275a0c805a082190eb7a683003a5e4ebb2` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/buf_deinterleave.branch` | `2c8c419b85c034fbd529fd396fb0854d2982be71c29358c171e162c2b9721808` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/buf_dot.branch` | `f9b37d961e959be8c731c30a43a007defa5fa16d3e5e60260bb3c356dbc51c00` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/buf_fill.branch` | `38e227a7b6ada697071d60d8460bab5de95d9a4cdedcae32ccbc987be5e1752c` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/buf_from_list.branch` | `e4a3b6623dd3f422e5712cdaf9f6b32133970df10636edb40f0e2143cbb889e1` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/buf_from_pcm16le.branch` | `036cc08edd6d3a419692c4b1a85ac42d9a891591f55bc5fb806c4d7c8628dff8` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/buf_get.branch` | `077ba41e4a2f93aeb44f20cb2928a585d7bc05cc158087e54aec2d097592081e` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/buf_mix.branch` | `c78a105cdb9774cbbae3417e4aacb73742cdace27313acc705733b80b109d75b` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/buf_peak.branch` | `b69875ae508284a12270c6791980349f86ff7d6ae32f9dfb29a05abccdc8e970` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/buf_resample_linear.branch` | `e37904ae42856ac5a70eaea9fb9e29dd6fd35c5a17a6b31a846bc1e25c23c22d` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/buf_scale_range.branch` | `c8f7e9898eb8c72ffa1bbed04503e8b4867f112300c617db3829aa67981e1d18` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/buf_set.branch` | `b8c58d0a2f26c3baa094a66d073b236ae89d5e12ae0330a4afe75c85728be0a9` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/buf_to_pcm16le.branch` | `63e6df418a4e5f7f819bef3ee88186fd6548d13c06a9073b803868961e01c4e4` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/copy_into.branch` | `a46c24a542bf109a46c4c71890100268ffcfe361b97d42781df51080c27cd7b4` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/cos.branch` | `cf5baf9404a28aab2b4f931c9273949f0072ba197c2bdc27fa58d3d21b54ef0f` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/divide.branch` | `a23f3e073d81fba8891829bb4b4457f39f3b7fb1017bf46a25ef07487d441352` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/dot.branch` | `02946f430ffc9d87a7939a1a2fc200d8367fbcb42feaf973ca0a784500c78966` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/exp.branch` | `a61898dfe0d5ce58736cacff6a0c5ca15e39b3f3aecd198990cb9fd611786479` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/f64_from_bytes.branch` | `731e864c5cb1cb1d39f14554a42eaa605d14019315acedcfacfc332b0fffb172` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/fround.branch` | `0eef9c22f27663cb7b9cffcc4704039adacba202777e3b4eb254c5462d851118` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/gather.branch` | `824cd2ba031d256ef19a25fe1eedae6cad151a9f7791cd52aa38c717ce599461` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/get_at.branch` | `447670d74eca66707e4805343956d16e27c37428081713849ca3c1c9d1f6889a` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/join.branch` | `4e2dd8e15a945d27912c461362bb70083cabdaf0b4e31a18eac4fa5c5980d557` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/json_build.branch` | `c2b8bacb39eb6eef288670e99b3ba01d46c7cab2f94f7c05f47724c1488d9cb1` | release, server, server-db, zlib | closed_in R1.7; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/json_decode.branch` | `c0057af18be5254f0f9d1131b02b0d0cbf3594f3d277a9ed153d80463ebfab12` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/json_encode.branch` | `2ae19e560a3ea73c416cce1162049d723037f5b529e06806bc605c33fcdc2133` | release, server, server-db, zlib | closed_in R1.7; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/leaky_relu.branch` | `ef90cedf931e7e04a61ae277ac5ac010bf33cfca9e5213ea0082221651f34896` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/log.branch` | `b02e0dada2cf9a63f5086fbf5e8501f85dba7cf73b6eda01029647865e8c2986` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/matmul.branch` | `14616b915a5fcfdb5de37ee29ba8d6c547c90e14f0139940b3e313afadab0865` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/matmul_at.branch` | `70bae5f918939bebaf25f312aade4592af6172b2eb587dea09d6f3076a38c050` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/matmul_bt.branch` | `ba1e66cb245a46a025f5d6ee5bf6dce760552982acef6a4ec2599848c6c73569` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/max.branch` | `1ca8c1c885cd796015304677d87b4782642d0a79026bd63fd28b67632b25ed9c` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/mean.branch` | `ce229cfb4718fca2a9b298d927c341ea796ed6f961db2c4360b25e802c1b5225` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/min.branch` | `eee02d9e7cd24809addb54e3c2df45f401134d5c279a7971a87fea26848781bc` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/norm.branch` | `d044f83f1db49f9968c9db1f30f1beafb2b8d39e4c7f162cadcc1474ddaa84ba` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/num.branch` | `7fb58551b9d82163c6703111cf84f5de26bb191de8a66d7fc5102ef8b8688162` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/numerical_grad.branch` | `4500785a3c9519176df2ab02f77fcad440fbf11f26227b29cb52496fd640e005` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/numerical_grad_cols.branch` | `2743a0bc2cabf3858d33ccd68cfab234c86adedc9665a0dbfc477f96aeb7a849` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/numerical_grad_rows.branch` | `0f8312d184ac73b4eeaeec5dfc903859353e0a783dd350c32c73a2855f0e2a03` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/observe.branch` | `1e0ee913120a78b044cf7b567cda8b1672e18fdb5faaa1af94ebb6db1193813a` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/pow.branch` | `68ab07f20b3ee61e305f67fa87230fd2c8a7730bbd4954642fd45136b37b9081` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/ppu_render_frame.branch` | `79f74efe5a437cbb3097669f3da297fb55c36d5682be19c74ba615679d486a47` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/print.branch` | `d2eaac663b00862a70c3ecd6d5f29aaaf9b793021e433025fb403ac65d6d6f01` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/proc_read_buf.hi.branch` | `f786f6b5395f54fa5f9c39c32f18ebc2d0fcda2099395156af684f37783cfe3b` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/read_bytes_buf.branch` | `0b52c1d8294591447cc198a3e8eb027ff8990555c52bf12fbdf93c912428ca84` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/relu.branch` | `24ae0c94c3ef3adf70443d1c90ab71b51e6212e09a7794c2dfc6d44c1a934601` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/scatter_add.branch` | `6efe02323a3891ed6ea11712c44546913ea92f4d0a064f1c5ec8daaaedc8a92d` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/set_at.branch` | `c90f8b78b48c20fae416587af85cc8277342614fa8935a3019ac814e3ac946c1` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/sgd_update.branch` | `42c640c625a2ea086262edc98062262e808ecfc56a0e700970575d9b4c5c10fd` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/sgd_update_cols.branch` | `74b47ef7f49936afc57f2858c3ead68863dd07091681bb275499ad4698237cce` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/sgd_update_rows.branch` | `9ab519ac1c069e9ba1b13cee49b34569bd3da3a72fdf6efe541e92d6e64a3379` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/sin.branch` | `e85163cfbb1a56ed2e29fc5ae75307f2a914acde489f6053e8e16ad55401d4bd` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/sqrt.branch` | `d02ec73520e2db4aa636bed3abe146241425f4b02141efce7a13e0b38ad22639` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/str.branch` | `0c399d98c18da266dc150e39e78e616faadc324cca6e7c6c62ceb270e867913f` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/stream_write.branch` | `33b3dae3eecb631329b1c727730d240df187e9c7b7e5bb4cbe737d0d561803e0` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/tan.branch` | `1390b34eb629f519c834cd599144878efae95d3d6a8e1f80a51694a1d051ebad` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/tensor_load.branch` | `ba6c76c1208e36214edb1aadaddf6bc0507f2163720ad681a11ca9d0d39c1fa3` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/tensor_save.branch` | `be16c42b1944c56fbfad22e242be1472004e60995d31735a08237d9ca4d0b975` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/text_builder_append.branch` | `264d7aac65f70767b435d80e1c3a301a2025121d6fa39503c01b0ef0cc7d6ad5` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/write.branch` | `d646570e76559c96769f89afa8d1160cde5e12bed99a3b36f2fb7d6bb7ca7b7b` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |
| `tests/phase2/builtins/builtins/zeros.branch` | `2530cd624a068d1882816dec67cdb9848c1011f5307c0c27fb514cc108b18160` | release, server, server-db, zlib | closed_in -; changes_vs_pre yes -> yes |
| `tests/phase2/builtins/builtins/zeros_like.branch` | `8d3e0cdb2aee733291b724abd3f038bd9cdf2a90288d24072b87838c538a130c` | release, server, server-db, zlib | closed_in -; changes_vs_pre no -> yes |

Prior accepted-amendment records (preserved provenance):

- | `tests/phase2/builtins/builtins/fround.branch` | `0eef9c22f27663cb7b9cffcc4704039adacba202777e3b4eb254c5462d851118` | R1.7-D2 | N6 Python repr float text only; prior R1.6g-D1 fround numeric semantics |
- | `tests/phase2/builtins/builtins/json_build.branch` | `c2b8bacb39eb6eef288670e99b3ba01d46c7cab2f94f7c05f47724c1488d9cb1` | R1.7-D2 | N6 Python repr float text only |
- | `tests/phase2/builtins/builtins/json_encode.branch` | `2ae19e560a3ea73c416cce1162049d723037f5b529e06806bc605c33fcdc2133` | R1.7-D2 | N6 Python repr float text only |
- | `tests/phase2/builtins/builtins/max.branch` | `1ca8c1c885cd796015304677d87b4782642d0a79026bd63fd28b67632b25ed9c` | R1.7-D2 | N6 Python repr float text only; prior R1.6b-D2 empty-call errors (#1895) |
- | `tests/phase2/builtins/builtins/min.branch` | `eee02d9e7cd24809addb54e3c2df45f401134d5c279a7971a87fea26848781bc` | R1.7-D2 | N6 Python repr float text only; prior R1.6b-D2 empty-call errors (#1895) |
- | `tests/phase2/builtins/builtins/str.branch` | `0c399d98c18da266dc150e39e78e616faadc324cca6e7c6c62ceb270e867913f` | R1.7-D2 | N6 Python repr float text only |

One-time public-entry plants: json_build.pre a -> z must fail the D5 non-float comparator; abs.pre integer -> float spelling (with derived flag synchronized) must fail A2; acos' derived candidate digit 0.0 -> 1.0 must fail D2's double-bit comparator naming acos. The last plant is checked through phase2_builtins.sh's population-proof preflight, rather than a stale frozen hash. This follows principle 5, Checks are anchored outside the system, narrow, and few.

## S10-D2 — explicit frozen retirement of `proc_read_buf` (2026-10-28)

Main #1691 (`5029856a`) removes `proc_read_buf` under #1677's zero-consumer
rule after removal of `proc_spawn`. The orchestrator's direct PR #1776 ruling
S10-D2 authorizes these retirements under R1.7-D2 and supersedes A5/C10's
retired-builtin witnesses. The prior accepted bank is
`ed09f908603a414f77ead78e241fa10aff7f2f38`; each path below is removed,
with its exact last accepted bytes identified by SHA-256.

| Retired path | Prior accepted SHA-256 | Authority |
| --- | --- | --- |
| `tests/phase2/builtins/builtins/_stdin/hi` | `3639efcd08abb273b1619e82e78c29a7df02c1051b1820e99fc395dcaa3326b8` | S10-D2 retirement |
| `tests/phase2/builtins/builtins/proc_read_buf.branch` | `76b9f9203919cf0f5b50c95f7ba849c0f66dc9f9d46910ecc966a1308ec409a9` | S10-D2 retirement |
| `tests/phase2/builtins/builtins/proc_read_buf.eigs` | `e14e9ac3f0a8421380d4f52db2778bd28c7567f8cb17358d386f94f65bd80221` | S10-D2 retirement |
| `tests/phase2/builtins/builtins/proc_read_buf.hi.branch` | `f786f6b5395f54fa5f9c39c32f18ebc2d0fcda2099395156af684f37783cfe3b` | S10-D2 retirement |
| `tests/phase2/builtins/builtins/proc_read_buf.hi.eigs` | `7af30b36bd60d04b0ff0e6bd5d690fa15db493dd25c88cd56813304d0be6cce3` | S10-D2 retirement |
| `tests/phase2/builtins/builtins/proc_read_buf.hi.pre` | `6a4eac6578eaf7ddde381600841f2c7f83ed104a443ead1da21ce8824ccf1c7a` | S10-D2 retirement |
| `tests/phase2/builtins/builtins/proc_read_buf.hi.tag` | `320688535eda1817e2f08d56e868a37f4c3b1e7c41430b87a61b151f55a6f1d4` | S10-D2 retirement |
| `tests/phase2/builtins/builtins/proc_read_buf.pre` | `6f490d81a564a89f7ba09b44f3f218c14edbd4997d5d8855603739e96a0e5e42` | S10-D2 retirement |
| `tests/phase2/builtins/builtins/proc_read_buf.tag` | `6f490d81a564a89f7ba09b44f3f218c14edbd4997d5d8855603739e96a0e5e42` | S10-D2 retirement |

The two `.branch` amendment rows above now read `DELETED | S10-D2`.
The `proc_read_buf.hi.branch` deletion supersedes its R1.7-D6 amendment
(`f786f6b5395f54fa5f9c39c32f18ebc2d0fcda2099395156af684f37783cfe3b`),
whose historical derivation table remains intact. `r17_float_text.json`
removes only that retired path from the active re-render population (68 to
67) and records both retirements with their exact bank anchor and prior
source/branch hashes. The original four-profile derivation digest remains
historical provenance; its scope is explicit. The float amendment checker
accepts only these two missing paths after checking the bank hashes,
absence of both source/branch files, and the matching `DELETED` amendments.
Every other frozen path and byte retains the previous checks.

The table/case metadata removes the `proc_read_buf` row and both cases:
309 builtin rows, 310 cases, round c=76; other round memberships stay fixed.
P23 (stdin-fixture membership) and R6 (missing stdin fixture) are retired
because the removed `proc_read_buf.hi` case was the only stdin-fixture user.
The fixture membership predicate still compares both directions and treats
an absent fixture directory as the empty set. Remaining plant IDs are fixed.

Existing `builtins/read_bytes_buf.eigs` and `.branch` preserve A5/C10's
host-byte-source f64 intent without any frozen-byte edit: the buffer read
pins `[3, 1.0, "float"]`, then `[3, "float"]` observes `d[2]` after an
integral-float cap. This distinguishes a runtime int-kind fault even when
numeric values agree. Its `.branch` SHA-256 remains
`0b52c1d8294591447cc198a3e8eb027ff8990555c52bf12fbdf93c912428ca84`.
No new case or changelog fragment is added for this pure merge. Checker
calibrations and the one-time real typing fault are scheduled in the
sync10 drivers; this amendment note does not claim they ran.

### S10-D2 sibling sweep: recorded #1888 nearest-other decision

[Issue #1888 comment 6402855103](https://github.com/InauguralSystems/EigenScript/issues/1888#issuecomment-6402855103)
expressly rules that each entity receives its nearest OTHER active entity,
that the entity itself is never a candidate, and that the next main-to-phase2
sync takes it. Main's #1888/#2010 implements that decision. BAR.md had already
filed the old self-neighbor behavior under #1888; no numeric ruling required
that incidental self index. S10-D2 step 3 applies the recorded-decision rule.

Only `builtins/nearest_in_range_all.branch` changes: `[1, "int", "float", "float"]`
becomes `[0, "int", "float", "float"]`; `rc=0`, source, scenario and all kind
witnesses remain byte-identical. Bank source SHA-256 is
`abf6d29d7dff1a56f1baed7c89dbf6e68025898c760ff598ce6da21626f5afa5`;
prior branch SHA-256 is
`b10fe4c4d96d69ca28c3216cb3b82b8db1232808558240afcd320eb943bee6d8`;
approved replacement SHA-256 is
`fa6f30b2af6cebed9c244889683a356120916ba20cd5b364579b21010f50634e`.
The exact SHA amendment above is separate from the N6 population. The checker
validates this single path, source hash and exact one-field transformation
against the same immutable R1.8 bank before installing its approved baseline;
it does not treat arbitrary numeric differences as float re-renders.

## S10-D3 — explicit read_text diagnostic amendment (2026-10-29)

Main `e0d491598ee19108802bf25c99c5b59d23039117` closes [#2076](https://github.com/InauguralSystems/EigenScript/issues/2076). Its Done-when requires "the same raise message naming the escape" for all three capped readers, from one shared helper. The orchestrator explicitly authorizes only the over-cap diagnostic line in `builtins/read_text.branch`; the case source, .pre/.tag, sizes, kinds, result rows and rc stay unchanged. This is a builtin self-test diagnostic, with no Phase2 number rule of its own.

Prior bank SHA-256 `460914ed8657b39b51c90f6401e02e920a30b85ff4c97587884650006193e2ae`; approved S10-D3 SHA-256 `fd9b265f1a9a5e33c8f9d225b8c0befc1f78a536c43a28cf3cb0ccfbde996cd9`. The existing exact frozen-amendment mechanism pins the new bytes.
