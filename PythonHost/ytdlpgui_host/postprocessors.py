"""yt-dlp's ffmpeg post-processors, redone with the app's AVFoundation media requests.

Each class here subclasses the yt-dlp original, so option handling, file naming, `--keep-video`,
`--no-post-overwrites` and hooks behave exactly as on the desktop, and replaces only the part
that would have run ffmpeg or ffprobe with a `media.*` request to the app (the requests are
documented in Docs/iOS-Architecture.md). They keep the originals' names ("Merger",
"ExtractAudio", …) in logs, hooks and --postprocessor-args.

When the app answers `{"ok": false, "unsupported": true}` — AVFoundation can't read WebM, Ogg
or Matroska, for instance — the post-processor warns and keeps the original file: an
unconvertible file is still a successful download. Any other failure raises
`PostProcessingError`, as an ffmpeg failure would.
"""

import os
import sys
import time

from yt_dlp import globals as yt_dlp_globals
from yt_dlp.postprocessor import embedthumbnail, ffmpeg, modify_chapters
from yt_dlp.postprocessor.common import PostProcessor
from yt_dlp.postprocessor.ffmpeg import resolve_mapping
from yt_dlp.utils import (
    PostProcessingError,
    float_or_none,
    prepend_extension,
    replace_extension,
)

from . import bridge, jobs

#: Containers the app can write when merging, by the extension yt-dlp chose.
_MERGE_CONTAINERS = {'mp4': 'mp4', 'm4v': 'mp4', 'mov': 'mov', 'm4a': 'm4a'}

#: Extensions of the MPEG-4 file family, which AVFoundation reads and writes.
_MP4_FAMILY = frozenset({'mp4', 'm4a', 'm4v', 'm4b', 'mov'})

#: Audio formats with no encoder on iPhone and iPad, by --audio-format value.
_UNAVAILABLE_AUDIO_FORMATS = {'mp3': 'MP3', 'opus': 'Opus', 'vorbis': 'Vorbis'}

#: Four-character codes AVFoundation reports for AAC audio.
_AAC_CODECS = frozenset({'mp4a', 'aac', 'aac ', 'aach', 'aacl', 'aacp'})


class MediaUnsupported(PostProcessingError):
    """The app can't process this file at all (it answered `unsupported`)."""


class _AppMediaMixin:
    """What every replacement shares: the request channel, and ffprobe's jobs done by the app.

    Listed before the yt-dlp class in each replacement's bases, so its methods win.
    """

    #: The yt-dlp class this one stands in for.
    replaces = None

    @classmethod
    def pp_key(cls):
        return cls.replaces.pp_key()

    @property
    def available(self):
        return True

    def _media(self, operation, info=None, **fields):
        """Sends `media.<operation>` to the app and returns its answer.

        Raises `MediaUnsupported` when the app can't handle the file, and `PostProcessingError`
        for any other failure.
        """
        job = jobs.job_of(self._downloader)
        if job is None:
            raise PostProcessingError(
                f'{self.pp_key()} can only run inside the app, which does the media processing.')
        if info is not None:
            self._hook_progress({'status': 'processing'}, self._copy_infodict(info))
        answer = bridge.request(job.id, {'op': f'media.{operation}', **fields})
        job.check_cancelled()
        if answer.get('ok'):
            return answer
        message = str(answer.get('error') or f'The app couldn\'t carry out media.{operation}.')
        if answer.get('unsupported'):
            raise MediaUnsupported(message)
        raise PostProcessingError(message)

    def _probe(self, path):
        answer = self._media('probe', path=path)
        return {
            'duration': float_or_none(answer.get('duration')),
            'tracks': [track for track in answer.get('tracks') or () if isinstance(track, dict)],
            'readable': bool(answer.get('readable')),
        }

    def _get_real_video_duration(self, filepath, fatal=True):
        # Used by `_fixup_chapters` and ModifyChaptersPP; the original asks ffprobe.
        try:
            probe = self._probe(filepath)
            if not probe['readable']:
                raise MediaUnsupported(f'"{filepath}" can\'t be opened on iPhone and iPad')
            if not probe['duration']:
                raise PostProcessingError('the file reports no duration')
            return probe['duration']
        except MediaUnsupported:
            raise
        except PostProcessingError as error:
            if fatal:
                raise PostProcessingError(f'Unable to determine video duration: {error.msg}')
            return None


