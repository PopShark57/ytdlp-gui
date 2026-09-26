"""The `download` command, end to end: a local web server, the stand-in app, real files."""

import errno
import glob
import json
import os
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock

from tests import support

APP = support.install_fake_app()

MPD = '''<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT3S"
     minBufferTime="PT1S" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011">
  <Period>
    <AdaptationSet mimeType="video/mp4" contentType="video">
      <Representation id="video" bandwidth="200000" codecs="avc1.4d400c" width="160" height="120">
        <BaseURL>video.mp4</BaseURL>
      </Representation>
    </AdaptationSet>
    <AdaptationSet mimeType="{audio_type}" contentType="audio" lang="en">
      <Representation id="audio" bandwidth="64000" codecs="{audio_codec}" audioSamplingRate="44100">
        <BaseURL>{audio}</BaseURL>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
'''


def setUpModule():
    support.configure_engine()


def media_routes():
    return {
        '/clip.mp4': (support.read(support.fixture('clip.mp4')), 'video/mp4'),
        '/video.mp4': (support.read(support.fixture('video.mp4')), 'video/mp4'),
        '/audio.m4a': (support.read(support.fixture('audio.m4a')), 'audio/mp4'),
        '/audio.webm': (support.read(support.fixture('audio.webm')), 'audio/webm'),
        '/thumbnail.jpg': (support.read(support.fixture('thumbnail.jpg')), 'image/jpeg'),
        '/thumbnail.webp': (support.read(support.fixture('thumbnail.webp')), 'image/webp'),
        '/manifest.mpd': (MPD.format(audio='audio.m4a', audio_type='audio/mp4', audio_codec='mp4a.40.2').encode(),
                          'application/dash+xml'),
        '/webm-audio.mpd': (MPD.format(audio='audio.webm', audio_type='audio/webm', audio_codec='opus').encode(),
                            'application/dash+xml'),
    }


class DownloadTestCase(unittest.TestCase):

    def setUp(self):
        self.output = support.output_dir()
        self.server = support.LocalServer(media_routes()).__enter__()
        self.addCleanup(self.server.__exit__, None, None, None)

    def download(self, argv, url=None, job_id=None):
        job_id = job_id or support.new_job_id()
        arguments = ['--paths', self.output, '--output', '%(title)s.%(ext)s', '--no-mtime', *argv]
        if url is not None:
            arguments += ['--', url]
        result = support.call('download', {'job_id': job_id, 'argv': arguments})
        return job_id, result

    def info_json(self, **fields):
        """An info document for --load-info-json, so a test controls thumbnails, chapters, tags."""
        info = {
            '_type': 'video', 'id': 'sample', 'title': 'Sample', 'ext': 'mp4',
            'url': self.server.url('/clip.mp4'), 'protocol': 'http',
            'vcodec': 'avc1.4d400c', 'acodec': 'mp4a.40.2',
            'extractor': 'generic', 'extractor_key': 'Generic',
            'webpage_url': self.server.url('/clip.mp4'), 'duration': 3,
            'uploader': 'Tester', 'upload_date': '20250102', 'description': 'A test clip',
        }
        info.update(fields)
        path = os.path.join(self.output, f'{support.new_job_id()}.info.json')
        with open(path, 'w', encoding='utf-8') as file:
            json.dump(info, file)
        return path

    def assertSucceeded(self, job_id, result):
        self.assertEqual(result.get('ok'), True, result)
        self.assertEqual(result['exit_code'], 0, APP.log(job_id))
        self.assertFalse(result['cancelled'])
        self.assertFalse([line for line in APP.log(job_id) if line.startswith('ERROR')])

    def outputs(self, pattern='*'):
        return sorted(os.path.basename(path) for path in glob.glob(os.path.join(self.output, pattern)))


