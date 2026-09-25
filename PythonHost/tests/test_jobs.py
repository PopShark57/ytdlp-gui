"""Jobs: log formatting, progress throttling, hooks, and cancellation."""

import threading
import time
import unittest
from unittest import mock

from tests import support


def setUpModule():
    support.configure_engine()


from ytdlpgui_host import jobs  # noqa: E402

APP = support.install_fake_app()


def new_job():
    return jobs.Job(support.new_job_id())


class LoggerTests(unittest.TestCase):

    def setUp(self):
        self.job = new_job()

    def logged(self):
        return [(event['level'], event['message']) for event in APP.events(self.job.id, 'log')]

    def test_screen_output_is_info_and_debug_is_debug(self):
        logger = jobs.JobLogger(self.job)
        logger.debug('[youtube] abc: Downloading webpage')
        logger.debug('[debug] Invoking http downloader')
        logger.info('[info] plain info')
        self.assertEqual(self.logged(), [
            ('info', '[youtube] abc: Downloading webpage'),
            ('debug', '[debug] Invoking http downloader'),
            ('info', '[info] plain info'),
        ])

    def test_warnings_and_errors_are_prefixed_like_the_command_line(self):
        logger = jobs.JobLogger(self.job)
        logger.warning('Falling back to generic n function search')
        logger.error('ERROR: [generic] Unable to download webpage')
        self.assertEqual(self.logged(), [
            ('warning', 'WARNING: Falling back to generic n function search'),
            ('error', 'ERROR: [generic] Unable to download webpage'),
        ])

    def test_multi_line_messages_become_one_event_per_line(self):
        logger = jobs.JobLogger(self.job)
        logger.warning('first line\n         second line\r\nthird line\n\n')
        logger.debug('\r[download] Got error: timed out')
        self.assertEqual(self.logged(), [
            ('warning', 'WARNING: first line'),
            ('warning', '         second line'),
            ('warning', 'third line'),
            ('info', '[download] Got error: timed out'),
        ])

    def test_terminal_sequences_are_removed(self):
        logger = jobs.JobLogger(self.job)
        logger.error('\x1b[0;31mERROR:\x1b[0m something \x1b]0;title\x07failed')
        self.assertEqual(self.logged(), [('error', 'ERROR: something failed')])

    def test_no_warnings(self):
        jobs.JobLogger(self.job, show_warnings=False).warning('hidden')
        self.assertEqual(self.logged(), [])
        jobs.JobLogger(self.job, show_warnings=False, verbose=True).warning('shown in verbose mode')
        self.assertEqual(self.logged(), [('debug', '[debug] WARNING: shown in verbose mode')])

    def test_deprecated_features_are_sent_once(self):
        logger = jobs.JobLogger(self.job)
        # What YoutubeDL.deprecated_feature does with a logger: both calls, same text.
        logger.warning('Deprecated Feature: old option')
        logger.error('Deprecated Feature: old option')
        self.assertEqual(self.logged(), [('warning', 'Deprecated Feature: old option')])

    def test_standard_output(self):
        jobs.JobLogger(self.job).stdout('ID  EXT  RESOLUTION\n18  mp4  640x360')
        self.assertEqual(self.logged(), [('info', 'ID  EXT  RESOLUTION'), ('info', '18  mp4  640x360')])

    def test_kept_lines_and_last_error(self):
        logger = jobs.JobLogger(self.job, keep_lines=True)
        logger.error('ERROR: first problem')
        logger.debug('[info] something else')
        logger.error('ERROR: [generic] second problem\n   with detail')
        self.assertEqual(logger.lines, [
            'ERROR: first problem', '[info] something else', 'ERROR: [generic] second problem',
            '   with detail'])
        self.assertEqual(jobs.last_error(logger.lines), '[generic] second problem')
        self.assertIsNone(jobs.last_error(['[info] fine']))

    def test_every_call_checks_for_cancellation(self):
        logger = jobs.JobLogger(self.job)
        self.job.cancel()
        for method in (logger.debug, logger.info, logger.warning, logger.error, logger.stdout):
            with self.subTest(method=method.__name__), self.assertRaises(jobs.JobCancelled):
                method('anything')
        self.assertEqual(self.logged(), [])


