"""A yt-dlp post-processor plugin the Mac app loads into every download.

The app copies this file into `yt_dlp_plugins/postprocessor/` under its own plugin folder
(Application Support/YTDLPGUI/yt-dlp-plugins) and runs yt-dlp with that folder in
`--plugin-dirs` and `--use-postprocessor YTDLPGUIThumbnailNaming:when=video`. It relies only on
yt-dlp's public post-processor interface, so it works with any yt-dlp that has `--plugin-dirs`
(2024.10.22 and later).

The iOS app's embedded engine does the same with `ThumbnailNamingPP` in
PythonHost/ytdlpgui_host/jobs.py; keep the two in step.
"""

from yt_dlp.postprocessor.common import PostProcessor
from yt_dlp.utils import determine_ext


class YTDLPGUIThumbnailNamingPP(PostProcessor):
    """Runs at `video`, just before yt-dlp names the files, and keeps thumbnails off the video's name.

    yt-dlp names a thumbnail after the video with the thumbnail's own extension, so a GIF whose
    preview URL also ends in ".gif" (as on Reddit GIF posts) gets a thumbnail with exactly the
    video's name. The thumbnail is written first, so the download is then skipped as "already
    downloaded", and --embed-thumbnail finally deletes that file as a thumbnail nobody asked
    to keep: the download succeeds with nothing on disk. Such a thumbnail becomes
    "<name>.thumbnail.<ext>" instead, as --write-all-thumbnails puts the ID in front of the
    extension.
    """

    def run(self, info):
        thumbnails = info.get('thumbnails') or ()
        write_all = self.get_param('write_all_thumbnails')
        if not (write_all or self.get_param('writethumbnail')) or (write_all and len(thumbnails) > 1):
            # None are written, or all are, as "<name>.<id>.<ext>".
            return [], info
        media_exts = {str(ext).lower() for ext in (info.get('ext'), self.get_param('final_ext')) if ext}
        for thumbnail in thumbnails:
            # The extension yt-dlp's _write_thumbnails will use. Compared without case because
            # the Mac's file system usually ignores it.
            ext = thumbnail.get('ext') or determine_ext(thumbnail.get('url'), 'jpg')
            if ext.lower() in media_exts:
                thumbnail['ext'] = f'thumbnail.{ext}'
        return [], info

    def _hook_progress(self, status, info_dict):
        # Not a step the person asked for, so the app shouldn't show it as a processing stage.
        pass