@support.requires_ffmpeg
class SingleFileTests(DownloadTestCase):

    def test_single_file_over_http(self):
        job_id, result = self.download([], self.server.url('/clip.mp4'))
        self.assertSucceeded(job_id, result)
        final = os.path.join(self.output, 'clip.mp4')
        self.assertEqual(result['files'], [final])
        self.assertEqual(support.read(final), support.read(support.fixture('clip.mp4')))

        self.assertEqual(APP.events(job_id, 'file'), [{'type': 'file', 'path': final, 'main': True}])
        [item] = APP.events(job_id, 'item')
        self.assertEqual(item['id'], 'clip')
        self.assertEqual(item['title'], 'clip')
        self.assertEqual(item['extractor'], 'generic')
        self.assertEqual(item['webpage_url'], self.server.url('/clip.mp4'))
        self.assertEqual(set(item), {
            'type', 'id', 'title', 'uploader', 'thumbnail', 'duration', 'webpage_url',
            'extractor', 'playlist_index', 'playlist_count'})

        progress = APP.events(job_id, 'progress')
        self.assertEqual(progress[-1]['status'], 'finished')
        self.assertEqual(progress[-1]['downloaded_bytes'], len(support.read(final)))
        self.assertEqual(progress[-1]['filename'], final)
        events = APP.events(job_id)
        self.assertLess(events.index(item), events.index(progress[0]))

    def test_yt_dlp_errors_are_log_lines_and_exit_code_1(self):
        job_id, result = self.download([], self.server.url('/missing.mp4'))
        self.assertEqual(result['ok'], True)
        self.assertEqual(result['exit_code'], 1)
        self.assertFalse(result['cancelled'])
        self.assertEqual(result['files'], [])
        self.assertTrue(any(line.startswith('ERROR: ') and '404' in line for line in APP.log(job_id)))

    def test_host_problems_are_failures(self):
        _, result = self.download(['--exec', 'rm -rf /'], self.server.url('/clip.mp4'))
        self.assertEqual(result['ok'], False)
        self.assertIn('--exec', result['error'])
        _, result = self.download([])
        self.assertEqual(result, {'ok': False, 'error': 'There is no link to download.'})
        _, result = self.download(['-f', 'best[[['], self.server.url('/clip.mp4'))
        self.assertEqual(result['ok'], False)
        self.assertIn("yt-dlp couldn't start", result['error'])

    def test_printed_output_goes_to_the_log(self):
        job_id, result = self.download(['--print', '%(title)s!', '--simulate'], self.server.url('/clip.mp4'))
        self.assertSucceeded(job_id, result)
        self.assertIn('clip!', APP.log(job_id))
        self.assertEqual(self.outputs(), [])