class HookTests(unittest.TestCase):

    def setUp(self):
        self.job = new_job()

    def progress(self):
        return APP.events(self.job.id, 'progress')

    def test_progress_event_fields(self):
        self.job.report_progress({
            'status': 'downloading', 'downloaded_bytes': 1024, 'total_bytes': None,
            'total_bytes_estimate': 4096.0, 'speed': float('inf'), 'eta': 3, 'elapsed': 0.5,
            'filename': '/tmp/video.mp4', 'tmpfilename': '/tmp/video.mp4.part', 'info_dict': {'id': 'x'},
        })
        self.assertEqual(self.progress(), [{
            'type': 'progress', 'status': 'downloading', 'downloaded_bytes': 1024,
            'total_bytes': None, 'total_bytes_estimate': 4096.0, 'speed': None, 'eta': 3,
            'elapsed': 0.5, 'fragment_index': None, 'fragment_count': None,
            'filename': '/tmp/video.mp4',
        }])

    def test_downloading_updates_are_throttled_but_not_finished_or_error(self):
        for index in range(50):
            self.job.report_progress({'status': 'downloading', 'downloaded_bytes': index})
        self.job.report_progress({'status': 'finished', 'downloaded_bytes': 50})
        self.job.report_progress({'status': 'downloading', 'downloaded_bytes': 0})
        self.job.report_progress({'status': 'error', 'downloaded_bytes': 1})
        self.job.report_progress({'status': 'error', 'downloaded_bytes': 1})
        self.assertEqual(
            [(event['status'], event['downloaded_bytes']) for event in self.progress()],
            [('downloading', 0), ('finished', 50), ('downloading', 0), ('error', 1), ('error', 1)])

    def test_throttle_allows_five_updates_a_second(self):
        # Twenty updates 110 ms apart, over 2.09 s: every other one is sent.
        ticks = iter(range(20))
        with mock.patch('time.monotonic', lambda: 1000 + next(ticks) * 0.11):
            for _ in range(20):
                self.job.report_progress({'status': 'downloading'})
        self.assertEqual(len(self.progress()), 10)

    def test_progress_from_many_threads_is_still_throttled(self):
        barrier = threading.Barrier(8)

        def report():
            barrier.wait()
            for _ in range(20):
                self.job.report_progress({'status': 'downloading'})

        with mock.patch('time.monotonic', lambda: 1000.0):
            threads = [threading.Thread(target=report) for _ in range(8)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
        self.assertEqual(len(self.progress()), 1)

    def test_postprocess_event(self):
        self.job.report_postprocessing({
            'status': 'started', 'postprocessor': 'Merger',
            'info_dict': {'filepath': '/tmp/video.mp4', 'id': 'x'}})
        self.assertEqual(APP.events(self.job.id, 'postprocess'), [{
            'type': 'postprocess', 'status': 'started', 'postprocessor': 'Merger',
            'filepath': '/tmp/video.mp4'}])

    def test_hooks_check_for_cancellation(self):
        self.job.cancel()
        with self.assertRaises(jobs.JobCancelled):
            self.job.report_progress({'status': 'finished'})
        with self.assertRaises(jobs.JobCancelled):
            self.job.report_postprocessing({'status': 'started', 'info_dict': {}})
        self.assertEqual(APP.events(self.job.id), [])


class CancellationTests(unittest.TestCase):

    def test_job_cancelled_needs_no_arguments(self):
        from yt_dlp.utils import DownloadCancelled

        error = jobs.JobCancelled()
        self.assertIsInstance(error, DownloadCancelled)
        self.assertEqual(str(error), 'Cancelled')

    def test_interrupts_python_code_that_never_calls_back(self):
        job_id = support.new_job_id()
        started, outcome = threading.Event(), {}

        def busy():
            started.set()
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                pass
            return 'finished'

        def worker():
            with jobs.registered(job_id) as job:
                try:
                    outcome['result'] = job.run(busy)
                except jobs.JobCancelled:
                    outcome['result'] = 'cancelled'

        thread = threading.Thread(target=worker)
        thread.start()
        self.assertTrue(started.wait(5))
        began = time.monotonic()
        self.assertEqual(support.call('cancel', {'job_id': job_id}), {'ok': True, 'found': True})
        thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(outcome['result'], 'cancelled')
        self.assertLess(time.monotonic() - began, 2)

    def test_cancelling_a_finished_job_is_harmless(self):
        job_id = support.new_job_id()
        with jobs.registered(job_id) as job:
            self.assertEqual(job.run(lambda: 42), 42)
        self.assertFalse(jobs.cancel(job_id))
        # The thread carries on unharmed: no exception is waiting for it.
        for _ in range(1000):
            sum(range(10))

    def test_no_interrupt_reaches_a_job_after_run_returns(self):
        # Cancel repeatedly while jobs finish, so some cancellations land right at the end.
        for _ in range(30):
            job = new_job()
            stop = threading.Event()

            def cancel_soon():
                time.sleep(0.001)
                job.cancel()
                stop.set()

            canceller = threading.Thread(target=cancel_soon)
            canceller.start()
            try:
                job.run(lambda: [sum(range(500)) for _ in range(200)])
            except jobs.JobCancelled:
                pass
            canceller.join()
            # Anything still pending would be raised by these calls.
            for _ in range(1000):
                sum(range(10))

    def test_cancel_before_the_job_starts(self):
        job_id = support.new_job_id()
        self.assertEqual(support.call('cancel', {'job_id': job_id}), {'ok': True, 'found': False})
        with jobs.registered(job_id) as job:
            self.assertTrue(job.cancel_requested)
            with self.assertRaises(jobs.JobCancelled):
                job.run(lambda: 'never runs')

    def test_job_ids_are_unique_while_running(self):
        job_id = support.new_job_id()
        with jobs.registered(job_id):
            with self.assertRaises(jobs.JobConflictError):
                with jobs.registered(job_id):
                    pass
        with jobs.registered(job_id):
            pass


if __name__ == '__main__':
    unittest.main()