def _audio_codec(probe):
    codec = next((track.get('codec') for track in probe['tracks'] if track.get('kind') == 'audio'), None)
    return str(codec).strip().lower() if codec else None


def _extension(path):
    return os.path.splitext(path)[1][1:].lower()


# MARK: - Merging

class MergerPP(_AppMediaMixin, ffmpeg.FFmpegMergerPP):
    """Merges separately downloaded video and audio into one file, without re-encoding."""

    replaces = ffmpeg.FFmpegMergerPP

    @PostProcessor._restrict_to(images=False)
    def run(self, info):
        filename = info['filepath']
        inputs = self._inputs_video_first(info)
        container = _MERGE_CONTAINERS.get(info['ext'])
        if container is None:
            return self._keep_separate(
                info, inputs, f"a .{info['ext']} file can't be written on iPhone and iPad")

        temp_filename = prepend_extension(filename, 'temp')
        self.to_screen(f'Merging formats into "{filename}"')
        try:
            self._media('merge', info, inputs=inputs, output=temp_filename, container=container)
        except MediaUnsupported as error:
            return self._keep_separate(info, inputs, str(error))
        os.replace(temp_filename, filename)
        # As the original: returning the parts makes yt-dlp delete them unless -k was given.
        return info['__files_to_merge'], info

    @staticmethod
    def _inputs_video_first(info):
        # The app takes the video from the first input and the audio from the others, while
        # ffmpeg is told explicitly which stream to take from where. A selector such as
        # "ba+bv" lists the audio first, so the video-bearing inputs are moved to the front.
        files = list(info['__files_to_merge'])
        formats = info.get('requested_formats') or ()
        if len(formats) != len(files):
            return files
        has_video = [fmt.get('vcodec') != 'none' for fmt in formats]
        return ([path for path, video in zip(files, has_video) if video]
                + [path for path, video in zip(files, has_video) if not video])

    def _keep_separate(self, info, inputs, reason):
        self.report_warning(
            f"The video and audio couldn't be merged ({reason}), so they were kept as separate files.")
        main, *others = inputs
        info['filepath'] = main
        info['ext'] = _extension(main) or info['ext']
        for path in others:
            # Moved to the final folder under its own name, like the main file.
            info['__files_to_move'].setdefault(path, '')
        info[jobs.KEPT_FILES_KEY] = [*info.get(jobs.KEPT_FILES_KEY, ()), *others]
        return [], info


# MARK: - Audio