@support.requires_ffmpeg
class MergeTests(DownloadTestCase):

    def test_dash_merge(self):
        job_id, result = self.download(
            ['-f', 'bv+ba', '--merge-output-format', 'mp4'], self.server.url('/manifest.mpd'))
        self.assertSucceeded(job_id, result)
        final = os.path.join(self.output, 'manifest.mp4')
        self.assertEqual(result['files'], [final])
        self.assertEqual(APP.events(job_id, 'file'), [{'type': 'file', 'path': final, 'main': True}])
        self.assertEqual(self.outputs(), ['manifest.mp4'])  # the parts are gone
        self.assertEqual(sorted(support.streams(final)), [('audio', 'aac'), ('video', 'h264')])

        [merge] = APP.requests(job_id, 'media.merge')
        self.assertEqual(merge['container'], 'mp4')
        self.assertEqual(len(merge['inputs']), 2)
        self.assertTrue(merge['inputs'][0].endswith('.fvideo.mp4'), merge['inputs'])
        self.assertTrue(merge['output'].endswith('manifest.temp.mp4'))

        stages = [(event['postprocessor'], event['status']) for event in APP.events(job_id, 'postprocess')]
        self.assertIn(('Merger', 'started'), stages)
        self.assertIn(('Merger', 'processing'), stages)
        self.assertIn(('Merger', 'finished'), stages)
        self.assertTrue(any('[Merger] Merging formats into' in line for line in APP.log(job_id)))

    def test_audio_first_selector_still_puts_the_video_first(self):
        job_id, result = self.download(['-f', 'ba+bv', '--merge-output-format', 'mp4'], self.server.url('/manifest.mpd'))
        self.assertSucceeded(job_id, result)
        [merge] = APP.requests(job_id, 'media.merge')
        self.assertTrue(merge['inputs'][0].endswith('.fvideo.mp4'), merge['inputs'])

    def test_keep_video_keeps_the_parts(self):
        job_id, result = self.download(['-f', 'bv+ba', '--merge-output-format', 'mp4', '-k'], self.server.url('/manifest.mpd'))
        self.assertSucceeded(job_id, result)
        self.assertEqual(self.outputs(), ['manifest.faudio.m4a', 'manifest.fvideo.mp4', 'manifest.mp4'])

    def test_unsupported_inputs_are_kept_as_separate_files(self):
        job_id, result = self.download(['-f', 'bv+ba', '--merge-output-format', 'mp4'], self.server.url('/webm-audio.mpd'))
        self.assertSucceeded(job_id, result)
        self.assertTrue(any(line.startswith('WARNING: The video and audio couldn\'t be merged')
                            for line in APP.log(job_id)))
        self.assertEqual(self.outputs(), ['webm-audio.faudio.webm', 'webm-audio.fvideo.mp4'])
        self.assertEqual(result['files'], [os.path.join(self.output, 'webm-audio.fvideo.mp4'),
                                           os.path.join(self.output, 'webm-audio.faudio.webm')])
        # The app names the video, not the audio kept beside it.
        self.assertEqual(APP.events(job_id, 'file'), [
            {'type': 'file', 'path': os.path.join(self.output, 'webm-audio.fvideo.mp4'), 'main': True},
            {'type': 'file', 'path': os.path.join(self.output, 'webm-audio.faudio.webm'), 'main': False},
        ])

    def test_containers_the_app_cannot_write(self):
        job_id, result = self.download(['-f', 'bv+ba', '--merge-output-format', 'mkv'], self.server.url('/manifest.mpd'))
        self.assertSucceeded(job_id, result)
        self.assertEqual(APP.requests(job_id, 'media.merge'), [])
        self.assertTrue(any("a .mkv file can't be written" in line for line in APP.log(job_id)))
        self.assertEqual(self.outputs(), ['manifest.faudio.m4a', 'manifest.fvideo.mp4'])


