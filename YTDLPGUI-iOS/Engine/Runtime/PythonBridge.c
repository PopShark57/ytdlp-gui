#define PY_SSIZE_T_CLEAN
#include <Python/Python.h>

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "PythonBridge.h"

// MARK: - State

// The callbacks are read by whichever Python thread emits or requests, possibly while another
// thread installs them, so they are atomics rather than plain globals.
static _Atomic(ytg_emit_callback) s_emit_callback = NULL;
static _Atomic(ytg_request_callback) s_request_callback = NULL;
static _Atomic(void *) s_callback_context = NULL;

/// CPython can be initialised once per process. A failed attempt may already have gone far
/// enough to make a second one unsafe, so failure is final too and is reported again, with the
/// same message, to anyone who tries later.
enum {
    YTG_STATE_NEW = 0,
    YTG_STATE_STARTING,
    YTG_STATE_READY,
    YTG_STATE_FAILED,
};
static atomic_int s_state = YTG_STATE_NEW;
/// Written once, before `s_state` becomes `YTG_STATE_FAILED`; read only after seeing that state.
static char *s_failure_message = NULL;

// MARK: - Small helpers

static char *ytg_strdup(const char *text) {
    if (text == NULL) {
        return NULL;
    }
    size_t length = strlen(text);
    char *copy = malloc(length + 1);
    if (copy != NULL) {
        memcpy(copy, text, length + 1);
    }
    return copy;
}

/// Joins `context` and `detail` as "context: detail" in a `malloc`ed string.
static char *describe(const char *context, const char *detail) {
    if (detail == NULL || detail[0] == '\0') {
        return ytg_strdup(context);
    }
    size_t size = strlen(context) + strlen(detail) + 3;
    char *message = malloc(size);
    if (message != NULL) {
        snprintf(message, size, "%s: %s", context, detail);
    }
    return message;
}

/// Appends `text` to `buffer` as the body of a JSON string literal (without the quotes).
/// Returns the new length, or -1 if the buffer would overflow.
static long json_escape_into(char *buffer, long length, long capacity, const char *text) {
    if (text == NULL) {
        return length;
    }
    for (const unsigned char *cursor = (const unsigned char *)text; *cursor != '\0'; cursor++) {
        char escape[8] = {0};
        const char *piece = NULL;
        switch (*cursor) {
            case '"': piece = "\\\""; break;
            case '\\': piece = "\\\\"; break;
            case '\n': piece = "\\n"; break;
            case '\r': piece = "\\r"; break;
            case '\t': piece = "\\t"; break;
            default:
                if (*cursor < 0x20) {
                    snprintf(escape, sizeof escape, "\\u%04x", *cursor);
                    piece = escape;
                }
                break;
        }
        if (piece != NULL) {
            long pieceLength = (long)strlen(piece);
            if (length + pieceLength >= capacity) return -1;
            memcpy(buffer + length, piece, (size_t)pieceLength);
            length += pieceLength;
        } else {
            if (length + 1 >= capacity) return -1;
            buffer[length++] = (char)*cursor;
        }
    }
    return length;
}

/// Builds `{"ok": false, "error": <message>, "traceback": <traceback>}` without needing Python,
/// so it works even when the interpreter is the thing that failed.
static char *error_json(const char *message, const char *traceback) {
    static const char fallback[] = "{\"ok\":false,\"error\":\"The download engine failed and ran out of memory while reporting why.\"}";
    // Every input byte expands to at most six (`\u00XX`); 64 covers the fixed JSON around them.
    long capacity = 64 + (long)(message ? strlen(message) : 0) * 6 + (long)(traceback ? strlen(traceback) : 0) * 6;
    char *buffer = malloc((size_t)capacity);
    if (buffer == NULL) {
        return ytg_strdup(fallback);
    }
    long length = 0;
    const char *prefix = "{\"ok\":false,\"error\":\"";
    memcpy(buffer, prefix, strlen(prefix));
    length += (long)strlen(prefix);
    length = json_escape_into(buffer, length, capacity, message ? message : "Unknown error");
    if (length < 0) { free(buffer); return ytg_strdup(fallback); }

    const char *middle = "\",\"traceback\":\"";
    memcpy(buffer + length, middle, strlen(middle));
    length += (long)strlen(middle);
    length = json_escape_into(buffer, length, capacity, traceback ? traceback : "");
    if (length < 0) { free(buffer); return ytg_strdup(fallback); }

    const char *suffix = "\"}";
    memcpy(buffer + length, suffix, strlen(suffix) + 1);
    return buffer;
}

