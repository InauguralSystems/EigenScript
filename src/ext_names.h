/*
 * ext_names.h — zero-drift builtin-name registry for the conditionally
 * compiled extensions (gfx/audio, http, db, model).
 *
 * Each list is THE single source for both sides:
 *   - the extension's registrar expands X(name, fn) into
 *     env_set_local_owned(env, #name, make_builtin(fn)) — so a builtin
 *     cannot be registered without appearing here;
 *   - the linter (E003, src/lint.c) expands the same lists into its
 *     binding base — so every extension name is known to name-resolution
 *     even in a binary built without that extension (the language surface,
 *     not this binary's build flags, is what the lint describes).
 *
 * lint.c's old hand-copied BUILTINS list drifted ~120 names behind the
 * runtime and even carried a phantom entry ("error"); this header is the
 * structural fix for the extension half of that problem. The core builtins
 * need no list at all — lint.c calls register_builtins() itself.
 *
 * This header is included from always-compiled TUs (lint.c): keep it to
 * pure macros, no declarations that depend on extension types.
 */

#ifndef EIGENSCRIPT_EXT_NAMES_H
#define EIGENSCRIPT_EXT_NAMES_H

/* ---- ext_gfx.c: SDL graphics + audio (EIGENSCRIPT_EXT_GFX) ---- */
#define EIGS_GFX_BUILTINS(X) \
    X(gfx_open, builtin_gfx_open) \
    X(gfx_close, builtin_gfx_close) \
    X(gfx_clear, builtin_gfx_clear) \
    X(gfx_rect, builtin_gfx_rect) \
    X(gfx_line, builtin_gfx_line) \
    X(gfx_point, builtin_gfx_point) \
    X(gfx_circle, builtin_gfx_circle) \
    X(gfx_rrect, builtin_gfx_rrect) \
    X(gfx_clip, builtin_gfx_clip) \
    X(gfx_present, builtin_gfx_present) \
    X(gfx_poll, builtin_gfx_poll) \
    X(gfx_ticks, builtin_gfx_ticks) \
    X(gfx_delay, builtin_gfx_delay) \
    X(gfx_title, builtin_gfx_title) \
    X(gfx_text, builtin_gfx_text) \
    X(gfx_text_width, builtin_gfx_text_width) \
    X(gfx_text_height, builtin_gfx_text_height) \
    X(gfx_fb, builtin_gfx_fb) \
    X(ppu_render_frame, builtin_ppu_render_frame) \
    X(audio_open, builtin_audio_open) \
    X(audio_close, builtin_audio_close) \
    X(audio_capture_open, builtin_audio_capture_open) \
    X(audio_capture_read, builtin_audio_capture_read) \
    X(audio_capture_close, builtin_audio_capture_close) \
    X(audio_stream_open, builtin_audio_stream_open) \
    X(audio_stream_push, builtin_audio_stream_push) \
    X(audio_stream_queued, builtin_audio_stream_queued) \
    X(audio_stream_clear, builtin_audio_stream_clear) \
    X(audio_stream_close, builtin_audio_stream_close) \
    X(audio_volume, builtin_audio_volume) \
    X(audio_stop, builtin_audio_stop) \
    X(audio_pause, builtin_audio_pause) \
    X(audio_play, builtin_audio_play) \
    X(audio_play_loop, builtin_audio_play_loop) \
    X(audio_music_play, builtin_audio_music_play) \
    X(audio_music_volume, builtin_audio_music_volume) \
    X(audio_music_stop, builtin_audio_music_stop) \
    X(audio_queue_size, builtin_audio_queue_size) \
    X(audio_clear, builtin_audio_clear) \
    X(audio_sine, builtin_audio_sine) \
    X(audio_saw, builtin_audio_saw) \
    X(audio_square, builtin_audio_square) \
    X(audio_sweep, builtin_audio_sweep) \
    X(audio_noise, builtin_audio_noise) \
    X(audio_mix, builtin_audio_mix) \
    X(audio_gain, builtin_audio_gain) \
    X(audio_envelope, builtin_audio_envelope)

/* ---- ext_http.c: request-scope builtins, safe on worker states ---- */
#define EIGS_HTTP_REQUEST_BUILTINS(X) \
    X(http_request_body, builtin_http_request_body) \
    X(http_session_id, builtin_http_session_id) \
    X(http_post, builtin_http_post) \
    X(http_request_headers, builtin_http_request_headers) \
    X(shared_set, builtin_shared_set) \
    X(shared_incr, builtin_shared_incr) \
    X(shared_get, builtin_shared_get) \
    X(shared_has, builtin_shared_has) \
    X(shared_delete, builtin_shared_delete) \
    X(shared_keys, builtin_shared_keys) \
    X(shared_size, builtin_shared_size) \
    X(shared_clear, builtin_shared_clear)

/* ---- ext_http.c: server-scope builtins (EIGENSCRIPT_EXT_HTTP) ---- */
#define EIGS_HTTP_BUILTINS(X) \
    X(http_route, builtin_http_route) \
    X(http_route_authed, builtin_http_route_authed) \
    X(http_static, builtin_http_static) \
    X(http_early_bind, builtin_http_early_bind) \
    X(http_serve, builtin_http_serve) \
    X(http_cors, builtin_http_cors)

/* ---- ext_db.c: SQLite bridge (EIGENSCRIPT_EXT_DB) ---- */
#define EIGS_DB_BUILTINS(X) \
    X(db_connect, builtin_db_connect) \
    X(db_query_value, builtin_db_query_value) \
    X(db_execute, builtin_db_execute) \
    X(db_query_json, builtin_db_query_json)

/* ---- model_train.c: transformer bridge (EIGENSCRIPT_EXT_MODEL) ----
 * Two irregular entries: native_train_step_builtin's fn drops the suffix,
 * and model_load_weights is a registered alias of eigen_model_load. */
#define EIGS_MODEL_BUILTINS(X) \
    X(eigen_model_loaded, builtin_eigen_model_loaded) \
    X(eigen_generate, builtin_eigen_generate) \
    X(eigen_model_info, builtin_eigen_model_info) \
    X(native_train_step_builtin, builtin_native_train_step) \
    X(model_save_weights, builtin_model_save_weights) \
    X(eigen_model_load, builtin_eigen_model_load) \
    X(model_load_weights, builtin_eigen_model_load) \
    X(eigen_model_save_binary, builtin_eigen_model_save_binary) \
    X(eigen_checkpoint_info, builtin_eigen_checkpoint_info)

#endif /* EIGENSCRIPT_EXT_NAMES_H */
