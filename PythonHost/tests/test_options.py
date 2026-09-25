"""Argument parsing, the safety checks, and the engine plumbing added to every job."""

import os
import unittest
from unittest import mock

from tests import support


def setUpModule():
    support.configure_engine()


from ytdlpgui_host import compat, options  # noqa: E402

URL = 'https://example.com/video'


class ParsingTests(unittest.TestCase):

    def test_parses_like_the_command_line_tool(self):
        parsed = options.parse([
            '--format', 'bv*+ba/b', '--merge-output-format', 'mp4', '--paths', '/tmp/out',
            '--output', '%(title)s.%(ext)s', '--no-mtime', '--', URL])
        self.assertEqual(parsed.urls, [URL])
        self.assertEqual(parsed.params['format'], 'bv*+ba/b')
        self.assertEqual(parsed.params['merge_output_format'], 'mp4')
        self.assertEqual(parsed.params['paths'], {'home': '/tmp/out'})
        self.assertEqual(parsed.params['outtmpl']['default'], '%(title)s.%(ext)s')
        self.assertFalse(parsed.params['updatetime'])

    def test_extract_audio_becomes_a_postprocessor(self):
        parsed = options.parse(['-x', '--audio-format', 'm4a', '--audio-quality', '5', '--', URL])
        extract = [pp for pp in parsed.params['postprocessors'] if pp['key'] == 'FFmpegExtractAudio']
        self.assertEqual(extract, [{
            'key': 'FFmpegExtractAudio', 'preferredcodec': 'm4a', 'preferredquality': '5',
            'nopostoverwrites': False}])

    def test_arguments_must_be_a_list_of_strings(self):
        for argv in (None, 'yt-dlp URL', ['--', 3]):
            with self.subTest(argv=argv), self.assertRaises(options.ArgumentError):
                options.parse(argv)

    def test_unknown_option(self):
        with self.assertRaises(options.ArgumentError) as context:
            options.parse(['--no-such-option', URL])
        self.assertEqual(str(context.exception), 'yt-dlp rejected the arguments: no such option: --no-such-option')

    def test_invalid_value(self):
        with self.assertRaises(options.ArgumentError) as context:
            options.parse(['--merge-output-format', 'exe', URL])
        self.assertIn('merge output format', str(context.exception))

    def test_help_and_version(self):
        for argument in ('--help', '-h', '--version'):
            with self.subTest(argument=argument), self.assertRaises(options.ArgumentError) as context:
                options.parse([argument])
            self.assertIn('--help and --version', str(context.exception))


class SafetyTests(unittest.TestCase):
    """Everything that would run a program, read configuration or plugins, replace yt-dlp or
    wait for a terminal is refused, whichever spelling reaches the parser."""

    def assertRefused(self, argv, fragment):
        with self.assertRaises(options.ArgumentError) as context:
            options.parse([*argv, '--', URL])
        self.assertIn(fragment, str(context.exception))

    def test_exec(self):
        self.assertRefused(['--exec', 'echo {}'], '--exec')
        self.assertRefused(['--exec', 'before_dl:echo hi'], '--exec')
        self.assertRefused(['--exec-before-download', 'echo hi'], '--exec')

    def test_exec_through_use_postprocessor(self):
        self.assertRefused(['--use-postprocessor', 'Exec:exec_cmd=echo'], '--exec')

    def test_exec_through_an_alias(self):
        self.assertRefused(['--alias', 'harmless', '--exec echo', '--harmless'], '--exec')

    def test_external_downloader(self):
        self.assertRefused(['--downloader', 'aria2c'], '--downloader aria2c')
        self.assertRefused(['--external-downloader', 'm3u8:ffmpeg'], '--downloader ffmpeg')

    def test_native_downloader_is_allowed(self):
        options.parse(['--downloader', 'native', '--', URL])

    def test_netrc_command(self):
        self.assertRefused(['--netrc-cmd', 'cat secrets'], '--netrc-cmd')

    def test_updates(self):
        for argv in (['-U'], ['--update'], ['--update-to', 'nightly']):
            with self.subTest(argv=argv):
                self.assertRefused(argv, 'update')
        options.parse(['--no-update', '--', URL])

    def test_browser_cookies(self):
        self.assertRefused(['--cookies-from-browser', 'safari'], '--cookies-from-browser')

    def test_plugin_directories(self):
        self.assertRefused(['--plugin-dirs', '/tmp/plugins'], '--plugin-dirs')
        options.parse(['--no-plugin-dirs', '--', URL])

    def test_config_locations_are_refused_before_anything_is_read(self):
        with mock.patch('yt_dlp.utils._utils.Config.read_file') as read_file:
            self.assertRefused(['--config-locations', '/etc/passwd'], '--config-locations')
            self.assertRefused(['--config-location', '-'], '--config-locations')
        read_file.assert_not_called()

    def test_bidi_workaround(self):
        self.assertRefused(['--bidi-workaround'], '--bidi-workaround')

    def test_standard_input_and_prompts(self):
        self.assertRefused(['--batch-file', '-'], 'no terminal')
        self.assertRefused(['--load-info-json', '-'], 'no terminal')
        self.assertRefused(['-f', '-'], 'no terminal')
        self.assertRefused(['--match-filters', '-'], 'no terminal')
        self.assertRefused(['--break-match-filters', '-'], 'no terminal')
        self.assertRefused(['-o', '-'], 'standard output')

    def test_password_prompts(self):
        with mock.patch('getpass.getpass') as getpass:
            self.assertRefused(['--username', 'me'], '--password')
            self.assertRefused(['--ap-mso', 'Comcast_SSO', '--ap-username', 'me'], '--ap-password')
        getpass.assert_not_called()
        options.parse(['--username', 'me', '--password', 'secret', '--', URL])

    def test_compat_options_that_change_global_state(self):
        from yt_dlp.utils import FormatSorter
        from yt_dlp.utils._utils import _UnsafeExtensionError

        default_sort = FormatSorter.default
        self.assertRefused(['--compat-options', 'allow-unsafe-ext'], 'allow-unsafe-ext')
        self.assertRefused(['--compat-options', '2023'], 'prefer-vp9-sort')
        self.assertTrue(_UnsafeExtensionError._enabled)
        self.assertIs(FormatSorter.default, default_sort)
        options.parse(['--compat-options', 'no-youtube-unavailable-videos', '--', URL])


