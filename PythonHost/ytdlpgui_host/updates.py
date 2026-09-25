"""Updating yt-dlp from PyPI, without trusting anything that wasn't verified.

Extractors break whenever sites change, so the app has to be able to update yt-dlp between app
releases. An update is two wheels: yt-dlp, and the yt-dlp-ejs release it declares it needs for
YouTube's JavaScript challenges. Both are checked against the SHA-256 digests PyPI publishes,
only their package folders are unpacked, and the result replaces the previous update in one
rename. The update takes effect at the next launch: a running interpreter can't swap out a
package it has already imported.

Only the two folders the app passes in are written to.
"""

import ast
import hashlib
import json
import os
import shutil
import ssl
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

from .errors import HostError

#: PyPI's JSON API. The tests point this at a local server through the environment variable.
DEFAULT_INDEX_URL = 'https://pypi.org/pypi'
INDEX_URL_ENVIRONMENT_VARIABLE = 'YTDLPGUI_HOST_PYPI_URL'

_PACKAGES = ('yt_dlp', 'yt_dlp_ejs')
_EJS_VERSION_FILE = 'yt_dlp/extractor/youtube/jsc/_builtin/vendor/_info.py'

_TIMEOUT = 60
_CHUNK_SIZE = 256 * 1024
_MAX_METADATA_BYTES = 64 * 1024 * 1024
_MAX_WHEEL_BYTES = 100 * 1024 * 1024
_MAX_UNPACKED_BYTES = 400 * 1024 * 1024


class UpdateError(HostError):
    """The update couldn't be checked for or installed; nothing was changed."""


def check_update(_payload):
    """The `check_update` command: compares the newest release on PyPI with the running one."""
    import yt_dlp.version
    from yt_dlp.utils import version_tuple

    current = yt_dlp.version.__version__
    latest = _release_metadata('yt-dlp')['info']['version']
    try:
        is_newer = version_tuple(latest, lenient=True) > version_tuple(current, lenient=True)
    except (TypeError, ValueError):
        is_newer = False
    return {'ok': True, 'current': current, 'latest': latest, 'is_newer': is_newer}


def install_update(payload):
    """The `install_update` command: downloads, verifies and installs the newest yt-dlp."""
    staging_dir = _directory(payload, 'staging_dir')
    update_dir = _directory(payload, 'update_dir')
    os.makedirs(staging_dir, exist_ok=True)
    work_dir = os.path.join(staging_dir, uuid.uuid4().hex)
    os.makedirs(work_dir)
    try:
        yt_dlp_release = _release_metadata('yt-dlp')
        version = yt_dlp_release['info']['version']
        yt_dlp_wheel = _download_wheel(yt_dlp_release, 'yt-dlp', work_dir)

        ejs_version = _ejs_version_required_by(yt_dlp_wheel)
        ejs_wheel = _download_wheel(_release_metadata('yt-dlp-ejs', ejs_version), 'yt-dlp-ejs', work_dir)

        unpacked = os.path.join(work_dir, 'unpacked')
        os.makedirs(unpacked)
        for wheel in (yt_dlp_wheel, ejs_wheel):
            _unpack_packages(wheel, unpacked)
        _check_unpacked(unpacked, version)
        _replace_directory(update_dir, unpacked, work_dir)
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)
    return {'ok': True, 'version': version}


def _directory(payload, key):
    value = payload.get(key)
    if not isinstance(value, str) or not os.path.isabs(value):
        raise UpdateError(f'The update was given no usable {key}.')
    return os.path.normpath(value)


# MARK: - PyPI

def _index_url():
    return os.environ.get(INDEX_URL_ENVIRONMENT_VARIABLE) or DEFAULT_INDEX_URL


def _release_metadata(project, version=None):
    path = f'{project}/{version}/json' if version else f'{project}/json'
    url = f'{_index_url().rstrip("/")}/{urllib.parse.quote(path)}'
    with _open(url, f'the {project} release information') as response:
        body = _read_limited(response, _MAX_METADATA_BYTES, f'The {project} release information')
    try:
        metadata = json.loads(body)
        metadata['info']['version']
    except (ValueError, KeyError, TypeError):
        raise UpdateError(f'PyPI sent unreadable release information for {project}.') from None
    return metadata


def _download_wheel(release, project, work_dir):
    """Downloads the release's pure-Python wheel and checks it against PyPI's digest."""
    version = release['info']['version']
    wheel = next((
        entry for entry in release.get('urls') or ()
        if isinstance(entry, dict) and entry.get('packagetype') == 'bdist_wheel'
        and str(entry.get('filename', '')).endswith('-none-any.whl')
    ), None)
    if wheel is None:
        raise UpdateError(f'PyPI has no installable {project} {version} package.')
    expected = str((wheel.get('digests') or {}).get('sha256') or '').lower()
    if len(expected) != 64:
        raise UpdateError(f'PyPI published no checksum for {project} {version}, so it wasn\'t installed.')
    url = urllib.parse.urljoin(_index_url(), str(wheel.get('url') or ''))

    destination = os.path.join(work_dir, f'{uuid.uuid4().hex}.whl')
    digest = hashlib.sha256()
    written = 0
    with _open(url, f'{project} {version}') as response, open(destination, 'wb') as file:
        while chunk := response.read(_CHUNK_SIZE):
            written += len(chunk)
            if written > _MAX_WHEEL_BYTES:
                raise UpdateError(f'The {project} {version} download is far larger than expected, so it was stopped.')
            digest.update(chunk)
            file.write(chunk)
    if digest.hexdigest() != expected:
        raise UpdateError(
            f"The downloaded {project} {version} doesn't match the checksum PyPI published, so it "
            "wasn't installed.")
    return destination


