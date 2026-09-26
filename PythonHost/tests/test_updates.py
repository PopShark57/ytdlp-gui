"""Updating yt-dlp from a (local, stand-in) PyPI, and starting the engine with an update."""

import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
import zipfile
from unittest import mock

from tests import support

from ytdlpgui_host import updates

NEW_VERSION = '2099.01.01'
EJS_VERSION = '0.9.9'
REPOSITORY = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOST = os.path.join(REPOSITORY, 'PythonHost')
VENDOR = os.path.join(REPOSITORY, 'Vendor', 'python-packages')


def setUpModule():
    support.configure_engine()


def wheel(files):
    """A wheel (a zip file) holding `files`, a mapping of archive name to text."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as archive:
        for name, text in files.items():
            archive.writestr(name, text)
    return buffer.getvalue()


def yt_dlp_wheel(version=NEW_VERSION, ejs_version=EJS_VERSION, extra=None):
    files = {
        'yt_dlp/__init__.py': '',
        'yt_dlp/version.py': f"__version__ = '{version}'\nRELEASE_GIT_HEAD = 'abc'\n",
        'yt_dlp/extractor/youtube/jsc/_builtin/vendor/_info.py': f"VERSION = '{ejs_version}'\nHASHES = {{}}\n",
        f'yt_dlp-{version}.dist-info/METADATA': 'Name: yt-dlp\n',
        f'yt_dlp-{version}.data/data/share/doc/yt_dlp/README.txt': 'readme\n',
    }
    files.update(extra or {})
    return wheel(files)


def ejs_wheel(version=EJS_VERSION):
    return wheel({
        'yt_dlp_ejs/__init__.py': 'from yt_dlp_ejs._version import version\n',
        'yt_dlp_ejs/_version.py': f"version = '{version}'\n",
        f'yt_dlp_ejs-{version}.dist-info/METADATA': 'Name: yt-dlp-ejs\n',
    })


class FakePyPI:
    """PyPI's JSON API and file hosting, served locally."""

    def __init__(self, yt_dlp=None, ejs=None, yt_dlp_digest=None, ejs_digest=None, version=NEW_VERSION):
        self.files = {'/files/yt_dlp.whl': yt_dlp or yt_dlp_wheel(), '/files/yt_dlp_ejs.whl': ejs or ejs_wheel()}
        self.digests = {
            '/files/yt_dlp.whl': yt_dlp_digest or hashlib.sha256(self.files['/files/yt_dlp.whl']).hexdigest(),
            '/files/yt_dlp_ejs.whl': ejs_digest or hashlib.sha256(self.files['/files/yt_dlp_ejs.whl']).hexdigest(),
        }
        self.version = version
        self.server = support.LocalServer({})

    def release(self, project, version, path):
        return json.dumps({
            'info': {'name': project, 'version': version},
            'urls': [
                {'packagetype': 'sdist', 'filename': f'{project}-{version}.tar.gz',
                 'url': self.server.url('/files/nothing.tar.gz'), 'digests': {'sha256': '0' * 64}},
                {'packagetype': 'bdist_wheel', 'filename': f'{project.replace("-", "_")}-{version}-py3-none-any.whl',
                 'url': self.server.url(path), 'digests': {'sha256': self.digests[path]}},
            ],
        }).encode()

    def __enter__(self):
        self.server.__enter__()
        self.server.routes.update({
            '/pypi/yt-dlp/json': (self.release('yt-dlp', self.version, '/files/yt_dlp.whl'), 'application/json'),
            f'/pypi/yt-dlp-ejs/{EJS_VERSION}/json': (
                self.release('yt-dlp-ejs', EJS_VERSION, '/files/yt_dlp_ejs.whl'), 'application/json'),
            **{path: (data, 'application/zip') for path, data in self.files.items()},
        })
        self.environment = mock.patch.dict(
            os.environ, {updates.INDEX_URL_ENVIRONMENT_VARIABLE: self.server.url('/pypi')})
        self.environment.start()
        return self

    def __exit__(self, *exc_info):
        self.environment.stop()
        self.server.__exit__(*exc_info)