class ExtractAudioPP(_AppMediaMixin, ffmpeg.FFmpegExtractAudioPP):
    """--extract-audio: rewraps or converts the audio, as the original does with ffmpeg.

    The app can copy AAC and ALAC into M4A, and encode AAC, ALAC, FLAC and WAV. There is no
    MP3, Opus or Vorbis encoder on iPhone and iPad.
    """

    replaces = ffmpeg.FFmpegExtractAudioPP

    @PostProcessor._restrict_to(images=False)
    def run(self, information):
        orig_path = path = information['filepath']
        source_ext = information['ext']
        target_format, _skip_msg = resolve_mapping(source_ext, self.mapping)
        if target_format == 'best' and source_ext in self.COMMON_AUDIO_EXTS:
            target_format, _skip_msg = None, 'the file is already in a common audio format'
        if not target_format:
            self.to_screen(f'Not converting audio {orig_path}; {_skip_msg}')
            return [], information
        if target_format in _UNAVAILABLE_AUDIO_FORMATS:
            raise PostProcessingError(
                f"{_UNAVAILABLE_AUDIO_FORMATS[target_format]} audio isn't available on iPhone and "
                'iPad; choose M4A')

        probe = self._probe(path)
        if not probe['readable']:
            self.report_warning(
                f'Kept "{path}" as it is: its audio can\'t be read on iPhone and iPad, so it '
                "couldn't be converted.")
            return [], information
        codec = _audio_codec(probe)
        if codec is None:
            raise PostProcessingError(f'"{path}" has no audio to extract')

        request = self._codec_request(target_format, codec, source_ext)
        if request is None:
            self.report_warning(
                f'Kept "{path}" as it is: its {codec} audio can only be kept by converting it. '
                'Choose M4A to convert it.')
            return [], information
        codec_request, extension = request

        temp_path = new_path = replace_extension(path, extension, source_ext)
        if new_path == path:
            if self._is_codec(codec, target_format):
                self.to_screen(f'Not converting audio {orig_path}; file is already in target format {target_format}')
                return [], information
            orig_path = prepend_extension(path, 'orig')
            temp_path = prepend_extension(path, 'temp')
        if (self._nopostoverwrites and os.path.exists(new_path)
                and os.path.exists(orig_path)):
            self.to_screen(f'Post-process file {new_path} exists, skipping')
            return [], information

        self.to_screen(f'Destination: {new_path}')
        try:
            answer = self._media(
                'extract_audio', information, input=path, output=temp_path, codec=codec_request,
                bitrate=self._bitrate() if codec_request == 'aac' else None)
        except MediaUnsupported as error:
            self.report_warning(f'Kept "{path}" as it is: {error}.')
            return [], information

        written = answer.get('output') or temp_path
        if not os.path.exists(written):
            raise PostProcessingError(f'audio conversion failed: the app didn\'t write "{written}"')
        if _extension(written) != _extension(temp_path):
            # The codec demanded another container; name the final file after what was written.
            extension = _extension(written)
            new_path = replace_extension(new_path, extension)

        os.replace(path, orig_path)
        os.replace(written, new_path)
        information['filepath'] = new_path
        information['ext'] = extension

        if information.get('filetime') is not None:
            self.try_utime(
                new_path, time.time(), information['filetime'], errnote='Cannot update utime of audio file')

        return [orig_path], information

    @staticmethod
    def _codec_request(target_format, codec, source_ext):
        """What to ask the app for: (codec, extension), or None to keep the file as it is."""
        is_aac, is_alac = codec in _AAC_CODECS, codec == 'alac'
        if target_format == 'best':
            # "Best" never re-encodes: AAC and ALAC are rewrapped, anything else is kept.
            if (is_aac or is_alac) and source_ext in _MP4_FAMILY:
                return 'copy', 'm4a'
            return None
        if target_format in ('m4a', 'aac'):
            return ('copy' if is_aac else 'aac'), 'm4a'
        if target_format == 'alac':
            return ('copy' if is_alac else 'alac'), 'm4a'
        if target_format == 'flac':
            return 'flac', 'flac'
        if target_format == 'wav':
            return 'wav', 'wav'
        return None

    @staticmethod
    def _is_codec(codec, target_format):
        """Whether the audio already is what `target_format` asks for."""
        if target_format in ('m4a', 'aac', 'best'):
            return codec in _AAC_CODECS
        return codec == {'alac': 'alac', 'flac': 'flac', 'wav': 'lpcm'}.get(target_format)

    def _bitrate(self):
        """--audio-quality as bits per second: 0 (best) to 10 (worst) or a bitrate in kbps."""
        quality = self._preferredquality
        if quality is None:
            return None
        if quality > 10:
            return int(quality * 1000)
        # The VBR scale maps linearly from 256 kbps at 0 to 64 kbps at 10, in 8 kbps steps.
        kbps = 256 - (256 - 64) * max(quality, 0) / 10
        return int(round(kbps / 8) * 8 * 1000)


