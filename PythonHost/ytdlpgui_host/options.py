"""Turns an argument vector into YoutubeDL parameters, exactly as the command-line tool does.

Swift builds the arguments (the command preview shows them), `yt_dlp.parse_options` interprets
them, and this module adds what the preview doesn't show: the host's logger and hooks, and the
settings that make yt-dlp behave inside an app. It also refuses anything that would run a
program, read configuration or plugins, replace yt-dlp, or wait for a terminal that isn't
there. Swift's `CustomArgumentPolicy` already strips most of these from the custom-arguments
field; this is the second line of defence.
"""

import dataclasses
import optparse

from . import compat
from .errors import HostError

# Settings in `--compat-options` that change module-level state in yt-dlp while the arguments
# are parsed, and so would leak into every other download running at the same time.
_PROCESS_WIDE_COMPAT_OPTIONS = ('allow-unsafe-ext', 'prefer-vp9-sort')


class ArgumentError(HostError):
    """The arguments can't be used: yt-dlp rejected them, or the host refuses what they ask."""


@dataclasses.dataclass(frozen=True)
class ParsedArguments:
    """The result of parsing, as the command-line tool would see it."""

    #: The YoutubeDL parameters `parse_options` built. Never modified; see `engine_params`.
    params: dict
    urls: list
    #: The raw option values, for the few things `parse_options` leaves out of `params`.
    options: optparse.Values


def parse(argv):
    """Parses `argv` with yt-dlp's own parser and checks it is safe to run in the app.

    Raises `ArgumentError` with a message for people when the arguments can't be used.
    """
    if not isinstance(argv, list) or not all(isinstance(argument, str) for argument in argv):
        raise ArgumentError('The engine was given arguments that aren\'t a list of strings.')

    # Some options act while they are being parsed — reading configuration files or standard
    # input, prompting for a password, changing global state — so they are looked for first,
    # with a parse that has no side effects.
    _refuse_before_parsing(_parse_leniently(argv))

    import yt_dlp

    try:
        _, options, urls, params = yt_dlp.parse_options(list(argv))
    except optparse.OptParseError as error:
        raise ArgumentError(_parser_message(error)) from None
    except SystemExit as exit_:
        raise ArgumentError(_exit_message(exit_)) from None

    _refuse_after_parsing(options, params)
    return ParsedArguments(params=params, urls=list(urls), options=options)


def engine_params(parsed, *, logger, progress_hook, postprocessor_hook, cache_dir, for_analysis):
    """The parameters for one job's YoutubeDL: the parsed ones plus the engine's plumbing."""
    params = dict(parsed.params)
    # no_color replaces the --color policy; dropping the policy first avoids YoutubeDL's
    # warning that it is being overwritten, which would otherwise start every job's log.
    params.pop('color', None)
    params.update({
        'logger': logger,
        'progress_hooks': [*params.get('progress_hooks', ()), progress_hook],
        'postprocessor_hooks': [*params.get('postprocessor_hooks', ()), postprocessor_hook],
        # Suppresses only the printed progress bar: the downloader still calls every progress
        # hook (FileDownloader._hook_progress), and those become the app's progress events.
        'noprogress': True,
        'no_color': True,
        # The only JavaScript runtime the app has; see javascript.py.
        'js_runtimes': {'jsc': {}},
        # yt-dlp would tell people to run "yt-dlp -U" once it's 90 days old; the app has its
        # own update screen.
        'warn_when_outdated': False,
    })
    # An explicit --cache-dir or --no-cache-dir wins, as on the command line.
    if params.get('cachedir') is None and cache_dir:
        params['cachedir'] = cache_dir
    # ffmpeg can't download HLS on iOS, so the native downloader is the only one that works.
    if compat.is_ios() and params.get('hls_prefer_native') is None:
        params['hls_prefer_native'] = True
    if for_analysis and params.get('extract_flat') in ('discard', 'discard_in_playlist'):
        # parse_options drops a playlist's entries after processing them unless something will
        # print the playlist. Analysis returns the playlist, so it keeps them, as
        # --dump-single-json would.
        params['extract_flat'] = False
    return params


# MARK: - Before parsing