def _open(url, description):
    if urllib.parse.urlsplit(url).scheme not in ('https', 'http'):
        raise UpdateError(f'The address for {description} isn\'t a web address.')
    request = urllib.request.Request(url, headers={'User-Agent': 'YTDLP-GUI', 'Accept': '*/*'})
    try:
        return urllib.request.urlopen(request, timeout=_TIMEOUT, context=_ssl_context())
    except urllib.error.HTTPError as error:
        raise UpdateError(f'PyPI answered "{error.code} {error.reason}" when asked for {description}.') from None
    except (urllib.error.URLError, OSError) as error:
        reason = getattr(error, 'reason', None) or error
        raise UpdateError(f"Couldn't reach PyPI to get {description}: {reason}.") from None


def _ssl_context():
    try:
        import certifi
    except ImportError:
        return ssl.create_default_context()
    return ssl.create_default_context(cafile=certifi.where())


def _read_limited(response, limit, description):
    body = response.read(limit + 1)
    if len(body) > limit:
        raise UpdateError(f'{description} is far larger than expected, so it was stopped.')
    return body


# MARK: - Wheels

def _ejs_version_required_by(wheel_path):
    """Reads VERSION from yt-dlp's vendored EJS information, without running any of it."""
    with _open_wheel(wheel_path) as wheel:
        try:
            source = wheel.read(_EJS_VERSION_FILE).decode('utf-8')
        except KeyError:
            raise UpdateError(
                "The new yt-dlp doesn't say which challenge-solver version it needs, so it wasn't "
                'installed.') from None
    version = _string_constant(source, 'VERSION')
    if not version or any(character in version for character in '/\\?#'):
        raise UpdateError("The new yt-dlp's challenge-solver version couldn't be read, so it wasn't installed.")
    return version


def _unpack_packages(wheel_path, destination):
    """Extracts the `yt_dlp/` and `yt_dlp_ejs/` folders of a wheel, and nothing else."""
    root = os.path.realpath(destination)
    total = 0
    with _open_wheel(wheel_path) as wheel:
        members = wheel.infolist()
        for member in members:
            _check_member_name(member.filename)
        for member in members:
            parts = member.filename.split('/')
            if parts[0] not in _PACKAGES or member.is_dir():
                continue
            target = os.path.realpath(os.path.join(root, *parts))
            if os.path.commonpath([root, target]) != root:
                raise UpdateError(f'The update contains an unsafe file path ({member.filename}), so it wasn\'t installed.')
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with wheel.open(member) as source, open(target, 'wb') as output:
                while chunk := source.read(_CHUNK_SIZE):
                    total += len(chunk)
                    if total > _MAX_UNPACKED_BYTES:
                        raise UpdateError('The update unpacks to far more than expected, so it wasn\'t installed.')
                    output.write(chunk)


def _check_member_name(name):
    parts = name.replace('\\', '/').split('/')
    if name.startswith('/') or '\\' in name or '..' in parts or (parts and parts[0].endswith(':')):
        raise UpdateError(f'The update contains an unsafe file path ({name}), so it wasn\'t installed.')


def _open_wheel(path):
    try:
        return zipfile.ZipFile(path)
    except zipfile.BadZipFile:
        raise UpdateError('A downloaded update package is damaged, so it wasn\'t installed.') from None


def _check_unpacked(unpacked, expected_version):
    for package in _PACKAGES:
        if not os.path.isfile(os.path.join(unpacked, package, '__init__.py')):
            raise UpdateError(f'The update is missing the {package} package, so it wasn\'t installed.')
    with open(os.path.join(unpacked, 'yt_dlp', 'version.py'), encoding='utf-8') as file:
        version = _string_constant(file.read(), '__version__')
    if version != expected_version:
        raise UpdateError(
            f'The update calls itself {version or "an unknown version"} instead of {expected_version}, '
            "so it wasn't installed.")


def _string_constant(source, name):
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return None
    for node in tree.body:
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant):
            if isinstance(node.value.value, str) and any(
                    isinstance(target, ast.Name) and target.id == name for target in node.targets):
                return node.value.value
    return None


# MARK: - Swapping

def _replace_directory(update_dir, unpacked, work_dir):
    """Makes `unpacked` the new `update_dir`, keeping the old one until the new one is in place."""
    os.makedirs(os.path.dirname(update_dir), exist_ok=True)
    previous = None
    if os.path.lexists(update_dir):
        previous = os.path.join(work_dir, 'previous')
        os.rename(update_dir, previous)
    try:
        os.rename(unpacked, update_dir)
    except OSError as error:
        if previous is not None:
            os.rename(previous, update_dir)
        raise UpdateError(f"The update couldn't be put in place: {error.strerror or error}.") from None
    # `previous` lives inside `work_dir`, which the caller deletes.
