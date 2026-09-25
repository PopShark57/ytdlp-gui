"""The `analyze` command."""

import json
import threading
import time
import unittest

from tests import support

APP = support.install_fake_app()


def setUpModule():
    support.configure_engine()


def file_url(path):
    return 'file://' + path


@support.requires_ffmpeg
class AnalyzeTests(unittest.TestCase):

    def analyze(self, argv, job_id=None):
        job_id = job_id or support.new_job_id()
        return job_id, support.call('analyze', {'job_id': job_id, 'argv': argv})

    def test_local_clip(self):
        clip = support.fixture('clip.mp4')
        job_id, result = self.analyze([
            '--dump-single-json', '--no-warnings', '--no-progress', '--color', 'never',
            '--flat-playlist', '--no-playlist', '--enable-file-urls', '--', file_url(clip)])
        self.assertEqual(result['ok'], True, result)
        info = result['info']
        self.assertEqual(info['id'], 'clip')
        self.assertEqual(info['title'], 'clip')
        self.assertEqual(info['extractor'], 'generic')
        self.assertEqual(info['webpage_url'], file_url(clip))
        self.assertEqual(info['_type'], 'video')
        self.assertTrue(info['formats'])
        # The same document `yt-dlp --dump-single-json` prints: plain JSON all the way down.
        self.assertEqual(json.loads(json.dumps(info)), info)
        self.assertIn('[generic] Extracting URL: ' + file_url(clip), APP.log(job_id))

    def test_log_events_are_sent_while_it_runs(self):
        clip = support.fixture('clip.mp4')
        job_id, result = self.analyze(['--enable-file-urls', '--', file_url(clip)])
        self.assertTrue(result['ok'])
        levels = {event['level'] for event in APP.events(job_id, 'log')}
        self.assertLessEqual(levels, {'info', 'debug', 'warning'})
        self.assertTrue(APP.log(job_id))

    def test_failure_reports_the_last_error_and_the_log(self):
        with support.LocalServer({}) as server:
            job_id, result = self.analyze(['--', server.url('/missing.mp4')])
        self.assertEqual(result['ok'], False)
        self.assertEqual(result['cancelled'], False)
        self.assertIn('HTTP Error 404', result['error'])
        self.assertFalse(result['error'].startswith('ERROR:'))
        self.assertEqual(result['log'], APP.log(job_id))
        self.assertTrue(any(line.startswith('ERROR: ') for line in result['log']))

    def test_file_urls_need_permission(self):
        _, result = self.analyze(['--', file_url(support.fixture('clip.mp4'))])
        self.assertEqual(result['ok'], False)
        self.assertIn('file://', result['error'])

    def test_refused_arguments(self):
        _, result = self.analyze(['--exec', 'echo', '--', 'https://example.com/v'])
        self.assertEqual(result['ok'], False)
        self.assertEqual(result['log'], [])
        self.assertEqual(result['cancelled'], False)
        self.assertIn('--exec', result['error'])

    def test_needs_exactly_one_link(self):
        self.assertIn('no link', self.analyze(['--no-playlist'])[1]['error'])
        self.assertIn('exactly one', self.analyze(['--', 'https://a.example/1', 'https://a.example/2'])[1]['error'])

    def test_verbose_output_keeps_passwords_out_of_the_log(self):
        clip = support.fixture('clip.mp4')
        job_id, result = self.analyze([
            '--verbose', '--username', 'me', '--password', 'hunter2', '--enable-file-urls', '--',
            file_url(clip)])
        self.assertTrue(result['ok'], result)
        log = APP.log(job_id)
        self.assertTrue(any(line.startswith('[debug] ') for line in log))
        self.assertFalse(any('hunter2' in line for line in log))

    def test_cancelled_while_extracting(self):
        # The server never answers, so yt-dlp waits without calling back into the host.
        release = threading.Event()

        def never_answer():
            release.wait(10)
            return b''

        job_id = support.new_job_id()
        with support.LocalServer({'/slow': (never_answer, 'text/html')}) as server:
            results = {}
            thread = threading.Thread(target=lambda: results.update(self.analyze(
                ['--socket-timeout', '30', '--', server.url('/slow')], job_id=job_id)[1]))
            thread.start()
            deadline = time.monotonic() + 10
            while not any('Downloading webpage' in line for line in APP.log(job_id)):
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.02)
            time.sleep(0.2)
            support.call('cancel', {'job_id': job_id})
            release.set()
            thread.join(10)
        self.assertFalse(thread.is_alive())
        self.assertEqual(results['ok'], False)
        self.assertEqual(results['cancelled'], True)
        self.assertEqual(results['error'], 'Cancelled.')


if __name__ == '__main__':
    unittest.main()