class PlumbingTests(unittest.TestCase):

    def plumbed(self, argv, **overrides):
        arguments = dict(logger=object(), progress_hook=print, postprocessor_hook=repr,
                         cache_dir='/cache', for_analysis=False)
        arguments.update(overrides)
        return options.engine_params(options.parse([*argv, '--', URL]), **arguments)

    def test_adds_the_engine_plumbing(self):
        logger = object()
        params = self.plumbed([], logger=logger)
        self.assertIs(params['logger'], logger)
        self.assertEqual(params['progress_hooks'], [print])
        self.assertEqual(params['postprocessor_hooks'], [repr])
        self.assertTrue(params['noprogress'])
        self.assertTrue(params['no_color'])
        self.assertNotIn('color', params)
        self.assertEqual(params['cachedir'], '/cache')
        self.assertEqual(params['js_runtimes'], {'jsc': {}})
        self.assertFalse(params['warn_when_outdated'])

    def test_does_not_modify_the_parsed_parameters(self):
        parsed = options.parse(['--', URL])
        options.engine_params(parsed, logger=None, progress_hook=print, postprocessor_hook=print,
                              cache_dir='/cache', for_analysis=True)
        self.assertNotIn('logger', parsed.params)

    def test_js_runtime_arguments_are_replaced(self):
        params = self.plumbed(['--no-js-runtimes', '--js-runtimes', 'node'])
        self.assertEqual(params['js_runtimes'], {'jsc': {}})

    def test_explicit_cache_settings_win(self):
        self.assertEqual(self.plumbed(['--cache-dir', '/elsewhere'])['cachedir'], '/elsewhere')
        self.assertIs(self.plumbed(['--no-cache-dir'])['cachedir'], False)

    def test_analysis_keeps_playlist_entries(self):
        self.assertIn(self.plumbed([])['extract_flat'], ('discard', 'discard_in_playlist'))
        self.assertIs(self.plumbed([], for_analysis=True)['extract_flat'], False)
        self.assertEqual(self.plumbed(['--flat-playlist'], for_analysis=True)['extract_flat'], 'in_playlist')

    def test_native_hls_on_ios(self):
        self.assertIsNone(self.plumbed([]).get('hls_prefer_native'))
        with mock.patch.dict(os.environ, {compat.SIMULATE_IOS_ENVIRONMENT_VARIABLE: '1'}):
            self.assertTrue(self.plumbed([])['hls_prefer_native'])
            self.assertFalse(self.plumbed(['--hls-prefer-ffmpeg'])['hls_prefer_native'])


if __name__ == '__main__':
    unittest.main()
