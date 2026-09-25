"""Test support: a stand-in for the app's `_ytdlpgui` module, media fixtures and a web server.

The stand-in behaves like the app, using the Mac's own tools: `media.*` requests are carried
out with ffmpeg and ffprobe (answering `unsupported` for files AVFoundation couldn't open),
`js.run` runs node, and `interrupt` calls `PyThreadState_SetAsyncExc` as the C bridge does.
It must be in `sys.modules` before the host is used; `tests/__init__.py` installs it.
"""

import base64
import contextlib
import ctypes
import functools
import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import uuid

FFMPEG = shutil.which('ffmpeg')
FFPROBE = shutil.which('ffprobe')
NODE = shutil.which('node')

requires_ffmpeg = unittest.skipUnless(FFMPEG and FFPROBE, 'ffmpeg and ffprobe are needed for media fixtures')
requires_node = unittest.skipUnless(NODE, 'node is needed to run JavaScript')

#: A 1×1 lossless WebP image; the Mac's ffmpeg can read WebP but not write it.
_WEBP_PIXEL = base64.b64decode('UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==')

# Four-character codes AVFoundation reports, by ffprobe's codec name.
_FOURCC = {
    'h264': 'avc1', 'hevc': 'hvc1', 'av1': 'av01', 'vp9': 'vp09', 'vp8': 'vp08',
    'aac': 'mp4a', 'alac': 'alac', 'flac': 'fLaC', 'mp3': '.mp3', 'opus': 'opus',
    'vorbis': 'vorb', 'pcm_s16le': 'lpcm', 'mjpeg': 'jpeg', 'png': 'png ',
}
# Containers AVFoundation can open, by ffprobe's format name.
_READABLE_FORMATS = ('mov', 'mp4', 'm4a', 'wav', 'flac', 'mp3', 'aac')


# MARK: - Spawning guard

_spawn_state = threading.local()


@contextlib.contextmanager
def fake_app_work():
    """Marks the current thread as doing the stand-in app's work, which may run programs."""
    previous = getattr(_spawn_state, 'allowed', False)
    _spawn_state.allowed = True
    try:
        yield
    finally:
        _spawn_state.allowed = previous


def spawning_allowed():
    return getattr(_spawn_state, 'allowed', False)


# MARK: - The stand-in for _ytdlpgui

class FakeApp:
    """Records what the host sends and answers its requests."""

    def __init__(self):
        self._lock = threading.Lock()
        self._events = {}
        self._requests = []
        self._listeners = []
        self.overrides = {}

    # The module interface -------------------------------------------------------------

    def emit(self, job_id, event_json):
        assert isinstance(job_id, str) and isinstance(event_json, str)
        event = json.loads(event_json)
        with self._lock:
            self._events.setdefault(job_id, []).append(event)
            listeners = list(self._listeners)
        for listener in listeners:
            listener(job_id, event)

    def request(self, job_id, request_json):
        request = json.loads(request_json)
        with self._lock:
            self._requests.append((job_id, request))
        operation = request.get('op')
        handler = self.overrides.get(operation) or _HANDLERS.get(operation)
        if handler is None:
            answer = {'ok': False, 'error': f'Unknown request {operation}'}
        else:
            try:
                with fake_app_work():
                    answer = handler(request)
            except Exception as error:
                answer = {'ok': False, 'error': f'{type(error).__name__}: {error}'}
        return json.dumps(answer)

    @staticmethod
    def interrupt(thread_ident, exception_type):
        return ctypes.pythonapi.PyThreadState_SetAsyncExc(
            ctypes.c_ulong(thread_ident), ctypes.py_object(exception_type))

    # For the tests --------------------------------------------------------------------

    def events(self, job_id, event_type=None):
        with self._lock:
            events = list(self._events.get(job_id, ()))
        return [event for event in events if event_type is None or event['type'] == event_type]

    def log(self, job_id):
        return [event['message'] for event in self.events(job_id, 'log')]

    def requests(self, job_id=None, operation=None):
        with self._lock:
            requests = list(self._requests)
        return [request for job, request in requests
                if (job_id is None or job == job_id) and (operation is None or request.get('op') == operation)]

    @contextlib.contextmanager
    def listening(self, listener):
        with self._lock:
            self._listeners.append(listener)
        try:
            yield
        finally:
            with self._lock:
                self._listeners.remove(listener)

    @contextlib.contextmanager
    def answering(self, operation, handler):
        """Answers `operation` with `handler(request)` for the duration of the block."""
        self.overrides[operation] = handler
        try:
            yield
        finally:
            self.overrides.pop(operation, None)


def install_fake_app():
    """Installs the stand-in as `_ytdlpgui` (once) and returns it."""
    module = sys.modules.get('_ytdlpgui')
    if module is not None and isinstance(getattr(module, 'app', None), FakeApp):
        return module.app
    app = FakeApp()
    module = types.ModuleType('_ytdlpgui')
    module.app = app
    module.emit = app.emit
    module.request = app.request
    module.interrupt = app.interrupt
    sys.modules['_ytdlpgui'] = module
    return app


