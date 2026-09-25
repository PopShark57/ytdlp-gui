#ifndef YTDLPGUI_PYTHON_BRIDGE_H
#define YTDLPGUI_PYTHON_BRIDGE_H

// The narrow C surface between Swift and the embedded CPython interpreter.
//
// Swift never touches the Python C API directly: reference counting, the GIL and exception
// state are all handled on this side, and everything that crosses the boundary is a UTF-8
// JSON string. That keeps the Swift code free of `PyObject *` and makes every exchange easy
// to log and to test.
//
// Threading model:
// - `ytg_initialize` may be called from any thread. CPython starts once per process: later calls
//   return NULL after a success and the original message after a failure, without retrying.
//   It releases the GIL before returning, on every path.
// - `ytg_call` may be called from any thread, concurrently. Each call takes the GIL for as
//   long as Python is running; yt-dlp releases it during network and file I/O, so concurrent
//   downloads really do overlap.
// - The callbacks are invoked on whichever Python thread is running, with the GIL released,
//   so a slow callback never stalls other downloads.

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

/// Delivers one event (progress, log line, …) from a running job. Both strings are UTF-8 and
/// only valid for the duration of the call.
typedef void (*ytg_emit_callback)(const char *job_id, const char *event_json, void *_Nullable context);

/// Asks the host app to perform a task Python cannot do itself — merging media with
/// AVFoundation, running JavaScript in JavaScriptCore. The calling Python thread blocks (with
/// the GIL released) until this returns. The result must be a UTF-8 JSON string allocated with
/// `malloc`; the bridge frees it. Returning NULL is reported to Python as an error.
typedef char *_Nullable (*ytg_request_callback)(const char *job_id, const char *request_json, void *_Nullable context);

/// Installs the callbacks used by the `_ytdlpgui` module. Call before `ytg_initialize`; calling
/// again later is safe, and affects the next emit or request.
void ytg_set_callbacks(ytg_emit_callback _Nullable emit,
                       ytg_request_callback _Nullable request,
                       void *_Nullable context);

/// Starts the interpreter.
///
/// - `python_home`: the directory holding `lib/python3.x` (the app bundle's `python` folder).
/// - `module_paths`: directories placed at the front of `sys.path`, in order.
/// - `bytecode_cache_dir`: a writable directory for compiled byte code. The app bundle is
///   read-only once signed, and compiling yt-dlp's ~1,800 extractor modules on every launch
///   would add seconds to each start, so byte code is cached outside the bundle.
///
/// Returns NULL on success, or a `malloc`ed plain-text description of the failure (free with
/// `ytg_free`).
char *_Nullable ytg_initialize(const char *python_home,
                               const char *const _Nullable *_Nullable module_paths,
                               int32_t module_path_count,
                               const char *_Nullable bytecode_cache_dir);

/// Whether `ytg_initialize` has completed successfully.
bool ytg_is_initialized(void);

/// Calls `ytdlpgui_host.dispatch(command, payload_json)` and returns its result.
///
/// The result is always a `malloc`ed UTF-8 JSON object (free with `ytg_free`). If Python
/// raised instead of returning, the object is `{"ok": false, "error": "…", "traceback": "…"}`.
/// Blocks for as long as the command runs, which for a download can be many minutes, so call
/// it from a dedicated thread rather than from Swift's cooperative thread pool.
char *ytg_call(const char *command, const char *payload_json);

/// Frees a string returned by this bridge.
void ytg_free(void *_Nullable pointer);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif /* YTDLPGUI_PYTHON_BRIDGE_H */