class InstallUpdateTests(unittest.TestCase):

    def setUp(self):
        self.root = tempfile.mkdtemp(dir=support.scratch_dir(), prefix='engine-')
        self.staging = os.path.join(self.root, 'Engine', 'staging')
        self.update_dir = os.path.join(self.root, 'Engine', 'yt-dlp')

    def install(self):
        return support.call('install_update', {'staging_dir': self.staging, 'update_dir': self.update_dir})

    def everything_under_root(self):
        return sorted(os.path.relpath(os.path.join(folder, name), self.root)
                      for folder, _, names in os.walk(self.root) for name in names)

    def test_installs_the_newest_release(self):
        with FakePyPI():
            result = self.install()
        self.assertEqual(result, {'ok': True, 'version': NEW_VERSION})
        self.assertEqual(self.everything_under_root(), [
            'Engine/yt-dlp/yt_dlp/__init__.py',
            'Engine/yt-dlp/yt_dlp/extractor/youtube/jsc/_builtin/vendor/_info.py',
            'Engine/yt-dlp/yt_dlp/version.py',
            'Engine/yt-dlp/yt_dlp_ejs/__init__.py',
            'Engine/yt-dlp/yt_dlp_ejs/_version.py',
        ])
        self.assertEqual(os.listdir(self.staging), [])

    def test_never_replaces_an_existing_folder(self):
        # The running interpreter may be importing from it.
        for existing in ('with-files', 'empty'):
            with self.subTest(existing=existing):
                shutil.rmtree(self.update_dir, ignore_errors=True)
                os.makedirs(os.path.join(self.update_dir, 'yt_dlp') if existing == 'with-files' else self.update_dir)
                if existing == 'with-files':
                    with open(os.path.join(self.update_dir, 'yt_dlp', 'old.py'), 'w') as file:
                        file.write('')
                with FakePyPI():
                    result = self.install()
                self.assertEqual(result['ok'], False)
                self.assertIn('already exists', result['error'])
                if existing == 'with-files':
                    self.assertTrue(os.path.exists(os.path.join(self.update_dir, 'yt_dlp', 'old.py')))
                else:
                    self.assertEqual(os.listdir(self.update_dir), [])

    def test_installs_beside_the_update_in_use_without_touching_it(self):
        # The app's layout: each update in a folder of its own under versions/.
        versions = os.path.join(self.root, 'Engine', 'yt-dlp', 'versions')
        in_use = os.path.join(versions, 'A')
        os.makedirs(os.path.join(in_use, 'yt_dlp'))
        with open(os.path.join(in_use, 'yt_dlp', 'extractor.py'), 'w') as file:
            file.write('VERSION = "A"\n')
        self.update_dir = os.path.join(versions, 'B')
        with FakePyPI():
            self.assertTrue(self.install()['ok'])
        self.assertEqual(sorted(os.listdir(versions)), ['A', 'B'])
        self.assertEqual(os.listdir(os.path.join(in_use, 'yt_dlp')), ['extractor.py'])
        self.assertTrue(os.path.isfile(os.path.join(self.update_dir, 'yt_dlp', 'version.py')))
        self.assertFalse(os.path.exists(os.path.join(self.update_dir, 'previous')))
        self.assertEqual(os.listdir(self.staging), [])

    def test_rejects_a_wheel_that_does_not_match_its_digest(self):
        with FakePyPI(yt_dlp_digest='1' * 64):
            result = self.install()
        self.assertEqual(result['ok'], False)
        self.assertIn("doesn't match the checksum", result['error'])
        self.assertFalse(os.path.exists(self.update_dir))
        self.assertEqual(os.listdir(self.staging), [])

    def test_rejects_an_ejs_wheel_that_does_not_match_its_digest(self):
        with FakePyPI(ejs_digest='2' * 64):
            result = self.install()
        self.assertIn('yt-dlp-ejs', result['error'])
        self.assertFalse(os.path.exists(self.update_dir))

    def test_rejects_paths_that_leave_the_staging_folder(self):
        for name in ('yt_dlp/../../../escaped.py', '/tmp/ytdlpgui-absolute.py', 'yt_dlp\\..\\escaped.py'):
            with self.subTest(name=name):
                with FakePyPI(yt_dlp=yt_dlp_wheel(extra={name: 'import os\n'})):
                    result = self.install()
                self.assertEqual(result['ok'], False)
                self.assertIn('unsafe file path', result['error'])
                self.assertFalse(os.path.exists(self.update_dir))
                self.assertFalse(os.path.exists('/tmp/ytdlpgui-absolute.py'))
                self.assertEqual([path for path in self.everything_under_root() if 'escaped' in path], [])
        self.assertFalse(any('escaped' in name for name in os.listdir(support.scratch_dir())))

    def test_rejects_a_release_whose_version_does_not_match(self):
        with FakePyPI(yt_dlp=yt_dlp_wheel(version='2000.01.01')):
            result = self.install()
        self.assertIn('calls itself 2000.01.01', result['error'])
        self.assertFalse(os.path.exists(self.update_dir))

    def test_rejects_a_release_without_the_ejs_version(self):
        broken = wheel({'yt_dlp/__init__.py': '', 'yt_dlp/version.py': f"__version__ = '{NEW_VERSION}'\n"})
        with FakePyPI(yt_dlp=broken):
            result = self.install()
        self.assertIn('challenge-solver', result['error'])

    def test_needs_absolute_folders(self):
        result = support.call('install_update', {'staging_dir': 'relative', 'update_dir': self.update_dir})
        self.assertEqual(result['ok'], False)

    def test_unreachable_index(self):
        with mock.patch.dict(os.environ, {updates.INDEX_URL_ENVIRONMENT_VARIABLE: 'http://127.0.0.1:9/pypi'}):
            result = self.install()
        self.assertEqual(result['ok'], False)
        self.assertIn("Couldn't reach PyPI", result['error'])