# MARK: - Requests, carried out with the Mac's tools

def _run(arguments, **kwargs):
    result = subprocess.run(arguments, capture_output=True, text=True, **kwargs)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(detail.splitlines()[-1] if detail else f'exit status {result.returncode}')
    return result.stdout


def _ffprobe(path):
    return json.loads(_run([FFPROBE, '-v', 'error', '-show_format', '-show_streams', '-of', 'json', path]))


def _unsupported(path):
    return {'ok': False, 'unsupported': True, 'error': f'"{os.path.basename(path)}" can\'t be opened by AVFoundation'}


def _readable(path):
    try:
        format_name = _ffprobe(path)['format']['format_name']
    except (RuntimeError, KeyError, ValueError):
        return False
    return any(name in format_name.split(',') for name in _READABLE_FORMATS)


def _probe(request):
    path = request['path']
    try:
        data = _ffprobe(path)
    except RuntimeError:
        return {'ok': True, 'duration': None, 'tracks': [], 'readable': False}
    kinds = {'video': 'video', 'audio': 'audio', 'subtitle': 'text'}
    tracks = [{'kind': kinds.get(stream.get('codec_type'), 'other'),
               'codec': _FOURCC.get(stream.get('codec_name'), stream.get('codec_name'))}
              for stream in data.get('streams', ())]
    duration = data.get('format', {}).get('duration')
    return {'ok': True, 'duration': float(duration) if duration else None, 'tracks': tracks,
            'readable': _readable(path)}


def _merge(request):
    inputs, output = request['inputs'], request['output']
    if not all(_readable(path) for path in inputs):
        return _unsupported(next(path for path in inputs if not _readable(path)))
    muxer = {'mp4': 'mp4', 'mov': 'mov', 'm4a': 'ipod'}[request['container']]
    arguments = [FFMPEG, '-v', 'error', '-y']
    for path in inputs:
        arguments += ['-i', path]
    arguments += ['-map', '0:v?']
    for index in range(1, len(inputs)):
        arguments += ['-map', f'{index}:a?']
    _run([*arguments, '-c', 'copy', '-f', muxer, output])
    return {'ok': True}


def _extract_audio(request):
    source, output, codec = request['input'], request['output'], request['codec']
    if not _readable(source):
        return _unsupported(source)
    options = {
        'copy': ['-c:a', 'copy', '-f', 'ipod'],
        'aac': ['-c:a', 'aac', *(['-b:a', str(request['bitrate'])] if request.get('bitrate') else []), '-f', 'ipod'],
        'alac': ['-c:a', 'alac', '-f', 'ipod'],
        'flac': ['-c:a', 'flac', '-f', 'flac'],
        'wav': ['-c:a', 'pcm_s16le', '-f', 'wav'],
    }[codec]
    _run([FFMPEG, '-v', 'error', '-y', '-i', source, '-vn', *options, output])
    return {'ok': True, 'output': output}


def _embed(request):
    path = request['path']
    if not _readable(path) or os.path.splitext(path)[1] not in ('.mp4', '.m4a', '.m4v', '.mov'):
        return _unsupported(path)
    temporary = f'{path}.embed{os.path.splitext(path)[1]}'
    arguments = [FFMPEG, '-v', 'error', '-y', '-i', path]
    maps = ['-map', '0']
    if request.get('artwork'):
        arguments += ['-i', request['artwork']]
        maps += ['-map', '1', '-disposition:v:1', 'attached_pic']
    chapters_file = None
    if request.get('chapters'):
        chapters_file = f'{path}.chapters.txt'
        with open(chapters_file, 'w', encoding='utf-8') as file:
            file.write(';FFMETADATA1\n')
            for chapter in request['chapters']:
                file.write(f"[CHAPTER]\nTIMEBASE=1/1000\nSTART={int(chapter['start'] * 1000)}\n"
                           f"END={int(chapter['end'] * 1000)}\ntitle={chapter['title']}\n")
        arguments += ['-i', chapters_file]
        maps += ['-map_chapters', str(2 if request.get('artwork') else 1)]
    for key, value in (request.get('metadata') or {}).items():
        maps += ['-metadata', f'{key}={value}']
    try:
        _run([*arguments, *maps, '-c', 'copy', '-f', 'mp4' if not path.endswith('.m4a') else 'ipod', temporary])
        os.replace(temporary, path)
    finally:
        for leftover in (temporary, chapters_file):
            if leftover and os.path.exists(leftover):
                os.remove(leftover)
    return {'ok': True}


def _convert_image(request):
    codec = {'jpg': 'mjpeg', 'png': 'png'}[request['format']]
    _run([FFMPEG, '-v', 'error', '-y', '-i', request['input'], '-frames:v', '1', '-c:v', codec,
          '-f', 'image2', request['output']])
    return {'ok': True}


def _remove_ranges(request):
    # A stand-in: keeps the content and lets the tests check the ranges that were asked for.
    shutil.copyfile(request['input'], request['output'])
    return {'ok': True}