/// Takes the pending Python exception, clears it, and returns "context: message" in a
/// `malloc`ed string, plus its formatted traceback in `*traceback_out` when asked for.
/// Requires the GIL. Never leaves an exception set.
static char *take_pending_exception(const char *context, char **traceback_out) {
    if (traceback_out != NULL) {
        *traceback_out = NULL;
    }
    PyObject *exception = PyErr_GetRaisedException();  // new reference, or NULL
    if (exception == NULL) {
        return ytg_strdup(context);
    }

    char *message = NULL;
    PyObject *text = PyObject_Str(exception);
    if (text != NULL) {
        message = describe(context, PyUnicode_AsUTF8(text));
        Py_DECREF(text);
    }
    PyErr_Clear();
    if (message == NULL) {
        message = ytg_strdup(context);
    }

    // The traceback is best effort; failing to format it must not hide the original error.
    if (traceback_out != NULL) {
        PyObject *tracebackModule = PyImport_ImportModule("traceback");
        if (tracebackModule != NULL) {
            PyObject *lines = PyObject_CallMethod(tracebackModule, "format_exception", "O", exception);
            if (lines != NULL) {
                PyObject *empty = PyUnicode_FromString("");
                if (empty != NULL) {
                    PyObject *joined = PyUnicode_Join(empty, lines);
                    if (joined != NULL) {
                        *traceback_out = ytg_strdup(PyUnicode_AsUTF8(joined));
                        Py_DECREF(joined);
                    }
                    Py_DECREF(empty);
                }
                Py_DECREF(lines);
            }
            Py_DECREF(tracebackModule);
        }
        PyErr_Clear();
    }

    Py_DECREF(exception);
    return message;
}

/// Describes the pending Python exception as an error JSON object and clears it. Requires the GIL.
static char *pending_exception_json(const char *context) {
    char *traceback = NULL;
    char *message = take_pending_exception(context, &traceback);
    char *result = error_json(message ? message : context, traceback);
    free(message);
    free(traceback);
    return result;
}

// MARK: - The `_ytdlpgui` module (Python → Swift)

/// `_ytdlpgui.emit(job_id: str, event_json: str) -> None`
static PyObject *module_emit(PyObject *self, PyObject *args) {
    (void)self;
    const char *jobID = NULL;
    const char *eventJSON = NULL;
    if (!PyArg_ParseTuple(args, "ss", &jobID, &eventJSON)) {
        return NULL;
    }
    ytg_emit_callback callback = atomic_load(&s_emit_callback);
    if (callback != NULL) {
        void *context = atomic_load(&s_callback_context);
        // The strings point into the UTF-8 caches of immutable str objects that `args` keeps
        // alive, so they stay valid while the GIL is released. Releasing it means a slow
        // consumer never stalls the other downloads.
        Py_BEGIN_ALLOW_THREADS
        callback(jobID, eventJSON, context);
        Py_END_ALLOW_THREADS
    }
    Py_RETURN_NONE;
}

/// `_ytdlpgui.request(job_id: str, request_json: str) -> str`
static PyObject *module_request(PyObject *self, PyObject *args) {
    (void)self;
    const char *jobID = NULL;
    const char *requestJSON = NULL;
    if (!PyArg_ParseTuple(args, "ss", &jobID, &requestJSON)) {
        return NULL;
    }
    ytg_request_callback callback = atomic_load(&s_request_callback);
    if (callback == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "The host app has not registered a request handler");
        return NULL;
    }
    void *context = atomic_load(&s_callback_context);

    // Media work can take minutes; the GIL is released so other jobs keep running meanwhile.
    char *response = NULL;
    Py_BEGIN_ALLOW_THREADS
    response = callback(jobID, requestJSON, context);
    Py_END_ALLOW_THREADS

    if (response == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "The host app did not answer the request");
        return NULL;
    }
    PyObject *result = PyUnicode_DecodeUTF8(response, (Py_ssize_t)strlen(response), "replace");
    free(response);
    return result;
}

