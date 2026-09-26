# YTDLP GUI for iOS — architecture

The iOS app is the same product as the macOS app — paste a link, pick a quality, download —
rebuilt around one hard constraint: **an iOS app cannot launch another program.** The macOS app
drives a separately installed `yt-dlp` executable with `Process`; on iPhone and iPad there is
no `Process`, no Homebrew and no ffmpeg. So the iOS app carries its own engine:

| Concern | macOS app | iOS app |
|---|---|---|
| Running yt-dlp | `Process` + the user's install | CPython 3.14 embedded in the app, yt-dlp imported in-process |
| Progress | parsed from `--progress-template` output | yt-dlp progress / post-processor hooks, delivered as JSON events |
| Merging, audio conversion, tagging | ffmpeg | AVFoundation, Core Audio and ImageIO |
| YouTube JavaScript challenges | deno / node / … found on `PATH` | JavaScriptCore |
| Cookies | `--cookies-from-browser` | an imported `cookies.txt` (`--cookies`) |
| Output | any folder | the app's Documents folder, visible in the Files app |
| Updating yt-dlp | `brew upgrade` / `yt-dlp -U` | a verified wheel from PyPI, installed into Application Support |

Everything that does not depend on those differences lives in `Shared/` and is compiled into
both apps: the option model, argument building, progress parsing, failure classification,
media-info decoding, history persistence and formatting.

## Repository layout

```
Shared/                      Platform-neutral Swift, compiled into both apps
YTDLPGUI/                    macOS app
YTDLPGUI-iOS/                iOS app
├── App/                     Entry point, AppModel (composition root), URL handling, intents
├── Engine/
│   ├── Runtime/             C bridge to CPython, YTDLPEngine, request routing
│   ├── JavaScript/          JavaScriptCore runner for yt-dlp's challenge solver
│   └── Media/               AVFoundation replacements for ffmpeg
├── ViewModels/              DownloadQueue, DownloadComposer, EngineController
├── Services/                Settings, notifications, Photos, storage, cookies, background work
└── Views/                   SwiftUI, grouped by screen
YTDLPGUI-iOS-Share/          Share extension: hands links to the app through an App Group
YTDLPGUI-iOSTests/           iOS unit and integration tests
YTDLPGUI-iOSUITests/         UI walkthrough (live tests only)
PythonHost/ytdlpgui_host/    The Python side of the engine (bundled into the app)
PythonHost/tests/            Its tests, run on the Mac with the desktop Python
Tools/fetch-ios-dependencies.sh   Downloads + verifies the Python runtime and wheels into Vendor/
Tools/install-ios-python.sh       Xcode build phase: installs them into the app bundle
Vendor/                      (git-ignored) Python.xcframework and python-packages/
```

## The app bundle

```
YTDLPGUI-iOS.app/
├── python/lib/python3.14/        standard library (test suites and Tk removed)
├── app/ytdlpgui_host/            engine host
├── app_packages/                 yt_dlp, yt_dlp_ejs, certifi
└── Frameworks/
    ├── Python.framework
    └── <module>.framework        every binary extension module, repackaged (iOS will not
                                  load a bare .so), with a .fwork placeholder left behind
```

## App data on device

| Path | Contents |
|---|---|
| `Documents/` | Finished downloads. Shown in Files › On My iPhone › YTDLP GUI. |
| `Library/Caches/Partial Downloads/` | In-progress files (`--paths temp:`). Moved into Documents when finished. |
| `Library/Caches/python-bytecode/` | Compiled byte code (`pycache_prefix`); the bundle is read-only. |
| `Library/Caches/yt-dlp/` | yt-dlp's own cache (`cachedir`). |
| `Library/Application Support/YTDLPGUI/history.json` | Download history (shared `HistoryStore`). Saved without credentials. |
| `Library/Application Support/YTDLPGUI/queue.json` | Unfinished downloads, with their full options. Excluded from backups. |
| `Library/Application Support/Engine/yt-dlp/versions/<name>/` | Installed yt-dlp updates (`yt_dlp/`, `yt_dlp_ejs/`), one folder each. |
| `Library/Application Support/Engine/yt-dlp/current` | The name of the update folder to use. No file means the bundled yt-dlp. |
| `Library/Application Support/Engine/staging/` | Scratch space while an update is installed. |
| `Library/Application Support/Cookies/cookies.txt` | The imported cookies file, if any. |
| `Library/Application Support/download-archive.txt` | The download archive. |
| App Group `group.io.github.ytdlpgui.YTDLPGUI` `/Inbox/` | Links handed over by the Share extension. |