def _run_javascript(request):
    if not NODE:
        return {'ok': False, 'error': 'node is not installed'}
    result = subprocess.run([NODE, '-'], input=request['script'], capture_output=True, text=True,
                            timeout=request.get('timeout') or 60)
    if result.returncode:
        return {'ok': False, 'error': result.stderr.strip() or f'node exited with {result.returncode}'}
    return {'ok': True, 'stdout': result.stdout.rstrip('\n')}


_HANDLERS = {
    'media.probe': _probe,
    'media.merge': _merge,
    'media.extract_audio': _extract_audio,
    'media.embed': _embed,
    'media.convert_image': _convert_image,
    'media.remove_ranges': _remove_ranges,
    'js.run': _run_javascript,
}


# MARK: - The engine

_scratch = None
_scratch_lock = threading.Lock()


def scratch_dir():
    """A folder for the whole test run, removed when the interpreter exits."""
    global _scratch
    with _scratch_lock:
        if _scratch is None:
            _scratch = tempfile.TemporaryDirectory(prefix='ytdlpgui-host-tests-')
        return _scratch.name


def configure_engine():
    """Configures the host once for the test run and returns its answer."""
    import ytdlpgui_host

    payload = {
        'cache_dir': os.path.join(scratch_dir(), 'cache'),
        'update_dir': None,
        'platform_version': '18.0',
    }
    return json.loads(ytdlpgui_host.dispatch('configure', json.dumps(payload)))


def call(command, payload):
    import ytdlpgui_host

    return json.loads(ytdlpgui_host.dispatch(command, json.dumps(payload)))


def new_job_id():
    return str(uuid.uuid4()).upper()


def output_dir():
    path = tempfile.mkdtemp(dir=scratch_dir(), prefix='out-')
    return path


# MARK: - Media fixtures

@functools.cache
def fixture(name):
    """Path of a small generated media file (ffmpeg required)."""
    folder = os.path.join(scratch_dir(), 'fixtures')
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, name)
    video = ['-f', 'lavfi', '-i', 'testsrc=size=160x120:rate=15']
    audio = ['-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100']
    h264 = ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-g', '15']
    recipes = {
        'clip.mp4': [*video, *audio, '-t', '3', *h264, '-c:a', 'aac', '-shortest'],
        'video.mp4': [*video, '-t', '3', *h264, '-an'],
        'audio.m4a': [*audio, '-t', '3', '-c:a', 'aac', '-vn'],
        'audio.webm': [*audio, '-t', '3', '-c:a', 'libopus', '-vn'],
        'thumbnail.jpg': ['-f', 'lavfi', '-i', 'color=c=red:s=64x64', '-frames:v', '1'],
    }
    if name == 'thumbnail.webp':
        with open(path, 'wb') as file:
            file.write(_WEBP_PIXEL)
        return path
    _run([FFMPEG, '-v', 'error', '-y', *recipes[name], path])
    return path


def streams(path):
    """ffprobe's codec_type → codec_name for a file."""
    return [(stream['codec_type'], stream['codec_name']) for stream in _ffprobe(path)['streams']]


def tags(path):
    return {key.lower(): value for key, value in _ffprobe(path)['format'].get('tags', {}).items()}


# MARK: - A local web server

class LocalServer:
    """Serves byte strings at fixed paths, with Range support, from a background thread.

    A route may be slow: `(data, content_type, delay)` sends 4 KiB every `delay` seconds.
    """

    def __init__(self, routes):
        self.routes = dict(routes)
        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *args):
                pass

            def do_HEAD(self):
                self._respond(send_body=False)

            def do_GET(self):
                self._respond(send_body=True)

            def _respond(self, send_body):
                route = server.routes.get(self.path.split('?')[0])
                if route is None:
                    self.send_error(404)
                    return
                data, content_type, *rest = route
                if callable(data):
                    data = data()
                delay = rest[0] if rest else None
                start, end, status = 0, len(data) - 1, 200
                range_header = self.headers.get('Range')
                if range_header and range_header.startswith('bytes='):
                    first, _, last = range_header[6:].partition('-')
                    start = int(first or 0)
                    end = min(int(last), len(data) - 1) if last else len(data) - 1
                    status = 206
                body = data[start:end + 1]
                self.send_response(status)
                self.send_header('Content-Type', content_type)
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Accept-Ranges', 'bytes')
                if status == 206:
                    self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
                self.end_headers()
                if not send_body:
                    return
                try:
                    if delay is None:
                        self.wfile.write(body)
                        return
                    for offset in range(0, len(body), 4096):
                        self.wfile.write(body[offset:offset + 4096])
                        self.wfile.flush()
                        time.sleep(delay)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self._server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self._server.daemon_threads = True
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    @property
    def base_url(self):
        host, port = self._server.server_address[:2]
        return f'http://{host}:{port}'

    def url(self, path):
        return f'{self.base_url}{path}'

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, *exc_info):
        self._server.shutdown()
        self._server.server_close()


def read(path):
    with open(path, 'rb') as file:
        return file.read()
