"""The `analyze` and `download` commands.

Both follow the command-line tool: `analyze` returns what `yt-dlp --dump-single-json` would
print, and `download` returns the tool's exit status (0 success, 1 errors, 101 cancelled) while
yt-dlp's own errors reach the app as "ERROR:" log lines, exactly where the tool prints them.
Only problems with the request itself — arguments that can't be parsed or aren't allowed, a job
ID already in use — come back as `{"ok": false, "error": …}` from `download`.
"""

import traceback

from yt_dlp.cookies import CookieLoadError
from yt_dlp.utils import (
    DownloadCancelled,
    DownloadError,
    SameFileError,
    UnsafeExecExpansionError,
    expand_path,
)

from . import engine, jobs, options
from .errors import HostError

EXIT_SUCCESS = 0
EXIT_ERROR = 1
EXIT_CANCELLED = 101


class _SetupError(HostError):
    """YoutubeDL refused the parameters (an invalid format selector, say) before starting."""


def analyze(payload):
    """The `analyze` command: extracts metadata without downloading anything."""
    try:
        job_id, argv = _job_request(payload)
        parsed = options.parse(argv)
        if len(parsed.urls) != 1:
            raise HostError(
                'Give exactly one link to analyse.' if parsed.urls else 'There is no link to analyse.')
        cache_dir = engine.settings().cache_dir
        return _analyze(job_id, parsed, cache_dir)
    except HostError as error:
        return _analysis_failure(str(error), [], cancelled=False)


def _analyze(job_id, parsed, cache_dir):
    with jobs.registered(job_id) as job:
        logger = _logger(job, parsed, keep_lines=True)
        params = options.engine_params(
            parsed, logger=logger, progress_hook=job.report_progress,
            postprocessor_hook=job.report_postprocessing,
            cache_dir=cache_dir, for_analysis=True)

        def work():
            ydl = _youtube_dl(params, job)
            with ydl:
                info = ydl.extract_info(parsed.urls[0], download=False)
                if info is None:
                    return None
                # As --dump-single-json does before printing.
                ydl.post_extract(info)
                return ydl.sanitize_info(info)

        try:
            info = job.run(work)
        except jobs.JobCancelled:
            return _analysis_failure('Cancelled.', logger.lines, cancelled=True)
        except _SetupError as error:
            return _analysis_failure(str(error), logger.lines, cancelled=job.cancel_requested)
        except (DownloadError, DownloadCancelled, CookieLoadError) as error:
            return _analysis_failure(
                jobs.last_error(logger.lines) or _describe(error), logger.lines,
                cancelled=job.cancel_requested)
        except Exception as error:
            _log_crash(logger, error)
            return _analysis_failure(_describe(error), logger.lines, cancelled=job.cancel_requested)

        if info is None:
            if job.cancel_requested:
                return _analysis_failure('Cancelled.', logger.lines, cancelled=True)
            return _analysis_failure(
                jobs.last_error(logger.lines) or "yt-dlp couldn't find anything to download at this link.",
                logger.lines, cancelled=False)
        return {'ok': True, 'info': info}


def download(payload):
    """The `download` command."""
    job_id, argv = _job_request(payload)
    parsed = options.parse(argv)
    info_file = parsed.options.load_info_filename
    if not parsed.urls and info_file is None:
        raise HostError('There is no link to download.')

    with jobs.registered(job_id) as job:
        logger = _logger(job, parsed, keep_lines=False)
        params = options.engine_params(
            parsed, logger=logger, progress_hook=job.report_progress,
            postprocessor_hook=job.report_postprocessing,
            cache_dir=engine.settings().cache_dir, for_analysis=False)

        def work():
            ydl = _youtube_dl(params, job)
            with ydl:
                ydl.add_reporters()
                try:
                    if info_file is not None:
                        return ydl.download_with_info_file(expand_path(info_file))
                    return ydl.download(parsed.urls)
                except jobs.JobCancelled:
                    raise
                except DownloadCancelled:
                    # --max-downloads, --break-on-existing and the like, as in yt_dlp._real_main.
                    ydl.to_screen('Aborting remaining downloads')
                    return EXIT_CANCELLED
                except (DownloadError, CookieLoadError, UnsafeExecExpansionError):
                    return EXIT_ERROR
                except SameFileError as error:
                    logger.error(f'ERROR: {error}')
                    return EXIT_ERROR

        try:
            exit_code = job.run(work)
        except jobs.JobCancelled:
            exit_code = EXIT_CANCELLED
        except _SetupError:
            raise
        except Exception as error:
            if job.cancel_requested:
                exit_code = EXIT_CANCELLED
            else:
                _log_crash(logger, error)
                exit_code = EXIT_ERROR

        cancelled = job.cancel_requested and exit_code != EXIT_SUCCESS
        return {
            'ok': True,
            'exit_code': EXIT_CANCELLED if cancelled else int(exit_code or EXIT_SUCCESS),
            'cancelled': cancelled,
            'files': list(job.files),
        }


def _job_request(payload):
    job_id = payload.get('job_id')
    if not isinstance(job_id, str) or not job_id:
        raise HostError('The engine was asked to start a job without an ID.')
    return job_id, payload.get('argv')


def _logger(job, parsed, *, keep_lines):
    return jobs.JobLogger(
        job, show_warnings=not parsed.params.get('no_warnings'),
        verbose=bool(parsed.params.get('verbose')), keep_lines=keep_lines)


def _youtube_dl(params, job):
    try:
        return jobs.EngineYoutubeDL(params, job)
    except jobs.JobCancelled:
        raise
    except Exception as error:
        raise _SetupError(f"yt-dlp couldn't start: {_describe(error)}") from error


def _analysis_failure(message, lines, *, cancelled):
    return {'ok': False, 'error': message, 'log': list(lines), 'cancelled': cancelled}


def _log_crash(logger, error):
    # What the command-line tool would print if yt-dlp crashed: the error, then the traceback,
    # which is only interesting to someone debugging, so it is logged at debug level.
    try:
        logger.error(f'ERROR: {_describe(error)}')
        for line in traceback.format_exception(error):
            logger.debug(f'[debug] {line}')
    except jobs.JobCancelled:
        pass


def _describe(error):
    message = getattr(error, 'msg', None) or str(error) or type(error).__name__
    return str(message).removeprefix('ERROR: ').strip()