# MARK: - Tags, chapters and artwork

class MetadataPP(_AppMediaMixin, ffmpeg.FFmpegMetadataPP):
    """--embed-metadata and --embed-chapters."""

    replaces = ffmpeg.FFmpegMetadataPP

    #: The tags the app writes; the rest of what yt-dlp would give ffmpeg has no MP4 atom.
    _APP_TAGS = ('title', 'artist', 'album', 'album_artist', 'date', 'comment', 'description',
                 'genre', 'track', 'purl')

    @PostProcessor._restrict_to(images=False)
    def run(self, info):
        self._fixup_chapters(info)
        filename = info['filepath']
        chapters = self._app_chapters(info) if self._add_chapters else None
        metadata = self._app_metadata(info) if self._add_metadata else None
        if self._add_infojson is True:
            self.to_screen('The info-json can only be attached to mkv/mka files')

        if not chapters and not metadata:
            self.to_screen('There isn\'t any metadata to add')
            return [], info

        self.to_screen(f'Adding metadata to "{filename}"')
        try:
            self._media('embed', info, path=filename, metadata=metadata, artwork=None, chapters=chapters)
        except MediaUnsupported as error:
            self.report_warning(f'Kept "{filename}" without the metadata: {error}.')
        return [], info

    def _app_metadata(self, info):
        # The original's own field mapping (title from track/title, artist from
        # artist/uploader, purl and comment from webpage_url, meta_* overrides, …), read back
        # from the ffmpeg options it builds.
        tags = {}
        for option, value in self._get_metadata_opts(info):
            if option != '-metadata':
                continue
            name, _, text = value.partition('=')
            if name in self._APP_TAGS and text:
                tags[name] = text
        return tags or None

    @staticmethod
    def _app_chapters(info):
        chapters = []
        for chapter in info.get('chapters') or ():
            start = float_or_none(chapter.get('start_time'))
            end = float_or_none(chapter.get('end_time'))
            if start is None or end is None:
                continue
            chapters.append({'start': start, 'end': end, 'title': str(chapter.get('title') or '')})
        return chapters or None


class EmbedThumbnailPP(_AppMediaMixin, embedthumbnail.EmbedThumbnailPP):
    """--embed-thumbnail, for the MPEG-4 family: the only files AVFoundation can tag."""

    replaces = embedthumbnail.EmbedThumbnailPP

    @PostProcessor._restrict_to(images=False)
    def run(self, info):
        filename = info['filepath']

        if not info.get('thumbnails'):
            self.to_screen('There aren\'t any thumbnails to embed')
            return [], info

        idx = next((-i for i, t in enumerate(info['thumbnails'][::-1], 1) if t.get('filepath')), None)
        if idx is None:
            self.to_screen('There are no thumbnails on disk')
            return [], info
        thumbnail_filename = info['thumbnails'][idx]['filepath']
        if not os.path.exists(thumbnail_filename):
            self.report_warning('Skipping embedding the thumbnail because the file is missing.')
            return [], info

        convertor = ThumbnailsConvertorPP(self._downloader)
        convertor.fixup_webp(info, idx)
        original_thumbnail = thumbnail_filename = info['thumbnails'][idx]['filepath']

        if info['ext'] not in _MP4_FAMILY:
            self.report_warning(
                f"The thumbnail can't be embedded in a .{info['ext']} file on iPhone and iPad, so "
                'it was left out.')
            return self._finish(info, original_thumbnail, thumbnail_filename)

        try:
            # PNG, as the original prefers: the conversion is lossless.
            if _extension(thumbnail_filename) not in ('jpg', 'jpeg', 'png'):
                thumbnail_filename = convertor.convert_thumbnail(thumbnail_filename, 'png')
            mtime = os.stat(filename).st_mtime
            self.to_screen(f'Adding thumbnail to "{filename}"')
            self._media('embed', info, path=filename, metadata=None, artwork=thumbnail_filename, chapters=None)
            self.try_utime(filename, mtime, mtime)
        except MediaUnsupported as error:
            self.report_warning(f'Kept "{filename}" without the thumbnail: {error}.')
        return self._finish(info, original_thumbnail, thumbnail_filename)

    def _finish(self, info, original_thumbnail, thumbnail_filename):
        # The original's clean-up: thumbnails the person didn't ask to keep are removed.
        converted = original_thumbnail != thumbnail_filename
        self._delete_downloaded_files(
            thumbnail_filename if converted or not self._already_have_thumbnail else None,
            original_thumbnail if converted and not self._already_have_thumbnail else None,
            info=info)
        return [], info


