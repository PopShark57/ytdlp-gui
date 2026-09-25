"""Starting the engine: choosing which yt-dlp to import, and wiring the app into it.

`configure` runs once, before any other command. It imports yt-dlp — an installed update when
there is one that works, otherwise the copy bundled with the app — and installs the host's
integration (see compat.py, postprocessors.py and javascript.py) exactly once.

Nothing that imports yt-dlp is imported before this module has decided which yt-dlp to use:
an update that fails has to be purged from `sys.modules` along with everything that saw it.
"""

import dataclasses
import importlib
import os
import platform
import sys
import threading

from .errors import HostError

#: The host's modules that import yt-dlp, which are purged with it if an update fails.
_INTEGRATION_MODULES = ('compat', 'options', 'jobs', 'postprocessors', 'javascript', 'downloads')


class NotConfiguredError(HostError):
    """A command that needs yt-dlp arrived before `configure` succeeded."""

    def __init__(self, message="The download engine hasn't been started yet."):
        super().__init__(message)


@dataclasses.dataclass(frozen=True)
class Settings:
    """What `configure` was told, and what it found."""

    cache_dir: str | None
    platform_version: str | None
    update_dir: str | None
    #: "bundled" or "updated": where the yt-dlp in use came from.
    source: str
    #: Why an installed update isn't in use, when there is one.
    update_error: str | None


_lock = threading.Lock()
_settings = None


def configure(payload):
    """The `configure` command. Later calls return the same versions without doing any work."""
    global _settings
    cache_dir = _optional_string(payload, 'cache_dir')
    update_dir = _optional_string(payload, 'update_dir')
    platform_version = _optional_string(payload, 'platform_version')
    with _lock:
        if _settings is None:
            _settings = _start(cache_dir, update_dir, platform_version)
        return _versions(_settings)


def version(_payload):
    """The `version` command."""
    return _versions(settings())


def settings():
    """The engine's settings. Raises `NotConfiguredError` before `configure` has succeeded."""
    current = _settings
    if current is None:
        raise NotConfiguredError()
    return current


def is_configured():
    return _settings is not None


def _optional_string(payload, key):
    value = payload.get(key)
    if value is None or value == '':
        return None
    if not isinstance(value, str):
        raise HostError(f'The engine was given a {key} that isn\'t text.')
    return value


def _start(cache_dir, update_dir, platform_version):
    _prepare_environment()

    source, update_error = 'bundled', None
    if update_dir and os.path.isdir(os.path.join(update_dir, 'yt_dlp')):
        try:
            _import_and_integrate(platform_version, first_path=update_dir)
        except Exception as error:
            update_error = (
                f"The installed yt-dlp update couldn't be loaded, so the bundled version is in "
                f'use: {_describe(error)}')
            _forget(update_dir)
        else:
            source = 'updated'

    if source == 'bundled':
        try:
            _import_and_integrate(platform_version)
        except Exception as error:
            _forget(None)
            raise HostError(f"yt-dlp couldn't be loaded: {_describe(error)}") from error

    return Settings(
        cache_dir=cache_dir, platform_version=platform_version, update_dir=update_dir,
        source=source, update_error=update_error)


def _prepare_environment():
    # The embedded OpenSSL can't see the iOS trust store; certifi's bundle stands in for it.
    # (yt-dlp loads certifi by itself; this covers the standard library, e.g. in updates.py.)
    try:
        import certifi
    except ImportError:
        pass
    else:
        os.environ['SSL_CERT_FILE'] = certifi.where()
    # yt-dlp would look for plugins in configuration folders and on sys.path; the app
    # doesn't run code that didn't ship with it or come from a verified update.
    os.environ['YTDLP_NO_PLUGINS'] = '1'


def _import_and_integrate(platform_version, first_path=None):
    if first_path is not None:
        sys.path.insert(0, first_path)
        importlib.invalidate_caches()

    import yt_dlp
    import yt_dlp.version
    from yt_dlp import globals as yt_dlp_globals

    if first_path is not None and not _is_inside(yt_dlp.__file__, first_path):
        raise ImportError(f'yt-dlp was loaded from {os.path.dirname(yt_dlp.__file__)} instead')

    # As the command-line tool: its log format, and no "API" details (such as every
    # parameter, passwords included) in verbose output.
    yt_dlp_globals.IN_CLI.value = True
    yt_dlp_globals.plugin_dirs.value = []

    from . import compat, javascript, postprocessors

    compat.install()
    postprocessors.install()
    javascript.install(platform_version)

    # Load the command modules now, so a yt-dlp they don't fit fails here, where the update
    # can still be set aside, rather than in the middle of a download.
    importlib.import_module(f'{__package__}.downloads')


def _forget(path):
    """Undoes a failed import: the path, yt-dlp's modules and the host modules that saw them."""
    if path is not None:
        while path in sys.path:
            sys.path.remove(path)
    host_modules = {f'{__package__}.{name}' for name in _INTEGRATION_MODULES}
    for name in list(sys.modules):
        if name.startswith('yt_dlp') or name in host_modules:
            del sys.modules[name]
    # yt-dlp registers import hooks for its plugin namespaces; drop the stale ones.
    sys.meta_path[:] = [
        finder for finder in sys.meta_path
        if not type(finder).__module__.startswith('yt_dlp')]
    importlib.invalidate_caches()


def _is_inside(path, folder):
    try:
        return os.path.commonpath([os.path.realpath(path), os.path.realpath(folder)]) == os.path.realpath(folder)
    except ValueError:
        return False


def _describe(error):
    return str(error) or type(error).__name__


def _versions(current):
    import yt_dlp.version

    return {
        'ok': True,
        'python': platform.python_version(),
        'yt_dlp': yt_dlp.version.__version__,
        'yt_dlp_source': current.source,
        'ejs': _package_version('yt_dlp_ejs', 'version'),
        'certifi': _package_version('certifi', '__version__'),
        'update_error': current.update_error,
    }


def _package_version(module_name, attribute):
    try:
        module = importlib.import_module(module_name)
    except ImportError:
        return None
    value = getattr(module, attribute, None)
    return str(value) if value else None