@support.requires_ffmpeg
class AudioTests(DownloadTestCase):

    def extract(self, audio_format, *extra, path='/clip.mp4'):
        return self.download(['-x', '--audio-format', audio_format, *extra], self.server.url(path))

    def test_m4a_copies_aac(self):
        job_id, result = self.extract('m4a')
        self.assertSucceeded(job_id, result)
        final = os.path.join(self.output, 'clip.m4a')
        self.assertEqual(result['files'], [final])
        self.assertEqual(self.outputs(), ['clip.m4a'])
        self.assertEqual(support.streams(final), [('audio', 'aac')])
        [probe] = APP.requests(job_id, 'media.probe')
        self.assertTrue(probe['path'].endswith('clip.mp4'))
        [request] = APP.requests(job_id, 'media.extract_audio')
        self.assertEqual((request['codec'], request['bitrate']), ('copy', None))
        self.assertTrue(request['output'].endswith('clip.m4a'))

    def test_flac(self):
        job_id, result = self.extract('flac')
        self.assertSucceeded(job_id, result)
        final = os.path.join(self.output, 'clip.flac')
        self.assertEqual(result['files'], [final])
        self.assertEqual(support.streams(final), [('audio', 'flac')])
        [request] = APP.requests(job_id, 'media.extract_audio')
        self.assertEqual(request['codec'], 'flac')

    def test_alac_and_wav(self):
        for audio_format, codec, extension in (('alac', 'alac', 'm4a'), ('wav', 'pcm_s16le', 'wav')):
            with self.subTest(audio_format=audio_format):
                job_id, result = self.extract(audio_format)
                self.assertSucceeded(job_id, result)
                self.assertEqual(support.streams(os.path.join(self.output, f'clip.{extension}')), [('audio', codec)])

    def test_quality_maps_to_a_bitrate_when_re_encoding(self):
        # An Opus source (as far as the app can tell) has to be re-encoded to AAC.
        with APP.answering('media.probe', lambda request: {
                'ok': True, 'duration': 3.0, 'readable': True, 'tracks': [{'kind': 'audio', 'codec': 'opus'}]}):
            for quality, bitrate in (('0', 256000), ('5', 160000), ('10', 64000), ('128K', 128000), (None, 160000)):
                with self.subTest(quality=quality):
                    job_id, result = self.extract('m4a', *(['--audio-quality', quality] if quality else []))
                    self.assertSucceeded(job_id, result)
                    [request] = APP.requests(job_id, 'media.extract_audio')
                    self.assertEqual((request['codec'], request['bitrate']), ('aac', bitrate))

    def test_best_keeps_common_audio_files(self):
        job_id, result = self.extract('best', path='/audio.m4a')
        self.assertSucceeded(job_id, result)
        self.assertEqual(APP.requests(job_id, 'media.extract_audio'), [])
        self.assertEqual(self.outputs(), ['audio.m4a'])

    def test_best_rewraps_aac_from_a_video(self):
        job_id, result = self.extract('best')
        self.assertSucceeded(job_id, result)
        [request] = APP.requests(job_id, 'media.extract_audio')
        self.assertEqual(request['codec'], 'copy')
        self.assertEqual(self.outputs(), ['clip.m4a'])

    def test_dash_m4a_is_rewrapped_without_an_ffmpeg_warning(self):
        # YouTube's audio streams are fragmented "DASH m4a"; yt-dlp's fix-up needs ffmpeg.
        job_id, result = self.download(['-f', 'ba'], self.server.url('/manifest.mpd'))
        self.assertSucceeded(job_id, result)
        [request] = APP.requests(job_id, 'media.extract_audio')
        self.assertEqual(request['codec'], 'copy')
        self.assertTrue(request['output'].endswith('.temp.m4a'))
        [final] = result['files']
        self.assertEqual(self.outputs(), [os.path.basename(final)])
        self.assertEqual(support.streams(final), [('audio', 'aac')])
        self.assertFalse([line for line in APP.log(job_id) if 'Install ffmpeg' in line], APP.log(job_id))

    def test_unreadable_sources_are_kept_with_a_warning(self):
        job_id, result = self.download(['-f', 'ba', '-x', '--audio-format', 'm4a'], self.server.url('/audio.webm'))
        self.assertSucceeded(job_id, result)
        self.assertEqual(APP.requests(job_id, 'media.extract_audio'), [])
        self.assertTrue(any(line.startswith('WARNING: Kept') for line in APP.log(job_id)))
        self.assertEqual(self.outputs(), ['audio.webm'])

    def test_formats_without_an_encoder_fail_clearly(self):
        job_id, result = self.extract('mp3')
        self.assertEqual(result['exit_code'], 1)
        self.assertIn("ERROR: Postprocessing: MP3 audio isn't available on iPhone and iPad; choose M4A",
                      APP.log(job_id))


