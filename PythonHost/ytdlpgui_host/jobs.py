"""Running jobs: registration, cancellation, and everything a job reports to the app.

Swift calls `dispatch` for each analysis or download on a thread of its own, so several jobs
run at once. Each has its own `Job`, logger, hooks and YoutubeDL; nothing here is shared
between jobs except the registry, which only maps job IDs to jobs.
"""

import collections
import contextlib
import os
import re
import threading
import time

from yt_dlp import YoutubeDL
from yt_dlp.postprocessor.common import PostProcessor
from yt_dlp.utils import DownloadCancelled, float_or_none, int_or_none, str_or_none

from . import bridge
from .errors import HostError

#: The most `downloading` progress events a job sends per second, as the protocol promises.
PROGRESS_INTERVAL = 0.2

#: Cancellations for jobs that hadn't started yet are remembered this long (in number of
#: jobs), so a job the app cancels while its thread is still starting never runs.
_EARLY_CANCELLATION_MEMORY = 256

#: An analysis log is returned to the app when it fails; this bounds a verbose one.
_MAX_KEPT_LOG_LINES = 10_000

_TERMINAL_SEQUENCES = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-_])')
_LINE_BREAKS = re.compile(r'\r\n|\r|\n')

#: Info-dict key listing extra files a video ended up as, besides `filepath`. Keys starting
#: with "__" are private to yt-dlp's callers and never written to info JSON.
KEPT_FILES_KEY = '__ytdlpgui_kept_files'


class JobCancelled(DownloadCancelled):
    """Raised in a job's thread when the app cancels the job.

    `_ytdlpgui.interrupt` raises this by class, from another thread, so it must be
    constructible without arguments. As a `DownloadCancelled`, yt-dlp lets it through its own
    error handling and keeps partial files, so a retry resumes where this one stopped.
    """

    msg = 'Cancelled'


class JobConflictError(HostError):
    """A job with the same ID is already running."""


class Job:
    """One analysis or download, from the moment `dispatch` receives it until it returns."""

    def __init__(self, job_id):
        self.id = job_id
        self.files = []
        self._cancelled = threading.Event()
        # Guards the handshake between `cancel` (any thread) and `run` (the job's thread), so
        # an asynchronous exception is only ever raised while `run` is ready to catch it.
        self._lock = threading.Lock()
        self._thread_ident = None
        self._interruptible = False
        self._interrupted = False
        self._progress_lock = threading.Lock()
        self._last_progress = None
        self._last_postprocessing = None

    @property
    def cancel_requested(self):
        return self._cancelled.is_set()

    def check_cancelled(self):
        """Raises `JobCancelled` if the app has cancelled this job."""
        if self._cancelled.is_set():
            raise JobCancelled()

    def cancel(self):
        """Asks the job to stop, from any thread.

        The flag is enough whenever yt-dlp calls back into the host (hooks and log lines
        check it), but extraction and retries can go a long time without doing so, so the
        job's thread is also interrupted: `JobCancelled` is raised there at its next Python
        instruction. That happens at most once, and only while `run` can catch it.
        """
        self._cancelled.set()
        with self._lock:
            if self._interruptible and not self._interrupted:
                self._interrupted = True
                bridge.interrupt(self._thread_ident, JobCancelled)

    def run(self, work):
        """Calls `work()` on this thread in a state where `cancel` may interrupt it.

        `JobCancelled` may come out of this, from `work` or from an interrupt that was
        already on its way when `work` returned; callers treat both as a cancellation. Once
        this returns or raises, no interrupt can reach the thread any more.
        """
        with self._lock:
            self._thread_ident = threading.get_ident()
            self._interruptible = True
        try:
            self.check_cancelled()
            return work()
        finally:
            with self._lock:
                self._interruptible = False
            _absorb_pending_interrupt()

    def emit(self, event):
        bridge.emit(self.id, event)

    def report_progress(self, status):
        """yt-dlp progress hook: sends `progress` events, at most five a second."""
        self.check_cancelled()
        state = status.get('status')
        now = time.monotonic()
        with self._progress_lock:
            if state == 'downloading':
                if self._last_progress is not None and now - self._last_progress < PROGRESS_INTERVAL:
                    return
                self._last_progress = now
            else:
                # The next file's first update goes out straight away.
                self._last_progress = None
        self.emit({
            'type': 'progress',
            'status': state,
            'downloaded_bytes': int_or_none(status.get('downloaded_bytes')),
            'total_bytes': int_or_none(status.get('total_bytes')),
            'total_bytes_estimate': float_or_none(status.get('total_bytes_estimate')),
            'speed': float_or_none(status.get('speed')),
            'eta': float_or_none(status.get('eta')),
            'elapsed': float_or_none(status.get('elapsed')),
            'fragment_index': int_or_none(status.get('fragment_index')),
            'fragment_count': int_or_none(status.get('fragment_count')),
            'filename': str_or_none(status.get('filename')),
        })

    def report_postprocessing(self, status):
        """yt-dlp post-processor hook: sends `postprocess` events."""
        self.check_cancelled()
        # Post-processors built from the parameters are given the hook twice (once by their
        # constructor, once by YoutubeDL.add_post_processor), and both calls receive the same
        # status dict. Post-processors run one at a time on the job's thread.
        if status is self._last_postprocessing:
            return
        self._last_postprocessing = status
        info = status.get('info_dict') or {}
        self.emit({
            'type': 'postprocess',
            'status': status.get('status'),
            'postprocessor': status.get('postprocessor'),
            'filepath': str_or_none(info.get('filepath')),
        })


