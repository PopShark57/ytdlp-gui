"""The Mac app's yt-dlp plugin (YTDLPGUI/Resources/ytdlpgui_thumbnail_naming.py), run as the app runs it.

The Mac app starts yt-dlp as a separate program, so these tests do too: the vendored yt-dlp in
its own interpreter, with the plugin laid out in a plugin folder exactly as
`YTDLPPlugins.install` lays it out, and ffmpeg doing the post-processing.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

from tests import support

REPOSITORY = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PLUGIN = os.path.join(REPOSITORY, 'YTDLPGUI', 'Resources', 'ytdlpgui_thumbnail_naming.py')
VENDORED_PACKAGES = os.path.join(REPOSITORY, 'Vendor', 'python-packages')


@support.requires_ffmpeg
class MacThumbnailNamingPluginTests(unittest.TestCase):

    def setUp(self):
        self.output = support.output_dir()
        self.server = support.LocalServer({
            '/animation.gif': (support.read(support.fixture('animation.gif')), 'image/gif'),
            # Like Reddit's previews of a GIF post: named .gif, but a still picture.
            '/preview.gif': (support.read(support.fixture('thumbnail.jpg')), 'image/jpeg'),
        }).__enter__()
        self.addCleanup(self.server.__exit__, None, None, None)

        self.plugin_dir = tempfile.mkdtemp(dir=support.scratch_dir(), prefix='plugins-')
        package = os.path.join(self.plugin_dir, 'ytdlpgui', 'yt_dlp_plugins', 'postprocessor')
        os.makedirs(package)
        shutil.copy(PLUGIN, package)

    def run_yt_dlp(self, *arguments, plugin=True):
        info = {
            '_type': 'video', 'id': 'sample', 'title': 'Sample', 'ext': 'gif',
            'url': self.server.url('/animation.gif'), 'protocol': 'http',
            'vcodec': 'gif', 'acodec': 'none', 'extractor': 'generic', 'extractor_key': 'Generic',
            'webpage_url': self.server.url('/animation.gif'),
            'thumbnails': [{'url': self.server.url('/preview.gif?format=png8&s=abc'), 'id': '0'}],
        }
        info_path = os.path.join(self.output, 'sample.info.json')
        with open(info_path, 'w', encoding='utf-8') as file:
            json.dump(info, file)
        argv = [sys.executable, '-m', 'yt_dlp', '--ignore-config', '--no-overwrites',
                '--paths', self.output, '--output', '%(title)s.%(ext)s', *arguments,
                '--load-info-json', info_path]
        if plugin:
            # As ArgumentBuilder.downloadArguments adds them.
            argv[3:3] = ['--plugin-dirs', self.plugin_dir,
                         '--use-postprocessor', 'YTDLPGUIThumbnailNaming:when=video']
        environment = {**os.environ, 'PYTHONPATH': VENDORED_PACKAGES}
        environment.pop('YTDLP_NO_PLUGINS', None)
        with support.fake_app_work():
            result = subprocess.run(argv, capture_output=True, text=True, env=environment, timeout=120)
        os.remove(info_path)
        return result

    def outputs(self):
        return sorted(name for name in os.listdir(self.output) if name.startswith('Sample'))

    def assertIsTheGif(self, name):
        self.assertEqual(support.read(os.path.join(self.output, name)), support.read(support.fixture('animation.gif')))

    def test_without_the_plugin_the_gif_is_lost(self):
        # The bug the plugin exists for, so this test notices if yt-dlp ever fixes it.
        result = self.run_yt_dlp('--write-thumbnail', plugin=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.outputs(), ['Sample.gif'])
        self.assertEqual(support.read(os.path.join(self.output, 'Sample.gif')),
                         support.read(support.fixture('thumbnail.jpg')))

    def test_embedding_keeps_the_gif(self):
        result = self.run_yt_dlp('--embed-thumbnail')
        # ffmpeg can't put a thumbnail in a GIF, so yt-dlp still ends with an error, as for any
        # file type that can't hold one; but the GIF itself is now there.
        self.assertIn('Supported filetypes for thumbnail embedding', result.stderr)
        self.assertIn('Sample.gif', self.outputs(), result.stdout + result.stderr)
        self.assertIsTheGif('Sample.gif')
        self.assertNotIn('YTDLPGUIThumbnailNaming', result.stdout)

    def test_writing_keeps_both(self):
        result = self.run_yt_dlp('--write-thumbnail')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.outputs(), ['Sample.gif', 'Sample.thumbnail.gif'])
        self.assertIsTheGif('Sample.gif')
        self.assertEqual(support.read(os.path.join(self.output, 'Sample.thumbnail.gif')),
                         support.read(support.fixture('thumbnail.jpg')))

    def test_nothing_changes_without_thumbnails(self):
        result = self.run_yt_dlp()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.outputs(), ['Sample.gif'])
        self.assertIsTheGif('Sample.gif')
