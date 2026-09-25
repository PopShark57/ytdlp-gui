"""`dispatch` never raises, and every failure is an `{"ok": false}` object."""

import json
import math
import sys
import unittest
from unittest import mock

from tests import support

import ytdlpgui_host
from ytdlpgui_host import bridge, engine


def setUpModule():
    support.configure_engine()


class DispatchErrorTests(unittest.TestCase):

    def dispatch(self, command, payload_json):
        text = ytdlpgui_host.dispatch(command, payload_json)
        self.assertIsInstance(text, str)
        return json.loads(text)

    def test_unknown_command(self):
        result = self.dispatch('explode', '{}')
        self.assertEqual(result['ok'], False)
        self.assertIn('explode', result['error'])

    def test_command_that_is_not_text(self):
        result = self.dispatch(None, '{}')
        self.assertEqual(result['ok'], False)

    def test_payload_that_is_not_json(self):
        result = self.dispatch('download', '{"job_id": ')
        self.assertEqual(result, {'ok': False, 'error': 'The engine was sent unreadable data for "download".'})

    def test_payload_that_is_not_an_object(self):
        result = self.dispatch('download', '[1, 2]')
        self.assertEqual(result['ok'], False)
        self.assertIn('unreadable', result['error'])

    def test_empty_payload_counts_as_empty_object(self):
        result = self.dispatch('version', '')
        self.assertEqual(result['ok'], True)

    def test_unexpected_exception_is_reported_with_a_traceback(self):
        with mock.patch.dict(ytdlpgui_host._COMMANDS, {'version': mock.Mock(side_effect=ZeroDivisionError('boom'))}):
            result = self.dispatch('version', '{}')
        self.assertEqual(result['ok'], False)
        self.assertIn('boom', result['error'])
        self.assertIn('ZeroDivisionError', result['traceback'])

    def test_base_exceptions_do_not_escape(self):
        with mock.patch.dict(ytdlpgui_host._COMMANDS, {'version': mock.Mock(side_effect=SystemExit(3))}):
            result = self.dispatch('version', '{}')
        self.assertEqual(result['ok'], False)

    def test_download_without_job_id(self):
        result = self.dispatch('download', json.dumps({'argv': ['--', 'https://example.com']}))
        self.assertEqual(result['ok'], False)
        self.assertIn('ID', result['error'])

    def test_cancel_of_unknown_job(self):
        result = self.dispatch('cancel', json.dumps({'job_id': support.new_job_id()}))
        self.assertEqual(result, {'ok': True, 'found': False})

    def test_cancel_without_job_id(self):
        self.assertEqual(self.dispatch('cancel', '{}')['ok'], False)


class ConfigureTests(unittest.TestCase):

    def test_configure_reports_versions(self):
        result = support.configure_engine()
        self.assertEqual(result['ok'], True)
        self.assertEqual(result['python'].split('.')[:2], ['3', '14'])
        self.assertEqual(result['yt_dlp_source'], 'bundled')
        self.assertIsNone(result['update_error'])
        import yt_dlp.version
        self.assertEqual(result['yt_dlp'], yt_dlp.version.__version__)
        self.assertTrue(result['ejs'])
        self.assertTrue(result['certifi'])

    def test_version_matches_configure(self):
        self.assertEqual(support.call('version', {}), support.configure_engine())

    def test_configure_sets_the_certificate_bundle(self):
        import certifi
        import os
        self.assertEqual(os.environ.get('SSL_CERT_FILE'), certifi.where())

    def test_commands_before_configure(self):
        with mock.patch.object(engine, '_settings', None):
            self.assertEqual(support.call('version', {})['ok'], False)
            download = support.call('download', {'job_id': 'x', 'argv': ['--', 'https://example.com']})
            self.assertEqual(download['ok'], False)
            self.assertIn("hasn't been started", download['error'])
            analysis = support.call('analyze', {'job_id': 'x', 'argv': ['--', 'https://example.com']})
            self.assertEqual(analysis, {
                'ok': False, 'error': download['error'], 'log': [], 'cancelled': False})
            self.assertEqual(support.call('cancel', {'job_id': 'x'}), {'ok': True, 'found': False})

    def test_configure_rejects_a_path_that_is_not_text(self):
        with mock.patch.object(engine, '_settings', None):
            result = support.call('configure', {'cache_dir': 3})
        self.assertEqual(result['ok'], False)


class BridgeTests(unittest.TestCase):

    def test_json_never_contains_nan_or_infinity(self):
        text = bridge.dumps({'speed': math.inf, 'eta': math.nan, 'list': [1.5, -math.inf]})
        self.assertEqual(json.loads(text), {'speed': None, 'eta': None, 'list': [1.5, None]})

    def test_json_replaces_lone_surrogates(self):
        text = bridge.dumps({'path': 'caf\udce9.mp4'})
        text.encode('utf-8')
        self.assertEqual(json.loads(text)['path'], 'caf?.mp4')

    def test_missing_module_is_a_clear_error(self):
        with mock.patch.dict(sys.modules, {'_ytdlpgui': None}):
            with self.assertRaises(bridge.BridgeUnavailableError) as context:
                bridge.emit('job', {'type': 'log'})
        self.assertIn('_ytdlpgui', str(context.exception))

    def test_unreadable_answer_becomes_a_failure(self):
        with mock.patch.object(sys.modules['_ytdlpgui'], 'request', return_value='not json'):
            answer = bridge.request('job', {'op': 'media.probe'})
        self.assertEqual(answer['ok'], False)
        self.assertIn('media.probe', answer['error'])


if __name__ == '__main__':
    unittest.main()
