"""The Python side of the YTDLP GUI iOS engine.

The app's C bridge (YTDLPGUI-iOS/Engine/Runtime/PythonBridge.c) calls `dispatch` for every
command, each job on a thread of its own. Commands and events are JSON; the protocol is
documented in Docs/iOS-Architecture.md.

This module only uses the standard library: which yt-dlp gets imported is decided by the
`configure` command, so every module that imports yt-dlp is loaded on demand, after that.
"""

import importlib
import json
import traceback

from . import bridge, engine
from .errors import HostError


def dispatch(command, payload_json):
    """Runs one command and returns its result as JSON. Never raises.

    Failures come back as `{"ok": false, "error": …}`, with a `traceback` when the failure is
    a bug rather than something the app or the person can act on.
    """
    try:
        result = _run(command, payload_json)
    except HostError as error:
        result = {'ok': False, 'error': str(error)}
    except BaseException as error:  # Anything at all: raising would hand the app a C-level error.
        result = {
            'ok': False,
            'error': f'The download engine failed unexpectedly: {str(error) or type(error).__name__}',
            'traceback': ''.join(traceback.format_exception(error)),
        }
    try:
        return bridge.dumps(result)
    except Exception as error:
        return json.dumps({'ok': False, 'error': f'The engine produced an unreadable result: {error}'})


def _run(command, payload_json):
    handler = _COMMANDS.get(command) if isinstance(command, str) else None
    if handler is None:
        raise HostError(f'The engine doesn\'t know the command "{command}".')
    try:
        payload = json.loads(payload_json) if payload_json else {}
    except (TypeError, ValueError):
        raise HostError(f'The engine was sent unreadable data for "{command}".') from None
    if not isinstance(payload, dict):
        raise HostError(f'The engine was sent unreadable data for "{command}".')
    return handler(payload)


def _needs_engine(module_name, function_name):
    """A handler that loads its module only once the engine knows which yt-dlp to use."""
    def handler(payload):
        engine.settings()
        module = importlib.import_module(f'{__name__}.{module_name}')
        return getattr(module, function_name)(payload)
    return handler


def _analyze(payload):
    if not engine.is_configured():
        # The analysis result always carries its log and cancellation state.
        return {'ok': False, 'error': str(engine.NotConfiguredError()), 'log': [], 'cancelled': False}
    return _needs_engine('downloads', 'analyze')(payload)


def _cancel(payload):
    job_id = payload.get('job_id')
    if not isinstance(job_id, str) or not job_id:
        raise HostError('The engine was asked to cancel a job without an ID.')
    if not engine.is_configured():
        # No job can have run yet.
        return {'ok': True, 'found': False}
    jobs = importlib.import_module(f'{__name__}.jobs')
    return {'ok': True, 'found': jobs.cancel(job_id)}


def _install_update(payload):
    from . import updates

    return updates.install_update(payload)


_COMMANDS = {
    'configure': engine.configure,
    'version': engine.version,
    'analyze': _analyze,
    'download': _needs_engine('downloads', 'download'),
    'cancel': _cancel,
    'check_update': _needs_engine('updates', 'check_update'),
    'install_update': _install_update,
}