@support.requires_ffmpeg
class TaggingTests(DownloadTestCase):

    def test_metadata_and_chapters(self):
        info = self.info_json(chapters=[
            {'start_time': 0, 'end_time': 1, 'title': 'Intro'},
            {'start_time': 1, 'end_time': 3, 'title': 'Main'}])
        job_id, result = self.download(['--load-info-json', info, '--embed-metadata'])
        self.assertSucceeded(job_id, result)
        [request] = APP.requests(job_id, 'media.embed')
        self.assertEqual(request['metadata'], {
            'title': 'Sample', 'artist': 'Tester', 'date': '20250102', 'description': 'A test clip',
            'purl': self.server.url('/clip.mp4'), 'comment': self.server.url('/clip.mp4')})
        self.assertEqual(request['chapters'], [
            {'start': 0.0, 'end': 1.0, 'title': 'Intro'}, {'start': 1.0, 'end': 3.0, 'title': 'Main'}])
        self.assertIsNone(request['artwork'])
        self.assertEqual(support.tags(os.path.join(self.output, 'Sample.mp4'))['title'], 'Sample')

    def test_nothing_to_add(self):
        job_id, result = self.download(['--embed-chapters'], self.server.url('/clip.mp4'))
        self.assertSucceeded(job_id, result)
        self.assertEqual(APP.requests(job_id, 'media.embed'), [])
        self.assertTrue(any("There isn't any metadata to add" in line for line in APP.log(job_id)))

    def test_thumbnail(self):
        info = self.info_json(thumbnails=[{'url': self.server.url('/thumbnail.jpg'), 'id': '0'}])
        job_id, result = self.download(['--load-info-json', info, '--embed-thumbnail'])
        self.assertSucceeded(job_id, result)
        [request] = APP.requests(job_id, 'media.embed')
        self.assertTrue(request['artwork'].endswith('Sample.jpg'))
        self.assertEqual(self.outputs('Sample*'), ['Sample.mp4'])  # the thumbnail wasn't asked for
        self.assertIn(('video', 'mjpeg'), support.streams(os.path.join(self.output, 'Sample.mp4')))

    def test_unsupported_thumbnail_embedding_is_a_warning(self):
        info = self.info_json(thumbnails=[{'url': self.server.url('/thumbnail.jpg'), 'id': '0'}])
        unsupported = {'ok': False, 'unsupported': True, 'error': 'the file can\'t be tagged'}
        with APP.answering('media.embed', lambda request: unsupported):
            job_id, result = self.download(['--load-info-json', info, '--embed-thumbnail', '--write-thumbnail'])
        self.assertSucceeded(job_id, result)
        self.assertIn('WARNING: Kept "{}" without the thumbnail: the file can\'t be tagged.'.format(
            os.path.join(self.output, 'Sample.mp4')), APP.log(job_id))
        self.assertEqual(self.outputs('Sample*'), ['Sample.jpg', 'Sample.mp4'])

    def test_other_embedding_failures_fail_the_download(self):
        info = self.info_json(thumbnails=[{'url': self.server.url('/thumbnail.jpg'), 'id': '0'}])
        with APP.answering('media.embed', lambda request: {'ok': False, 'error': 'disk full'}):
            job_id, result = self.download(['--load-info-json', info, '--embed-thumbnail'])
        self.assertEqual(result['exit_code'], 1)
        self.assertIn('ERROR: Postprocessing: disk full', APP.log(job_id))

    def test_webp_thumbnails_are_converted(self):
        info = self.info_json(thumbnails=[{'url': self.server.url('/thumbnail.webp'), 'id': '0'}])
        job_id, result = self.download(['--load-info-json', info, '--write-thumbnail', '--convert-thumbnails', 'jpg'])
        self.assertSucceeded(job_id, result)
        [request] = APP.requests(job_id, 'media.convert_image')
        self.assertEqual(request['format'], 'jpg')
        self.assertEqual(self.outputs('Sample*'), ['Sample.jpg', 'Sample.mp4'])
        with open(os.path.join(self.output, 'Sample.jpg'), 'rb') as file:
            self.assertEqual(file.read(2), b'\xff\xd8')

    def test_thumbnail_formats_the_app_cannot_write_are_kept(self):
        info = self.info_json(thumbnails=[{'url': self.server.url('/thumbnail.jpg'), 'id': '0'}])
        job_id, result = self.download(['--load-info-json', info, '--write-thumbnail', '--convert-thumbnails', 'webp'])
        self.assertSucceeded(job_id, result)
        self.assertEqual(self.outputs('Sample*'), ['Sample.jpg', 'Sample.mp4'])
        self.assertTrue(any(line.startswith('WARNING: Kept the thumbnail') for line in APP.log(job_id)))

    def test_thumbnails_cannot_go_into_other_containers(self):
        info = self.info_json(ext='webm', url=self.server.url('/audio.webm'), vcodec='none', acodec='opus',
                              thumbnails=[{'url': self.server.url('/thumbnail.jpg'), 'id': '0'}])
        job_id, result = self.download(['--load-info-json', info, '--embed-thumbnail'])
        self.assertSucceeded(job_id, result)
        self.assertEqual(APP.requests(job_id, 'media.embed'), [])
        self.assertTrue(any("can't be embedded in a .webm file" in line for line in APP.log(job_id)))
        self.assertEqual(self.outputs('Sample*'), ['Sample.webm'])