def _absorb_pending_interrupt():
    # `cancel` can raise JobCancelled in this thread up to the moment the job stops being
    # interruptible. CPython delivers such an exception at the thread's next check for pending
    # work, which happens on entry to any Python function. Calling one here, inside a handler,
    # makes sure an interrupt that was already on its way lands now instead of later, in code
    # that doesn't expect it.
    try:
        for _ in range(3):
            _checkpoint()
    except JobCancelled:
        pass


def _checkpoint():
    pass


# MARK: - Registry

_jobs = {}
_early_cancellations = collections.OrderedDict()
_registry_lock = threading.Lock()


@contextlib.contextmanager
def registered(job_id):
    """Registers a job under `job_id` for as long as the block runs."""
    job = Job(job_id)
    with _registry_lock:
        if job_id in _jobs:
            raise JobConflictError(f'A job with the ID {job_id} is already running.')
        _jobs[job_id] = job
        if _early_cancellations.pop(job_id, None):
            job.cancel()
    try:
        yield job
    finally:
        with _registry_lock:
            _jobs.pop(job_id, None)


def cancel(job_id):
    """Cancels the job with this ID. Returns whether it was running.

    A job that isn't running yet is cancelled as soon as it starts: the app starts a job on a
    new thread and may cancel it before that thread gets as far as registering it.
    """
    with _registry_lock:
        job = _jobs.get(job_id)
        if job is None:
            _early_cancellations[job_id] = True
            while len(_early_cancellations) > _EARLY_CANCELLATION_MEMORY:
                _early_cancellations.popitem(last=False)
            return False
    job.cancel()
    return True


# MARK: - Log

class JobLogger:
    """Receives everything YoutubeDL would print and sends it to the app as `log` events.

    With a logger set, YoutubeDL routes screen output to `debug` (real debug messages start
    with "[debug] "), warnings to `warning` without their prefix, and stderr output, which
    includes the "ERROR: " prefix, to `error`. Each line is sent as the command-line tool would
    print it, so the app's failure classifier and log view work unchanged.
    """

    def __init__(self, job, *, show_warnings=True, verbose=False, keep_lines=False):
        self._job = job
        self._show_warnings = show_warnings
        self._verbose = verbose
        self._lines = collections.deque(maxlen=_MAX_KEPT_LOG_LINES) if keep_lines else None

    @property
    def lines(self):
        """Every line sent so far, when the logger was asked to keep them."""
        return list(self._lines or ())

    def debug(self, message, **_):
        self._job.check_cancelled()
        text = str(message)
        self._send('debug' if text.startswith('[debug] ') else 'info', text)

    def info(self, message, **_):
        self._job.check_cancelled()
        self._send('info', str(message))

    def warning(self, message, **_):
        self._job.check_cancelled()
        text = str(message)
        if text.startswith('Deprecated Feature: '):
            # YoutubeDL.deprecated_feature sends the same message to `error` right after.
            return
        if self._show_warnings:
            self._send('warning', f'WARNING: {text}')
        elif self._verbose:
            self._send('debug', f'[debug] WARNING: {text}')

    def error(self, message, **_):
        self._job.check_cancelled()
        text = str(message)
        if text.startswith('Deprecated Feature: '):
            level = 'warning'
        elif text.startswith('[debug] '):
            level = 'debug'
        else:
            level = 'error'
        self._send(level, text)

    def stdout(self, message):
        """What the command-line tool prints on standard output (--print, -F and so on)."""
        self._job.check_cancelled()
        self._send('info', str(message))

    def _send(self, level, text):
        for line in _LINE_BREAKS.split(_TERMINAL_SEQUENCES.sub('', text)):
            line = line.rstrip()
            if not line.strip():
                continue
            if self._lines is not None:
                self._lines.append(line)
            self._job.emit({'type': 'log', 'level': level, 'message': line})