/// `_ytdlpgui.interrupt(thread_ident: int, exception_type: type) -> int`
///
/// Raises `exception_type` asynchronously in another Python thread. This is how a download is
/// cancelled while yt-dlp is busy in code that never calls back into the host (extraction,
/// retries); the exception is delivered at the thread's next bytecode boundary. Returns the
/// number of threads affected: 0 when the thread has already finished, which is harmless.
static PyObject *module_interrupt(PyObject *self, PyObject *args) {
    (void)self;
    PyObject *identObject = NULL;
    PyObject *exceptionType = NULL;
    if (!PyArg_ParseTuple(args, "OO", &identObject, &exceptionType)) {
        return NULL;
    }
    // `threading.get_ident()` values are unsigned longs, which is also what
    // `PyThreadState_SetAsyncExc` takes in 3.14. The "k" format would silently wrap a negative
    // or oversized number into some other thread's ident, so convert with overflow checking.
    unsigned long threadIdent = PyLong_AsUnsignedLong(identObject);
    if (threadIdent == (unsigned long)-1 && PyErr_Occurred()) {
        return NULL;
    }
    if (!PyExceptionClass_Check(exceptionType)) {
        PyErr_SetString(PyExc_TypeError, "exception_type must be an exception class");
        return NULL;
    }
    int affected = PyThreadState_SetAsyncExc(threadIdent, exceptionType);
    return PyLong_FromLong(affected);
}