class CheckUpdateTests(unittest.TestCase):

    def test_newer_release(self):
        import yt_dlp.version

        with FakePyPI():
            result = support.call('check_update', {})
        self.assertEqual(result, {
            'ok': True, 'current': yt_dlp.version.__version__, 'latest': NEW_VERSION, 'is_newer': True})

    def test_same_release(self):
        import yt_dlp.version

        with FakePyPI(version=yt_dlp.version.__version__):
            result = support.call('check_update', {})
        self.assertFalse(result['is_newer'])


class StartingWithAnUpdateTests(unittest.TestCase):
    """yt-dlp is imported once per process, so each case runs in a fresh interpreter."""

    SCRIPT = textwrap.dedent('''
        import json, sys, types
        stand_in = types.ModuleType('_ytdlpgui')
        stand_in.emit = lambda job, event: None
        stand_in.request = lambda job, request: '{"ok": false, "error": "none"}'
        stand_in.interrupt = lambda ident, error: 0
        sys.modules['_ytdlpgui'] = stand_in
        import ytdlpgui_host
        configured = json.loads(ytdlpgui_host.dispatch('configure', json.dumps(
            {"cache_dir": None, "update_dir": sys.argv[1], "platform_version": "18.0"})))
        analysis = json.loads(ytdlpgui_host.dispatch('analyze', json.dumps(
            {"job_id": "j", "argv": ["--enable-file-urls", "--", "file://" + sys.argv[2]]})))
        import yt_dlp
        print(json.dumps({"configured": configured, "analysis_ok": analysis["ok"],
                          "yt_dlp_file": yt_dlp.__file__, "update_on_path": sys.argv[1] in sys.path}))
    ''')

    def start(self, update_dir):
        environment = dict(os.environ, PYTHONPATH=os.pathsep.join([HOST, VENDOR]), PYTHONDONTWRITEBYTECODE='1')
        completed = subprocess.run(
            [sys.executable, '-c', self.SCRIPT, update_dir, support.fixture('clip.mp4')],
            capture_output=True, text=True, env=environment, timeout=120)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout.strip().splitlines()[-1])

    def update_dir(self):
        return tempfile.mkdtemp(dir=support.scratch_dir(), prefix='update-')

    @support.requires_ffmpeg
    def test_a_broken_update_falls_back_to_the_bundled_copy(self):
        update_dir = self.update_dir()
        os.makedirs(os.path.join(update_dir, 'yt_dlp'))
        with open(os.path.join(update_dir, 'yt_dlp', '__init__.py'), 'w') as file:
            file.write('raise ImportError("this update is broken")\n')
        result = self.start(update_dir)
        configured = result['configured']
        self.assertEqual(configured['ok'], True)
        self.assertEqual(configured['yt_dlp_source'], 'bundled')
        self.assertIn('this update is broken', configured['update_error'])
        self.assertTrue(result['yt_dlp_file'].startswith(VENDOR))
        self.assertFalse(result['update_on_path'])
        self.assertTrue(result['analysis_ok'])

    @support.requires_ffmpeg
    def test_an_update_that_does_not_fit_the_host_falls_back_too(self):
        # Imports fine, but lacks what the host plugs into.
        update_dir = self.update_dir()
        os.makedirs(os.path.join(update_dir, 'yt_dlp'))
        with open(os.path.join(update_dir, 'yt_dlp', '__init__.py'), 'w') as file:
            file.write('')
        with open(os.path.join(update_dir, 'yt_dlp', 'version.py'), 'w') as file:
            file.write(f"__version__ = '{NEW_VERSION}'\n")
        result = self.start(update_dir)
        self.assertEqual(result['configured']['yt_dlp_source'], 'bundled')
        self.assertTrue(result['configured']['update_error'])
        self.assertTrue(result['analysis_ok'])

    @support.requires_ffmpeg
    def test_a_working_update_is_used(self):
        update_dir = self.update_dir()
        for package in ('yt_dlp', 'yt_dlp_ejs'):
            shutil.copytree(os.path.join(VENDOR, package), os.path.join(update_dir, package),
                            ignore=shutil.ignore_patterns('__pycache__'))
        version_file = os.path.join(update_dir, 'yt_dlp', 'version.py')
        with open(version_file, encoding='utf-8') as file:
            source = file.read()
        with open(version_file, 'w', encoding='utf-8') as file:
            file.write(re.sub(r"__version__ = '[^']*'", f"__version__ = '{NEW_VERSION}'", source))
        result = self.start(update_dir)
        configured = result['configured']
        self.assertEqual((configured['yt_dlp_source'], configured['yt_dlp']), ('updated', NEW_VERSION))
        self.assertIsNone(configured['update_error'])
        self.assertTrue(result['yt_dlp_file'].startswith(update_dir))
        self.assertTrue(result['analysis_ok'])

    @support.requires_ffmpeg
    def test_installing_another_update_leaves_the_running_one_alone(self):
        # yt-dlp imports each extractor the first time it is used, from the folder it started
        # with, so a later install must not change what that folder holds.
        running = self.update_dir()
        for package in ('yt_dlp', 'yt_dlp_ejs'):
            shutil.copytree(os.path.join(VENDOR, package), os.path.join(running, package),
                            ignore=shutil.ignore_patterns('__pycache__'))
        new_update = os.path.join(os.path.dirname(running), f'{os.path.basename(running)}-next')
        staging = tempfile.mkdtemp(dir=support.scratch_dir(), prefix='staging-')
        script = textwrap.dedent('''
            import json, sys, types
            stand_in = types.ModuleType('_ytdlpgui')
            stand_in.emit = lambda job, event: None
            stand_in.request = lambda job, request: '{"ok": false, "error": "none"}'
            stand_in.interrupt = lambda ident, error: 0
            sys.modules['_ytdlpgui'] = stand_in
            import ytdlpgui_host
            configured = json.loads(ytdlpgui_host.dispatch('configure', json.dumps(
                {"cache_dir": None, "update_dir": sys.argv[1], "platform_version": "18.0"})))
            unused = 'yt_dlp.extractor.vimeo'
            was_loaded = unused in sys.modules
            installed = json.loads(ytdlpgui_host.dispatch('install_update', json.dumps(
                {"staging_dir": sys.argv[3], "update_dir": sys.argv[2]})))
            import importlib
            extractor = importlib.import_module(unused)
            print(json.dumps({"configured": configured, "installed": installed, "was_loaded": was_loaded,
                              "extractor_file": extractor.__file__}))
        ''')
        with FakePyPI():
            environment = dict(os.environ, PYTHONPATH=os.pathsep.join([HOST, VENDOR]), PYTHONDONTWRITEBYTECODE='1')
            completed = subprocess.run(
                [sys.executable, '-c', script, running, new_update, staging],
                capture_output=True, text=True, env=environment, timeout=120)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout.strip().splitlines()[-1])
        self.assertEqual(result['configured']['yt_dlp_source'], 'updated')
        self.assertEqual(result['installed'], {'ok': True, 'version': NEW_VERSION})
        self.assertFalse(result['was_loaded'])
        self.assertTrue(result['extractor_file'].startswith(running), result['extractor_file'])
        self.assertTrue(os.path.isfile(os.path.join(running, 'yt_dlp', 'extractor', 'vimeo.py')))
        self.assertTrue(os.path.isfile(os.path.join(new_update, 'yt_dlp', 'version.py')))

    @support.requires_ffmpeg
    def test_no_update_installed(self):
        result = self.start(os.path.join(self.update_dir(), 'missing'))
        self.assertEqual(result['configured']['yt_dlp_source'], 'bundled')
        self.assertIsNone(result['configured']['update_error'])


if __name__ == '__main__':
    unittest.main()