@support.requires_ffmpeg
class CuttingTests(DownloadTestCase):

    CHAPTERS = [{'start_time': 0, 'end_time': 1, 'title': 'Intro'},
                {'start_time': 1, 'end_time': 3, 'title': 'Main'}]

    def test_removed_ranges_and_chapters(self):
        info = self.info_json(chapters=self.CHAPTERS)
        job_id, result = self.download(['--load-info-json', info, '--remove-chapters', 'Intro', '--embed-chapters'])
        self.assertSucceeded(job_id, result)
        [cut] = APP.requests(job_id, 'media.remove_ranges')
        self.assertEqual(cut['ranges'], [[0.0, 1.0]])
        self.assertTrue(cut['output'].endswith('Sample.temp.mp4'))
        [embed] = APP.requests(job_id, 'media.embed')
        self.assertEqual(embed['chapters'], [{'start': 0.0, 'end': 2.0, 'title': 'Main'}])
        self.assertEqual(self.outputs('Sample*'), ['Sample.mp4'])

    def test_unsupported_cut_keeps_the_file_and_its_chapters(self):
        info = self.info_json(chapters=self.CHAPTERS)
        unsupported = {'ok': False, 'unsupported': True, 'error': 'the file can\'t be cut'}
        with APP.answering('media.remove_ranges', lambda request: unsupported):
            job_id, result = self.download(['--load-info-json', info, '--remove-chapters', 'Intro', '--embed-chapters'])
        self.assertSucceeded(job_id, result)
        self.assertTrue(any(line.startswith('WARNING: Kept') and 'uncut' in line for line in APP.log(job_id)))
        [embed] = APP.requests(job_id, 'media.embed')
        self.assertEqual([chapter['title'] for chapter in embed['chapters']], ['Intro', 'Main'])
        stages = [(event['postprocessor'], event['status']) for event in APP.events(job_id, 'postprocess')]
        self.assertEqual(stages.count(('ModifyChapters', 'started')), 1)


@support.requires_ffmpeg
class CancellationTests(DownloadTestCase):

    def test_cancel_mid_download(self):
        data = support.read(support.fixture('clip.mp4')) * 200
        self.server.routes['/slow.mp4'] = (data, 'video/mp4', 0.01)
        job_id = support.new_job_id()
        downloading = threading.Event()

        def listener(event_job, event):
            if event_job == job_id and event.get('type') == 'progress' and event.get('downloaded_bytes'):
                downloading.set()

        results = {}
        with APP.listening(listener):
            thread = threading.Thread(target=lambda: results.update(result=self.download(
                ['--buffer-size', '16K', '--no-resize-buffer'], self.server.url('/slow.mp4'), job_id=job_id)[1]))
            thread.start()
            self.assertTrue(downloading.wait(10))
            cancelled_at = time.monotonic()
            self.assertEqual(support.call('cancel', {'job_id': job_id}), {'ok': True, 'found': True})
            thread.join(10)
        self.assertFalse(thread.is_alive())
        self.assertLess(time.monotonic() - cancelled_at, 3)

        result = results['result']
        self.assertEqual(result, {'ok': True, 'exit_code': 101, 'cancelled': True, 'files': []})
        self.assertEqual(self.outputs('*.part'), ['slow.mp4.part'])  # kept, so a retry resumes
        self.assertFalse(os.path.exists(os.path.join(self.output, 'slow.mp4')))
        self.assertEqual(support.call('cancel', {'job_id': job_id}), {'ok': True, 'found': False})