class ThumbnailsConvertorPP(_AppMediaMixin, ffmpeg.FFmpegThumbnailsConvertorPP):
    """--convert-thumbnails, and the conversions EmbedThumbnailPP needs."""

    replaces = ffmpeg.FFmpegThumbnailsConvertorPP

    _APP_IMAGE_FORMATS = {'jpg': 'jpg', 'jpeg': 'jpg', 'png': 'png'}

    def convert_thumbnail(self, thumbnail_filename, target_ext):
        image_format = self._APP_IMAGE_FORMATS.get(target_ext)
        if image_format is None:
            raise MediaUnsupported(f"images can't be converted to {target_ext} on iPhone and iPad")
        thumbnail_conv_filename = replace_extension(thumbnail_filename, target_ext)
        self.to_screen(f'Converting thumbnail "{thumbnail_filename}" to {target_ext}')
        self._media('convert_image', input=thumbnail_filename, output=thumbnail_conv_filename, format=image_format)
        return thumbnail_conv_filename

    def run(self, info):
        # The original's loop, except that a thumbnail the app can't convert is kept as it is
        # instead of failing the download.
        files_to_delete = []
        has_thumbnail = False

        for idx, thumbnail_dict in enumerate(info.get('thumbnails') or []):
            original_thumbnail = thumbnail_dict.get('filepath')
            if not original_thumbnail:
                continue
            has_thumbnail = True
            self.fixup_webp(info, idx)
            original_thumbnail = thumbnail_dict['filepath']  # Path can change during fixup
            thumbnail_ext = _extension(original_thumbnail)
            if thumbnail_ext == 'jpeg':
                thumbnail_ext = 'jpg'
            target_ext, _skip_msg = resolve_mapping(thumbnail_ext, self.mapping)
            if _skip_msg:
                self.to_screen(f'Not converting thumbnail "{original_thumbnail}"; {_skip_msg}')
                continue
            try:
                thumbnail_dict['filepath'] = self.convert_thumbnail(original_thumbnail, target_ext)
            except MediaUnsupported as error:
                self.report_warning(f'Kept the thumbnail "{original_thumbnail}" as it is: {error}.')
                continue
            files_to_delete.append(original_thumbnail)
            info['__files_to_move'][thumbnail_dict['filepath']] = replace_extension(
                info['__files_to_move'][original_thumbnail], target_ext)

        if not has_thumbnail:
            self.to_screen('There aren\'t any thumbnails to convert')
        return files_to_delete, info


# MARK: - Cutting

