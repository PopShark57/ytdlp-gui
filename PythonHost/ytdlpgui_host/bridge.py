"""The host's only way to reach the app: the built-in `_ytdlpgui` module.

`PythonBridge.c` registers `_ytdlpgui` before the interpreter starts. It is imported on first
use rather than when this package loads, so the tests can install a stand-in first, and so a
missing module becomes an error that says what is wrong instead of an `ImportError` from deep
inside a download.
"""

import json
import math

from .errors import HostError


class BridgeUnavailableError(HostError):
    """The `_ytdlpgui` module isn't there: the host is running outside the app."""


def _module():
    try:
        import _ytdlpgui
    except ImportError as error:
        raise BridgeUnavailableError(
            'The engine host can only run inside the YTDLP GUI app: the built-in _ytdlpgui '
            'module it talks to the app through is missing.') from error
    return _ytdlpgui


def dumps(value):
    """Encodes `value` as JSON the Swift side can always decode.

    Two things Python's `json` happily produces would make Swift reject the whole document:
    `NaN`/`Infinity` (yt-dlp uses infinite speeds and sizes now and then), and lone surrogates,
    which appear in file names that weren't valid UTF-8.
    """
    text = json.dumps(_finite(value), ensure_ascii=False, allow_nan=False, default=str)
    try:
        text.encode('utf-8')
    except UnicodeEncodeError:
        text = text.encode('utf-8', 'replace').decode('utf-8')
    return text


def _finite(value):
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if isinstance(value, dict):
        return {str(key): _finite(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_finite(item) for item in value]
    return value


def emit(job_id, event):
    """Delivers one event to the app. Never blocks for long: the app only queues it."""
    _module().emit(job_id, dumps(event))


def request(job_id, payload):
    """Asks the app to do something Python can't, and waits for the answer.

    The calling thread blocks with the GIL released, so other jobs keep running. The answer is
    always a dict with an `ok` key, even when the app replies with something unexpected.
    """
    answer_text = _module().request(job_id, dumps(payload))
    try:
        answer = json.loads(answer_text)
    except ValueError:
        answer = None
    if not isinstance(answer, dict):
        operation = payload.get('op', 'request')
        return {'ok': False, 'error': f'The app gave an unreadable answer to {operation}.'}
    return answer


def interrupt(thread_ident, exception_type):
    """Raises `exception_type` asynchronously in the thread `thread_ident`.

    Returns how many threads were affected: 0 when the thread has already finished.
    """
    return _module().interrupt(thread_ident, exception_type)