def last_error(lines):
    """The message of the last "ERROR:" line, without its prefix, or None."""
    for line in reversed(lines):
        if line.startswith('ERROR:'):
            return line.removeprefix('ERROR:').strip() or None
    return None


# MARK: - YoutubeDL

class EngineYoutubeDL(YoutubeDL):
    """A YoutubeDL that belongs to one job.

    The app's post-processors and JavaScript challenge provider find the job through
    `_downloader.job`, so their requests are attributed to it. Standard output goes to the job's
    log rather than the process's, which on iOS is the system log nobody reads.
    """

    def __init__(self, params, job):
        self.job = job
        super().__init__(params)

    def to_stdout(self, message, skip_eol=False, quiet=None):
        logger = self.params.get('logger')
        if isinstance(logger, JobLogger):
            logger.stdout(message)
        else:
            super().to_stdout(message, skip_eol, quiet)

    def add_reporters(self):
        """Adds the post-processors that send `item` and `file` events."""
        self.add_post_processor(ItemReporterPP(self.job), when='pre_process')
        self.add_post_processor(FileReporterPP(self.job), when='after_move')


def job_of(downloader):
    """The job a YoutubeDL belongs to, or None for one the host didn't create."""
    return getattr(downloader, 'job', None)


class _ReporterPP(PostProcessor):
    """A post-processor that only tells the app what is happening."""

    def __init__(self, job):
        super().__init__()
        self._job = job

    def _hook_progress(self, status, info_dict):
        # Not a step the person asked for, so it stays out of the post-processing events.
        pass


class ItemReporterPP(_ReporterPP):
    """Runs at `pre_process`, before any bytes move, for every video."""

    def run(self, info):
        self._job.emit({
            'type': 'item',
            'id': str_or_none(info.get('id')),
            'title': str_or_none(info.get('title')),
            'uploader': str_or_none(info.get('uploader') or info.get('channel')),
            'thumbnail': str_or_none(info.get('thumbnail')),
            'duration': float_or_none(info.get('duration')),
            'webpage_url': str_or_none(info.get('webpage_url')),
            'extractor': str_or_none(info.get('extractor')),
            'playlist_index': int_or_none(info.get('playlist_index')),
            'playlist_count': int_or_none(info.get('playlist_count') or info.get('n_entries')),
        })
        return [], info


class FileReporterPP(_ReporterPP):
    """Runs at `after_move`, once a video's files are at their final location."""

    def run(self, info):
        for path, is_main in _final_paths(info):
            self._job.files.append(path)
            # `main` tells the video apart from a companion kept beside it, so the app names the
            # video, not its separate audio track.
            self._job.emit({'type': 'file', 'path': path, 'main': is_main})
        return [], info


def _final_paths(info):
    """The video's final file, then any companions kept beside it, as (path, is_main) pairs."""
    main = info.get('filepath')
    if not main:
        return []
    paths = [(main, True)]
    # Files a post-processor kept alongside the main one (see MergerPP in postprocessors.py).
    # MoveFilesAfterDownloadPP moved them into the same folder under their own names.
    folder = os.path.dirname(main)
    for kept in info.get(KEPT_FILES_KEY) or ():
        path = os.path.join(folder, os.path.basename(kept))
        if path != main and os.path.exists(path):
            paths.append((path, False))
    return paths