static PyMethodDef module_methods[] = {
    {"emit", module_emit, METH_VARARGS, "Deliver an event to the host app."},
    {"request", module_request, METH_VARARGS, "Ask the host app to perform a task and wait for the JSON answer."},
    {"interrupt", module_interrupt, METH_VARARGS, "Raise an exception asynchronously in another thread."},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef module_definition = {
    PyModuleDef_HEAD_INIT,
    "_ytdlpgui",
    "Bridge from the embedded Python engine to the YTDLP GUI app.",
    -1,
    module_methods,
    NULL, NULL, NULL, NULL,
};

static PyObject *PyInit__ytdlpgui(void) {
    return PyModule_Create(&module_definition);
}

// MARK: - Public API

void ytg_set_callbacks(ytg_emit_callback emit, ytg_request_callback request, void *context) {
    atomic_store(&s_callback_context, context);
    atomic_store(&s_emit_callback, emit);
    atomic_store(&s_request_callback, request);
}

bool ytg_is_initialized(void) {
    return atomic_load(&s_state) == YTG_STATE_READY;
}

/// Records `message` as the permanent initialisation failure and returns a copy for the caller.
static char *fail_initialization(char *message) {
    if (message == NULL) {
        message = ytg_strdup("Python couldn't start and ran out of memory while reporting why");
    }
    s_failure_message = message;
    atomic_store(&s_state, YTG_STATE_FAILED);
    return ytg_strdup(message);
}

static char *status_failure(const char *context, PyStatus status) {
    return fail_initialization(describe(context, status.err_msg ? status.err_msg : "unknown error"));
}

/// Places `module_paths` at the front of `sys.path`. Requires the GIL; returns a `malloc`ed
/// description of the failure, or NULL.
static char *prepend_module_paths(const char *const *module_paths, int32_t module_path_count) {
    PyObject *searchPath = PySys_GetObject("path");  // borrowed
    if (searchPath == NULL || !PyList_Check(searchPath)) {
        PyErr_Clear();
        return ytg_strdup("Python started without a module search path");
    }
    Py_ssize_t position = 0;
    for (int32_t index = 0; module_paths != NULL && index < module_path_count; index++) {
        if (module_paths[index] == NULL) {
            continue;
        }
        PyObject *entry = PyUnicode_FromString(module_paths[index]);
        if (entry == NULL) {
            return take_pending_exception("Couldn't extend the module search path", NULL);
        }
        int inserted = PyList_Insert(searchPath, position, entry);
        Py_DECREF(entry);
        if (inserted != 0) {
            return take_pending_exception("Couldn't extend the module search path", NULL);
        }
        position++;
    }
    return NULL;
}

char *ytg_initialize(const char *python_home,
                     const char *const *module_paths,
                     int32_t module_path_count,
                     const char *bytecode_cache_dir) {
    int expected = YTG_STATE_NEW;
    if (!atomic_compare_exchange_strong(&s_state, &expected, YTG_STATE_STARTING)) {
        switch (expected) {
            case YTG_STATE_READY:
                return NULL;
            case YTG_STATE_FAILED:
                return ytg_strdup(s_failure_message);
            default:
                return ytg_strdup("Python is already being started on another thread");
        }
    }

    PyStatus status;
    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    // UTF-8 everywhere: titles and file names are routinely non-ASCII.
    preconfig.utf8_mode = 1;
    status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        return status_failure("Couldn't pre-initialise Python", status);
    }

    if (PyImport_AppendInittab("_ytdlpgui", PyInit__ytdlpgui) == -1) {
        return fail_initialization(ytg_strdup("Couldn't register the _ytdlpgui module"));
    }

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.buffered_stdio = 0;
    // The app owns the process; Python must not install handlers for SIGINT and friends.
    config.install_signal_handlers = 0;
#ifdef __APPLE__
    // Anything that does reach stdout or stderr ends up in the unified log.
    config.use_system_logger = 1;
#endif
    config.write_bytecode = bytecode_cache_dir != NULL ? 1 : 0;

    status = PyConfig_SetBytesString(&config, &config.home, python_home);
    if (PyStatus_Exception(status)) {
        PyConfig_Clear(&config);
        return status_failure("Couldn't set the Python home", status);
    }
    if (bytecode_cache_dir != NULL) {
        status = PyConfig_SetBytesString(&config, &config.pycache_prefix, bytecode_cache_dir);
        if (PyStatus_Exception(status)) {
            PyConfig_Clear(&config);
            return status_failure("Couldn't set the byte-code cache", status);
        }
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        return status_failure("Couldn't start Python", status);
    }

    // From here on this thread holds the GIL, and every path must hand it back: a thread that
    // exits while holding it would deadlock every later call.
    //
    // Since Python 3.11 the standard library's search path is only computed during
    // initialisation, so the app's own directories are placed in front of it afterwards.
    char *failure = prepend_module_paths(module_paths, module_path_count);

    // The saved thread state belongs to this (short-lived) thread and is never resumed; every
    // later call gets its own state through `PyGILState_Ensure`.
    PyEval_SaveThread();

    if (failure != NULL) {
        return fail_initialization(failure);
    }
    atomic_store(&s_state, YTG_STATE_READY);
    return NULL;
}

char *ytg_call(const char *command, const char *payload_json) {
    if (!ytg_is_initialized()) {
        return error_json("The Python engine has not been started", NULL);
    }

    PyGILState_STATE gil = PyGILState_Ensure();
    char *output = NULL;

    PyObject *host = PyImport_ImportModule("ytdlpgui_host");
    if (host == NULL) {
        output = pending_exception_json("Couldn't load the engine host module");
        PyGILState_Release(gil);
        return output;
    }

    PyObject *result = PyObject_CallMethod(host, "dispatch", "ss", command, payload_json);
    Py_DECREF(host);
    if (result == NULL) {
        output = pending_exception_json("The engine raised an error");
        PyGILState_Release(gil);
        return output;
    }

    if (!PyUnicode_Check(result)) {
        Py_DECREF(result);
        output = error_json("The engine returned something other than a string", NULL);
        PyGILState_Release(gil);
        return output;
    }

    const char *utf8 = PyUnicode_AsUTF8(result);
    output = utf8 != NULL ? ytg_strdup(utf8) : pending_exception_json("The engine returned undecodable text");
    Py_DECREF(result);
    // Releasing the last `PyGILState_Ensure` on this thread destroys its thread state, and with
    // it any asynchronous cancel that arrived just as the job returned.
    PyGILState_Release(gil);
    return output != NULL ? output : error_json("The download engine ran out of memory", NULL);
}

void ytg_free(void *pointer) {
    free(pointer);
}
