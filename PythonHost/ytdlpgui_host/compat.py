"""Keeps yt-dlp from trying to launch programs where it can't.

An iOS app cannot start another process: CPython's `subprocess` raises `OSError(ENOTSUP)` on
iOS. yt-dlp probes for ffmpeg, ffprobe, JavaScript runtimes and other helpers by running them,
and most probes already treat an `OSError` as "not installed". The host makes that outcome
certain and immediate instead of relying on each call site: every program launch through
yt-dlp's `Popen` is refused up front, and ffmpeg's location resolves to nothing, so no ffmpeg
version check is even attempted.

On the Mac the patches stay dormant, so the tests exercise yt-dlp's normal desktop behaviour
unless `YTDLPGUI_HOST_SIMULATE_IOS=1` asks for the iOS behaviour.
"""

import errno
import functools
import getpass
import os
import sys

SIMULATE_IOS_ENVIRONMENT_VARIABLE = 'YTDLPGUI_HOST_SIMULATE_IOS'


def is_ios():
    """Whether programs must not be launched: on iOS, or when the tests simulate it."""
    return sys.platform == 'ios' or os.environ.get(SIMULATE_IOS_ENVIRONMENT_VARIABLE) == '1'


def install():
    """Patches yt-dlp's program probing. Called once, when the engine is configured."""
    from yt_dlp.postprocessor.ffmpeg import FFmpegPostProcessor
    from yt_dlp.utils._utils import Popen

    _refuse_program_launches(Popen)
    _hide_ffmpeg(FFmpegPostProcessor)
    _refuse_password_prompts()


def _refuse_program_launches(popen_class):
    # Every module in yt-dlp imports this one class, so patching it covers `check_executable`,
    # `_get_exe_version_output` and `get_exe_version` — which all report "not found" when the
    # launch fails with OSError — as well as any direct `Popen(...)` call.
    launch = popen_class.__init__

    @functools.wraps(launch)
    def __init__(self, args, *remaining, **kwargs):
        if is_ios():
            raise OSError(
                errno.ENOTSUP,
                f"{_program_name(args)} can't be run, because apps on iPhone and iPad can't "
                'start other programs')
        launch(self, args, *remaining, **kwargs)

    popen_class.__init__ = __init__


def _program_name(args):
    if isinstance(args, (list, tuple)):
        args = args[0] if args else ''
    name = os.path.basename(os.fsdecode(args)) if isinstance(args, (str, bytes, os.PathLike)) else ''
    return name or 'The program'


def _hide_ffmpeg(ffmpeg_class):
    # An empty table makes `FFmpegPostProcessor` report ffmpeg and ffprobe as unavailable
    # without running anything: their versions resolve through `_version_cache[None]`. The
    # app's own post-processors (see postprocessors.py) don't depend on this table.
    determine_executables = ffmpeg_class._determine_executables

    @functools.wraps(determine_executables)
    def _determine_executables(self):
        if is_ios():
            return {}
        return determine_executables(self)

    ffmpeg_class._determine_executables = _determine_executables


def _refuse_password_prompts():
    # yt-dlp asks for two-factor codes and some passwords on the terminal. The app has no
    # terminal, and on iOS standard input doesn't exist, so a prompt would hang or crash the
    # job. Failing with an ExtractorError reports it as an ordinary "ERROR:" line instead.
    def refuse(prompt='Password: ', stream=None):
        from yt_dlp.utils import ExtractorError  # the copy that is loaded now, updated or not

        question = prompt.strip().rstrip(':').strip() or 'a password'
        raise ExtractorError(
            f'yt-dlp needs input that the app can\'t ask for ("{question}"). '
            'Pass it in the custom arguments instead, for example with --password or --twofactor.',
            expected=True)

    getpass.getpass = refuse