@support.requires_ffmpeg
class SimulatedIOSTests(DownloadTestCase):
    """With iOS simulated, nothing the host does may try to start a program."""

    def setUp(self):
        super().setUp()
        self.attempts = []
        launch = subprocess.Popen.__init__

        def guarded_launch(popen, args, *remaining, **kwargs):
            if support.spawning_allowed():  # the stand-in app's own ffmpeg work
                return launch(popen, args, *remaining, **kwargs)
            self.attempts.append((args, _calling_module()))
            raise OSError(errno.ENOTSUP, 'ios does not support processes.')

        def refuse(*args, **kwargs):
            self.attempts.append(args)
            raise OSError(errno.ENOTSUP, 'ios does not support processes.')

        for patcher in (
                mock.patch.dict(os.environ, {'YTDLPGUI_HOST_SIMULATE_IOS': '1'}),
                mock.patch.object(subprocess.Popen, '__init__', guarded_launch),
                mock.patch.object(os, 'system', refuse),
                mock.patch.object(os, 'posix_spawn', refuse),
                mock.patch.object(os, 'posix_spawnp', refuse),
                mock.patch.object(os, 'fork', refuse)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_audio_extraction_launches_nothing(self):
        job_id, result = self.download(['-x', '--audio-format', 'm4a', '--embed-metadata'],
                                       self.server.url('/clip.mp4'))
        self.assertSucceeded(job_id, result)
        self.assertEqual(self.attempts, [])
        self.assertEqual(self.outputs(), ['clip.m4a'])

    def test_verbose_output_probes_no_programs(self):
        job_id, result = self.download(['--verbose'], self.server.url('/clip.mp4'))
        self.assertSucceeded(job_id, result)
        # The verbose header lists the programs yt-dlp looked for: ffmpeg, ffprobe, rtmpdump,
        # phantomjs and the JavaScript runtimes. None was launched, and none was found.
        self.assertIn('[debug] exe versions: none', APP.log(job_id))
        self.assertIn('[debug] JS runtimes: jsc-18.0', APP.log(job_id))
        # Only the standard library's `platform` module tries, to describe the system, and
        # falls back quietly, as it does on iOS.
        self.assertEqual({module for _, module in self.attempts} - {'platform'}, set())

    def test_merging_launches_nothing(self):
        job_id, result = self.download(['-f', 'bv+ba', '--merge-output-format', 'mp4'], self.server.url('/manifest.mpd'))
        self.assertSucceeded(job_id, result)
        self.assertEqual(self.attempts, [])
        self.assertEqual(self.outputs(), ['manifest.mp4'])

    def test_ffmpeg_only_features_report_unavailable(self):
        job_id, result = self.download(['--remux-video', 'mkv'], self.server.url('/clip.mp4'))
        self.assertEqual(self.attempts, [])
        self.assertEqual(result['exit_code'], 1)
        self.assertTrue(any('ffmpeg' in line for line in APP.log(job_id) if line.startswith('ERROR')))

    def test_direct_program_launches_are_refused_with_a_clear_error(self):
        from yt_dlp.utils import Popen, check_executable

        self.assertFalse(check_executable('ffmpeg', ['-version']))
        with self.assertRaises(OSError) as context:
            Popen(['ffmpeg', '-version'])
        self.assertIn("ffmpeg can't be run", str(context.exception))
        self.assertEqual(self.attempts, [])


def _calling_module():
    frame = sys._getframe(2)
    while frame is not None and frame.f_globals.get('__name__') == 'subprocess':
        frame = frame.f_back
    return frame.f_globals.get('__name__') if frame is not None else None


if __name__ == '__main__':
    unittest.main()