def _parse_leniently(argv):
    from yt_dlp.options import create_parser

    parser = create_parser()
    # --version would print to standard output before the refusal below could explain.
    parser.print_version = lambda file=None: None
    try:
        options, _ = parser.parse_known_args(argv, strict=False)
    except optparse.OptParseError as error:
        raise ArgumentError(_parser_message(error)) from None
    except SystemExit:
        # --version prints and exits as soon as it is seen.
        raise ArgumentError("yt-dlp's --help and --version output isn't available in the app.") from None
    return options


def _refuse_before_parsing(options):
    if options.print_help:
        raise ArgumentError("yt-dlp's --help and --version output isn't available in the app.")
    if options.config_locations:
        raise ArgumentError(
            "--config-locations can't be used: the app doesn't read yt-dlp configuration files.")
    if options.batchfile == '-':
        raise ArgumentError(_no_terminal('--batch-file - reads links from standard input'))
    if options.load_info_filename == '-':
        raise ArgumentError(_no_terminal('--load-info-json - reads from standard input'))
    if options.format == '-':
        raise ArgumentError(_no_terminal('-f - asks which format to download'))
    if '-' in (options.match_filter or ()) or '-' in (options.breaking_match_filter or ()):
        raise ArgumentError(_no_terminal('A match filter of "-" asks about every video'))
    if options.outtmpl.get('default') == '-':
        raise ArgumentError(
            "-o - writes the download to standard output, which the app doesn't have. "
            'Use an output template with a file name instead.')
    if options.username is not None and options.password is None:
        raise ArgumentError(
            'Pass the password with --password as well: the app can\'t ask for it the way '
            'yt-dlp does on a terminal.')
    if options.ap_username is not None and options.ap_password is None:
        raise ArgumentError(
            'Pass the TV provider password with --ap-password as well: the app can\'t ask for '
            'it the way yt-dlp does on a terminal.')
    for name in _PROCESS_WIDE_COMPAT_OPTIONS:
        if name in (options.compat_opts or ()):
            raise ArgumentError(
                f'--compat-options {name} changes yt-dlp for every download at once, so the app '
                "doesn't allow it.")


def _no_terminal(what):
    return f"{what}, but the app has no terminal to answer from."


# MARK: - After parsing

def _refuse_after_parsing(options, params):
    if any(_runs_commands(definition) for definition in params.get('postprocessors') or ()):
        raise ArgumentError(
            "--exec can't be used: it runs other programs, which apps on iPhone and iPad can't do.")

    downloaders = {name for name in (options.external_downloader or {}).values()
                   if str(name).lower() != 'native'}
    if downloaders:
        raise ArgumentError(
            f"--downloader {', '.join(sorted(downloaders))} can't be used: it runs another "
            "program, which apps on iPhone and iPad can't do. Remove it to use yt-dlp's own "
            'downloader.')

    if options.netrc_cmd:
        raise ArgumentError(
            "--netrc-cmd can't be used: it runs another program, which apps on iPhone and iPad "
            "can't do. Use --username and --password, or --netrc-location, instead.")

    if options.update_self not in (None, False):
        raise ArgumentError(
            "yt-dlp can't update itself from the arguments. Install updates from the app's "
            'engine settings instead.')

    if options.cookiesfrombrowser:
        raise ArgumentError(
            "--cookies-from-browser can't read browser cookies on iPhone and iPad. Export a "
            'cookies.txt file and import it in the app instead.')

    if any(directory != 'default' for directory in options.plugin_dirs or ()):
        raise ArgumentError("--plugin-dirs can't be used: the app doesn't load yt-dlp plugins.")

    if options.config_locations:
        raise ArgumentError(
            "--config-locations can't be used: the app doesn't read yt-dlp configuration files.")

    if params.get('bidi_workaround'):
        raise ArgumentError(
            "--bidi-workaround can't be used: it runs another program, which apps on iPhone and "
            "iPad can't do.")


def _runs_commands(definition):
    return definition.get('key') in ('Exec', 'ExecAfterDownload') or 'exec_cmd' in definition


# MARK: - Messages

def _parser_message(error):
    # yt-dlp's parser formats errors for a terminal: usage line, then "yt-dlp: error: <reason>".
    text = str(error).strip()
    reason = text.rpartition('error: ')[2].strip() or text
    return f'yt-dlp rejected the arguments: {reason}'


def _exit_message(exit_):
    code = exit_.code
    if isinstance(code, str) and code.strip():
        message = code.strip()
        return message.removeprefix('ERROR: ').strip()
    return 'yt-dlp stopped while reading the arguments.'