class ModifyChaptersPP(_AppMediaMixin, modify_chapters.ModifyChaptersPP):
    """--sponsorblock-remove and --remove-chapters.

    The original works out which ranges to cut and how the chapters and duration change; only
    the cutting itself (ffmpeg's concat demuxer) becomes a `media.remove_ranges` request.
    """

    replaces = modify_chapters.ModifyChaptersPP

    def run(self, info):
        chapters, duration = info.get('chapters'), info.get('duration')
        try:
            return _without_hooks(modify_chapters.ModifyChaptersPP.run)(self, info)
        except MediaUnsupported as error:
            # Nothing was cut, so the chapters and duration still describe the file.
            info['chapters'], info['duration'] = chapters, duration
            self.report_warning(f'Kept "{info["filepath"]}" uncut: {error}.')
            return [], info

    def remove_chapters(self, filename, ranges_to_cut, concat_opts, force_keyframes=False):
        if force_keyframes:
            self.report_warning(
                '--force-keyframes-at-cuts isn\'t available on iPhone and iPad; the video is cut '
                'without re-encoding.', only_once=True)
        out_file = prepend_extension(filename, 'temp')
        ranges = [[float(cut['start_time']), float(cut['end_time'])] for cut in ranges_to_cut]
        if any(end == float('inf') for _, end in ranges):
            duration = self._get_real_video_duration(filename)
            ranges = [[start, min(end, duration)] for start, end in ranges]
        self.to_screen(f'Removing chapters from {filename}')
        self._media('remove_ranges', input=filename, output=out_file, ranges=ranges)
        return out_file

    def _get_supported_subs(self, info):
        for sub in (info.get('requested_subtitles') or {}).values():
            sub_file = sub.get('filepath')
            if sub_file and os.path.exists(sub_file):
                self.report_warning(
                    f'Cannot remove chapters from external {sub["ext"]} subtitles; "{sub_file}" is now out of sync')
        return iter(())


# MARK: - Fix-ups

class FixupM4aPP(_AppMediaMixin, ffmpeg.FFmpegFixupM4aPP):
    """Rewrites YouTube's fragmented "DASH m4a" audio as an ordinary M4A.

    yt-dlp runs this after every download of a DASH audio stream. Without it every audio
    download warns about a missing ffmpeg, and some players stumble over the fragmented file.
    """

    replaces = ffmpeg.FFmpegFixupM4aPP

    @PostProcessor._restrict_to(images=False, video=False)
    def run(self, info):
        if info.get('container') != 'm4a_dash':
            return [], info
        path = info['filepath']
        temporary = prepend_extension(path, 'temp')
        self.to_screen(f'Correcting container of "{path}"')
        try:
            answer = self._media('extract_audio', info, input=path, output=temporary, codec='copy', bitrate=None)
        except MediaUnsupported as error:
            self.report_warning(f'Kept the DASH m4a container: {error.msg}')
            return [], info
        written = answer.get('output') or temporary
        os.replace(written, path)
        return [], info


def _without_hooks(run):
    # PostProcessorMetaClass wraps every `run` so it reports "started" and "finished". This
    # class's own `run` is wrapped already, so calling the original's wrapped one would report
    # both twice; functools.wraps leaves the unwrapped function in `__wrapped__`.
    return getattr(run, '__wrapped__', run)


# MARK: - Installation

REPLACEMENTS = (MergerPP, ExtractAudioPP, MetadataPP, EmbedThumbnailPP, ThumbnailsConvertorPP, ModifyChaptersPP)
# Fix-ups YoutubeDL creates directly from its own module's namespace.
DIRECT_REPLACEMENTS = (MergerPP, FixupM4aPP)


def install():
    """Puts the replacements where yt-dlp looks post-processors up. Called once."""
    table = yt_dlp_globals.postprocessors.value
    for replacement in REPLACEMENTS:
        # Keyed like the originals: YoutubeDL looks up `key + 'PP'` for each --option's
        # post-processor, e.g. 'FFmpegExtractAudio' → 'FFmpegExtractAudioPP'.
        table[replacement.replaces.__name__] = replacement
    # YoutubeDL creates its merger and fix-ups directly, from its own module's namespace. (The package
    # attribute `yt_dlp.YoutubeDL` is the class, not the module, so it is looked up here.)
    module = sys.modules['yt_dlp.YoutubeDL']
    for replacement in DIRECT_REPLACEMENTS:
        setattr(module, replacement.replaces.__name__, replacement)
