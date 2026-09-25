"""The `jsc` runtime and the JavaScriptCore challenge provider."""

import json
import os
import unittest

from tests import support

APP = support.install_fake_app()

LIVE_TESTS = os.environ.get('YTDLPGUI_LIVE_TESTS') == '1'


def setUpModule():
    support.configure_engine()


class JavaScriptCoreProviderTests(unittest.TestCase):

    def setUp(self):
        from ytdlpgui_host import jobs, options

        self.job_id = support.new_job_id()
        registration = jobs.registered(self.job_id)
        self.job = registration.__enter__()
        self.addCleanup(registration.__exit__, None, None, None)
        parsed = options.parse(['--', 'https://www.youtube.com/watch?v=jNQXAC9IVRw'])
        params = options.engine_params(
            parsed, logger=jobs.JobLogger(self.job), progress_hook=self.job.report_progress,
            postprocessor_hook=self.job.report_postprocessing, cache_dir=None, for_analysis=True)
        self.ydl = jobs.EngineYoutubeDL(params, self.job)
        self.addCleanup(self.ydl.close)

    def director(self):
        from yt_dlp.extractor.youtube.jsc._director import initialize_jsc_director

        return initialize_jsc_director(self.ydl.get_info_extractor('Youtube'))

    @staticmethod
    def n_request(*challenges):
        from yt_dlp.extractor.youtube.jsc.provider import JsChallengeRequest, JsChallengeType, NChallengeInput

        return JsChallengeRequest(
            type=JsChallengeType.N, video_id='jNQXAC9IVRw',
            input=NChallengeInput(player_url='https://www.youtube.com/s/player/abc/base.js',
                                  challenges=list(challenges)))

    def test_runtime_is_registered_and_launches_nothing(self):
        from yt_dlp.globals import supported_js_runtimes
        from ytdlpgui_host import javascript

        self.assertIs(supported_js_runtimes.value['jsc'], javascript.JavaScriptCoreRuntime)
        info = self.ydl._js_runtimes['jsc'].info
        self.assertEqual((info.name, info.path, info.version, info.version_tuple, info.supported),
                         ('jsc', 'JavaScriptCore', '18.0', (18, 0), True))
        self.assertEqual(set(self.ydl._js_runtimes), {'jsc'})

    def test_provider_is_registered_and_chosen_first(self):
        from yt_dlp.extractor.youtube.jsc._registry import _jsc_providers
        from ytdlpgui_host import javascript

        self.assertIs(_jsc_providers.value['JavaScriptCore'], javascript.JavaScriptCoreJCP)
        providers = list(self.director()._get_providers([self.n_request('abc')]))
        self.assertEqual([provider.PROVIDER_NAME for provider in providers], ['javascriptcore'])

    def test_solving_sends_the_solver_to_the_app(self):
        import yt_dlp_ejs.yt.solver

        director = self.director()
        provider = next(iter(director._get_providers([self.n_request('abc')])))
        provider._get_player = lambda video_id, player_url: 'var player = "stand-in";'
        answer = {'type': 'result', 'responses': [{'type': 'result', 'data': {'abc': 'xyz'}}]}
        with APP.answering('js.run', lambda request: {'ok': True, 'stdout': json.dumps(answer)}):
            [(request, response)] = director.bulk_solve([self.n_request('abc')])

        self.assertEqual(response.output.results, {'abc': 'xyz'})
        [sent] = APP.requests(self.job_id, 'js.run')
        self.assertEqual(sent['timeout'], 60)
        # The solver scripts come from the yt-dlp-ejs package, as bundled in the app.
        self.assertIn(yt_dlp_ejs.yt.solver.lib(), sent['script'])
        self.assertIn(yt_dlp_ejs.yt.solver.core(), sent['script'])
        self.assertIn('var player = \\"stand-in\\";', sent['script'])
        self.assertTrue(any('Solving JS challenges using jsc' in line for line in APP.log(self.job_id)))

    def test_app_errors_are_provider_errors(self):
        from yt_dlp.extractor.youtube.jsc.provider import JsChallengeProviderError

        provider = next(iter(self.director()._get_providers([self.n_request('abc')])))
        with APP.answering('js.run', lambda request: {'ok': False, 'error': 'SyntaxError: Unexpected token'}):
            with self.assertRaises(JsChallengeProviderError) as context:
                provider._run_js_runtime('console.log(')
        self.assertIn('SyntaxError: Unexpected token', str(context.exception))

    @support.requires_node
    def test_the_real_solver_runs(self):
        # Without a real player the solver stops with its own complaint about the player's
        # structure: proof that the library and the solver were sent, and ran, in one piece.
        from yt_dlp.extractor.youtube.jsc.provider import JsChallengeProviderError

        provider = next(iter(self.director()._get_providers([self.n_request('abc')])))
        script = provider._construct_stdin('var nothing = 1;', False, [self.n_request('abc')])
        with self.assertRaises(JsChallengeProviderError) as context:
            provider._run_js_runtime(script)
        self.assertIn('unexpected structure', str(context.exception))


@unittest.skipUnless(LIVE_TESTS, 'set YTDLPGUI_LIVE_TESTS=1 to analyse a real YouTube video')
@support.requires_node
class LiveYouTubeTests(unittest.TestCase):

    def test_metadata_of_a_real_video(self):
        # yt-dlp's default clients may get every format without a challenge (as they did in
        # September 2026 for this video), so the web_embedded client, whose stream URLs always
        # carry an "n" challenge, is asked for explicitly.
        job_id = support.new_job_id()
        result = support.call('analyze', {'job_id': job_id, 'argv': [
            '--no-warnings', '--no-playlist', '--extractor-args', 'youtube:player_client=web_embedded',
            '--', 'https://www.youtube.com/watch?v=jNQXAC9IVRw']})
        log = APP.log(job_id)
        self.assertTrue(result['ok'], result.get('error'))
        info = result['info']
        self.assertEqual(info['id'], 'jNQXAC9IVRw')
        self.assertTrue(any('Solving JS challenges using jsc' in line for line in log), log)
        with_urls = [fmt for fmt in info['formats'] if fmt.get('url', '').startswith('https://')]
        self.assertTrue(with_urls)
        self.assertTrue(APP.requests(job_id, 'js.run'))
        print(f'\n{len(info["formats"])} formats, {len(with_urls)} with URLs; log:', *log, sep='\n  ')


if __name__ == '__main__':
    unittest.main()