The container path changes when iOS updates or reinstalls the app, so no absolute path is
trusted across launches: option paths are re-resolved when a download is queued, and history
entries whose absolute path has gone stale are re-rooted under the current Documents folder.

Passwords, two-factor codes, proxy credentials and authorisation headers can be given in the
custom arguments and the proxy field. They reach yt-dlp unchanged, but:

- the command preview and each download's log show them as `PRIVATE`
  (`ShellQuoting.redactingSecrets`, which follows yt-dlp's own `Config.hide_login_info`);
- history entries and the last-used options (`UserDefaults`) are saved without them
  (`DownloadOptions.removingSecrets`). A history entry records which options lost something
  (`removedSecretOptions`), so *Download Again* and *Edit Options and Download* can say so;
- `queue.json` keeps them, so interrupted downloads can resume, and is excluded from backups.

## Runtime and threading

`PythonBridge.c` is the only code that touches the Python C API. It:

- initialises an isolated interpreter (`utf8_mode`, no signal handlers, stdout/stderr to the
  unified log, byte code cached outside the bundle), then puts `app/` and `app_packages/` at the
  front of `sys.path` and releases the GIL;
- registers a built-in module, `_ytdlpgui`, through which Python reaches the app:
  - `emit(job_id, event_json)` — deliver an event (non-blocking for Python);
  - `request(job_id, request_json) -> str` — ask the app to do something and wait for the answer;
  - `interrupt(thread_ident, exception_type)` — raise an exception in another Python thread;
- exposes `ytg_call(command, payload_json) -> json`, which calls `ytdlpgui_host.dispatch`.

Swift calls `ytg_call` from a **dedicated `Thread` per job**, never from Swift concurrency's
cooperative pool: a download blocks its thread for as long as it runs. yt-dlp releases the GIL
during network and file I/O, so concurrent downloads overlap. Both callbacks run on the calling
Python thread with the GIL released; `request` blocks that thread (a semaphore around the async
Swift work), which is safe because it is never a cooperative-pool thread.

## Host protocol

Everything crossing the bridge is a UTF-8 JSON object. `dispatch` never raises: failures come
back as `{"ok": false, "error": "…", "traceback": "…"}`.

### Commands (Swift → Python, via `ytg_call`)

| Command | Payload | Result |
|---|---|---|
| `configure` | `{"cache_dir", "update_dir": str\|null, "platform_version"}` | `{"ok", "python", "yt_dlp", "yt_dlp_source": "bundled"\|"updated", "ejs", "certifi", "update_error"}` |
| `version` | `{}` | same fields as `configure` |
| `analyze` | `{"job_id", "argv": [str]}` | `{"ok": true, "info": {…}}` or `{"ok": false, "error", "log": [str], "cancelled": bool}` |
| `download` | `{"job_id", "argv": [str]}` | `{"ok": true, "exit_code", "cancelled", "files": [str]}` or `{"ok": false, "error"}` |
| `cancel` | `{"job_id"}` | `{"ok": true, "found": bool}` |
| `check_update` | `{}` | `{"ok", "current", "latest", "is_newer"}` |
| `install_update` | `{"staging_dir", "update_dir"}` | `{"ok", "version"}` |

`configure` runs once, after the interpreter starts and before anything else. It imports yt-dlp
— from `update_dir` when one is installed and importable, otherwise the bundled copy (reporting
why in `update_error`) — and installs the iOS integration described below.

`analyze` returns the same document as `yt-dlp --dump-single-json` (`YoutubeDL.sanitize_info`),
so the shared `MediaInfoDecoder` reads it unchanged. `download` exit codes follow the command-line
tool: 0 success, 1 error, 101 cancelled.

### Events (Python → Swift, via `_ytdlpgui.emit`)

```jsonc
{"type": "log", "level": "debug|info|warning|error", "message": "WARNING: …"}
{"type": "progress", "status": "downloading|finished|error",
 "downloaded_bytes": 0, "total_bytes": null, "total_bytes_estimate": null,
 "speed": null, "eta": null, "elapsed": null,
 "fragment_index": null, "fragment_count": null, "filename": "…"}
{"type": "postprocess", "status": "started|processing|finished", "postprocessor": "Merger", "filepath": "…"}
{"type": "item", "id", "title", "uploader", "thumbnail", "duration", "webpage_url", "extractor",
 "playlist_index", "playlist_count"}
{"type": "file", "path": "…", "main": true}
```

- `log` messages are one line each, formatted exactly as the command-line tool would print them
  (`WARNING: ` prefix for warnings, `ERROR: …` for errors, `[debug] ` for debug), so the shared
  `ProgressParser` and `DownloadFailure.classify` work on them unchanged.
- `progress` is throttled to five updates a second per job; `finished` and `error` always pass.
- `item` is sent at yt-dlp's `pre_process` stage for every video, before any bytes move.
- `file` is sent at `after_move` for every finished video, with its final path, and then for each
  file kept beside it with `"main": false` (the audio of a pair AVFoundation couldn't merge). The
  queue records every file (`DownloadItem.outputURLs`, `HistoryEntry.outputPaths`) and names the
  download after the last main file, never after a kept companion. A missing `main` means `true`.

### Requests (Python → Swift, via `_ytdlpgui.request`)

Every answer is `{"ok": true, …}` or `{"ok": false, "error": "…", "unsupported": bool}`.
`unsupported` means AVFoundation cannot handle the input at all (WebM, Ogg, MKV…); the host turns
that into a warning and keeps the original file rather than failing the download.

| `op` | Fields | Answer |
|---|---|---|
| `js.run` | `script`, `timeout` (s) | `stdout` — whatever the script passed to `console.log`, newline-joined |
| `media.merge` | `inputs` [path], `output`, `container` (`mp4`\|`mov`\|`m4a`) | — |
| `media.extract_audio` | `input`, `output`, `codec` (`copy`\|`aac`\|`alac`\|`flac`\|`wav`), `bitrate` (bps\|null) | `output` (actual path written) |
| `media.embed` | `path`, `metadata` {title, artist, album, album_artist, date, comment, description, genre, track, purl}\|null, `artwork` path\|null, `chapters` [{start, end, title}]\|null | — |
| `media.convert_image` | `input`, `output`, `format` (`jpg`\|`png`) | — |
| `media.remove_ranges` | `input`, `output`, `ranges` [[start, end]] | — |
| `media.probe` | `path` | `duration`, `tracks` [{kind, codec}], `readable` |

## yt-dlp integration

All of it goes through yt-dlp's own extension points, not by editing its source:

- **Arguments.** Swift builds the argument vector (`ArgumentBuilder.embedded…`); the host turns
  it into parameters with `yt_dlp.parse_options(argv)`, exactly as the command-line tool would.
  The command preview therefore shows the real arguments. The host then adds the engine
  plumbing the preview does not show: `logger`, `progress_hooks`, `postprocessor_hooks`,
  `noprogress`, `no_color`, `cachedir`, `js_runtimes={"jsc": {}}`, and its two reporting
  post-processors (`pre_process` → `item`, `after_move` → `file`).
- **Safety.** After parsing, the host refuses anything that would run a program, load
  configuration or plugins, or replace yt-dlp: `Exec` post-processors, external downloaders,
  `netrc_cmd`, `--update`, browser cookies. (Swift's `CustomArgumentPolicy` already strips these
  from the custom-arguments field; this is the second line of defence.)
- **No subprocesses.** `subprocess` does not work on iOS. The host makes every ffmpeg / ffprobe /
  external-runtime probe report "not available" without trying to launch anything.
- **AVFoundation post-processors.** Registered in place of yt-dlp's ffmpeg ones through
  `yt_dlp.globals.postprocessors` (the same table plugins use), plus `yt_dlp.YoutubeDL.FFmpegMergerPP`
  for merging, which `YoutubeDL` instantiates directly. Each subclasses the original so option
  handling, file naming, `--keep-video` and hooks behave exactly as on the desktop, and overrides
  only the part that would have run ffmpeg, replacing it with a `media.*` request:

  | Replaces | Does | Request |
  |---|---|---|
  | `FFmpegMergerPP` | video + audio → MP4 | `media.merge` |
  | `FFmpegExtractAudioPP` | `--extract-audio`, `--audio-format` | `media.probe`, `media.extract_audio` |
  | `FFmpegMetadataPP` | `--embed-metadata`, `--embed-chapters` | `media.embed` |
  | `EmbedThumbnailPP` | `--embed-thumbnail` | `media.embed` |
  | `FFmpegThumbnailsConvertorPP` | thumbnail → JPEG | `media.convert_image` |
  | `ModifyChaptersPP` | `--sponsorblock-remove` | `media.remove_ranges` |
  | `FFmpegFixupM4aPP` | rewraps YouTube's fragmented "DASH m4a" audio as a plain M4A | `media.extract_audio` (`codec: copy`) |

  `FFmpegMergerPP` and `FFmpegFixupM4aPP` are also replaced in the `yt_dlp.YoutubeDL` module's
  namespace, because `YoutubeDL` creates them directly rather than through the table. Without the
  fix-up replacement every YouTube audio download would warn that ffmpeg is missing. The other
  fix-ups, subtitle embedding and conversion, remuxing and splitting remain ffmpeg-only; yt-dlp
  reports them as unavailable with a warning.
- **JavaScript challenges.** YouTube requires solving JavaScript "n" and signature challenges.
  yt-dlp's EJS framework runs a solver script in an external runtime; the host registers a
  runtime named `jsc` in `yt_dlp.globals.supported_js_runtimes` and a challenge provider
  subclassing `EJSBaseJCP` whose `_run_js_runtime` sends the script to Swift as `js.run`.
  Swift evaluates it in a fresh `JSContext` with `console.log` captured.
- **TLS.** The embedded OpenSSL cannot see the iOS trust store, so certifi's CA bundle is used
  (`SSL_CERT_FILE`, and yt-dlp picks certifi up by itself).
- **Cancellation.** A per-job flag checked in every hook and log call, which raises
  `DownloadCancelled`; plus `_ytdlpgui.interrupt` to raise it asynchronously in the job's thread
  when yt-dlp is busy somewhere that never calls back (extraction, retries).

## Argument rules for the embedded engine

`ArgumentBuilder.embeddedDownloadArguments` follows the macOS builder section by section, with
these differences:

- No progress template (hooks replace it) and no `--ffmpeg-location`.
- `--paths temp:<Library/Caches/Partial Downloads>` when a temporary directory is given.
- `--no-mtime`: files are dated when downloaded, which is what the Files app sorts by.
- **Video** always ends up MP4 (`--merge-output-format mp4`), so format selection only accepts
  what AVFoundation can mux: H.264 or HEVC video (plus AV1 when the device decodes it in
  hardware) in MP4, with AAC audio, either as `.m4a` or as any `mp4a` stream (HLS audio
  renditions are AAC with an `.mp4` extension). Pre-merged MP4 is the fallback, first at the
  height cap and then without it; after that come any pre-merged file and, last, any video and
  audio pair, both downloaded as is. The pair keeps sites with no pre-merged format at all
  (WebM-only DASH) working: if AVFoundation can't merge it, the host keeps both files with a
  warning. With a height cap `H` (`ArgumentBuilder.embeddedVideoFormatSelector`):
  `bv*[height<=?H][ext=mp4][vcodec~='^(avc|h264|hvc|hev|h265)']+(ba[ext=m4a]/ba[acodec^=mp4a])/b[height<=?H][ext=mp4]/bv*[ext=mp4][vcodec~='^(avc|h264|hvc|hev|h265)']+(ba[ext=m4a]/ba[acodec^=mp4a])/b[ext=mp4]/b/bv*+ba`
- **Audio** prefers AAC sources (`ba[ext=m4a]/ba[acodec^=mp4a]/ba/b`), which AVFoundation can
  read. Available formats: Best (keep the original), M4A (AAC, with bitrate), ALAC, FLAC, WAV.
  MP3 and Opus have no encoder on iOS; if either arrives (from an old saved option) it becomes M4A.
- **Subtitles** are written as separate files; `--embed-subs` is never passed.
- **Cookies** come from `--cookies <file>`; `--cookies-from-browser` is never passed. The host
  reads the file when a job starts and gives yt-dlp an in-memory copy (`cookiefile` accepts a
  text stream), so the imported file is never written. yt-dlp saves its cookie jar back to the
  file whenever a job closes, truncating it first; with concurrent jobs, one job's save could
  otherwise let another read a half-written file, and the last job to finish would silently undo
  the others' changes.
- **Custom arguments** use `CustomArgumentPolicy` with `context: .embedded`, which additionally
  rejects `--cookies-from-browser`, `--ffmpeg-location`, `-U`/`--update`/`--update-to`,
  `--js-runtimes`, `--no-js-runtimes` and `--remote-components`.

## App layer

The iOS app mirrors the macOS app's structure and names; each type is the iOS counterpart of
the macOS one.

- **`AppModel`** — composition root, in the SwiftUI environment. Owns everything below; tracks the
  selected tab (`AppTab`: download, queue, history, settings) and the queue item and history
  entry being shown; handles `ytdlpgui://` links, the Share extension inbox, scene-phase changes
  and the clipboard suggestion. A tap on a download notification goes through `openDownload`:
  the queue item while the queue has it, otherwise the history entry whose `downloadID` matches,
  since the queue forgets finished downloads when the app is relaunched or they're cleared.
- **`EngineController`** — the counterpart of `Toolchain`: engine state (starting, ready, failed),
  versions, the capabilities used for argument building, and yt-dlp updates.
- **`DownloadComposer`** — the Download screen: URL text, analysis, options, advisories, command
  preview, queueing.
- **`DownloadQueue`** — runs `DownloadItem`s through `YTDLPEngine`, with a concurrency limit, and
  handles completion: history, notifications, saving to Photos. A link is queued only once at a
  time: `enqueue` returns `.alreadyPending` for a link that is waiting or running, whichever
  screen it came from, and retrying skips an item whose link is pending as another item. yt-dlp
  names its temporary files after the video and doesn't lock them, so two jobs for one link would
  write the same `.part` files.
- **Services** — `AppSettings`, `NotificationService`, `MediaLibrary` (Photos), `CookieStore`,
  `StorageManager`, `BackgroundActivity` (continued processing and idle timer), `SharedLinkInbox`.

### Background execution

iOS suspends a backgrounded app within seconds. On iOS 26 and later a download started in the
foreground submits a `BGContinuedProcessingTaskRequest`
(`io.github.ytdlpgui.YTDLPGUI.iOS.downloads.<id>`), which lets the queue keep running with system
progress UI; the task reports aggregate progress and, if the system expires it, running downloads
are cancelled cleanly so they resume from their partial files later. Earlier systems get the
standard short background-task extension. While downloads run in the foreground the idle timer
can be disabled (a setting), so the screen doesn't lock mid-download.

### Links from elsewhere

- **Share sheet** — the Share extension writes each shared link to the App Group inbox as
  `Inbox/<timestamp>-<uuid>.json`: `{"version": 1, "urls": [str], "kind": "video"|"audio"|null,
  "created": ISO-8601}`. When the app becomes active it drains the inbox: links with a `kind` are
  queued straight away with the last-used options; links without one are put in the URL field.
- **URL scheme** — `ytdlpgui://download?url=<percent-encoded>&kind=video|audio` fills in the
  Download screen. It never starts a download by itself: a web page must not be able to.
- **Shortcuts** — an App Intent, “Download with YTDLP GUI”, which the user configures explicitly
  and which does start the download.

## Updating yt-dlp

Extractors break whenever sites change, so an app that could never update yt-dlp would stop
working within weeks. Settings › Engine checks PyPI for the newest release; installing it
downloads the yt-dlp wheel and the yt-dlp-ejs release that version expects, verifies both against
the SHA-256 digests PyPI publishes, unpacks them into a staging folder, and moves that into a new
folder, `Application Support/Engine/yt-dlp/versions/<UUID>/`. The app then writes that folder's
name to `Engine/yt-dlp/current`. The update takes effect at the next launch. If it ever fails to
import, the engine falls back to the bundled copy and says so. “Use Bundled Version” removes
`current`.

No update folder is changed or removed while the app runs. yt-dlp imports each extractor the
first time a site is used, and the challenge solver reads its scripts on each use, both from the
folder the interpreter started with. Replacing or deleting that folder mid-session would mix two
yt-dlp versions or fail with `ModuleNotFoundError`. So the host refuses to install into a folder
that exists, and folders nothing points at any more are deleted at the next launch, before Python
starts (`EngineConfiguration.prepareUpdatesForLaunch`). That step also moves an update installed
by an earlier build, which lived directly in `Engine/yt-dlp/`, into a folder of its own and keeps
using it. Installing and reverting are therefore safe while downloads run.

## Testing

- `Shared/` logic is covered by the macOS test suite (`xcodebuild test -scheme YTDLPGUI`), which
  now also asserts the embedded argument rules.
- `PythonHost/tests` run on the Mac against the vendored yt-dlp with a fake `_ytdlpgui` module:
  `python3 -m unittest discover -s PythonHost/tests -t PythonHost`.
- `YTDLPGUI-iOSTests` run on a device or in the Simulator: media processing on generated clips,
  the JavaScript runner, and the engine end to end — a download of a generated clip over a local
  HTTP server, merged by AVFoundation — without touching the network. A live YouTube check runs
  only when `YTDLPGUI_LIVE_TESTS=1` is set (`TEST_RUNNER_YTDLPGUI_LIVE_TESTS=1` when passed
  through `xcodebuild`).
- `YTDLPGUI-iOSUITests` is a walkthrough from link to download, queue, history and settings. It
  also needs the live flag, since it downloads from YouTube.
