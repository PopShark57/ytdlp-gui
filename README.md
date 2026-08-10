<div align="center">

<img src="Icon/AppIcon.svg" width="128" height="128" alt="YTDLP GUI icon">

# YTDLP GUI

**A native macOS front end for [yt-dlp](https://github.com/yt-dlp/yt-dlp).**

Paste a link, pick a quality, click Download. Everything else stays out of the way
until you ask for it.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![Interface](https://img.shields.io/badge/UI-SwiftUI-blue)
![License](https://img.shields.io/badge/license-MIT-green)

</div>

---

## Overview

YTDLP GUI is a SwiftUI application that drives the `yt-dlp` command-line tool through a proper
Mac interface. It parses yt-dlp's output into real UI state — a progress bar, a transfer rate,
an estimated time, a named post-processing stage — instead of dumping terminal text into a
window. Errors arrive as sentences a person can act on, with the original output one click away.

The app is a front end only. It does not bundle, vendor or install `yt-dlp`: it drives the copy
you install yourself, so you decide when it updates and where it comes from.

## Features

### The basics

- URL field with paste, drag-and-drop and clipboard detection
- **Analyze** a link to see the title, thumbnail, channel, duration, resolution, chapters,
  subtitle languages and every available format before committing
- Video presets: Best, 4K, 1440p, 1080p, 720p, 480p — with a container preference of MP4, MKV,
  WebM or automatic
- Audio presets: Best (no re-encode), MP3, M4A, FLAC, WAV, Opus — with a selectable bitrate
  where it actually applies
- Output folder picker with a live filename-template field and ready-made template presets

### Download queue

- Multiple simultaneous downloads with a configurable limit (1–8)
- Per-item thumbnail, title, phase, percentage, speed, ETA and transferred/total size
- Distinct phases: downloading, merging, extracting audio, embedding artwork, writing metadata,
  removing segments, finishing up
- Cancel, retry, remove, clear finished, reveal in Finder
- An expandable raw log per item, with filtering and copy

### Advanced options

Subtitles (uploaded, auto-generated or both, with language selection and embedding) · embed
thumbnail, metadata and chapters · write thumbnail and `.info.json` · SponsorBlock marking or
removal with per-category selection · playlist downloading with item ranges · download archive ·
cookies from browser · rate limit · parallel fragments · proxy · user agent · ASCII-only
filenames · overwrite behaviour · and a free-form field for any other yt-dlp argument.

A **command preview** shows the exact command before it runs, and it is generated from the same
argument array that is handed to the process — not a reconstruction.

### History

Every finished download is recorded locally with its title, source URL, output path, date,
format and outcome. Search it, reveal the file in Finder, copy the original URL, or download it
again with the exact options used the first time. Entries whose file has since moved are
flagged.

### Dependency management

The app finds `yt-dlp` and `ffmpeg` in the usual Homebrew, MacPorts and pip locations, shows
their versions, and lets you point at a specific executable. It can update yt-dlp for you, and
it is Homebrew-aware: a Homebrew install is upgraded with `brew upgrade yt-dlp` rather than
`yt-dlp --update`, which would leave the formula out of step.

### macOS integration

Sidebar navigation · standard Settings window · menu bar commands · keyboard shortcuts ·
drag-and-drop · Finder reveal · local notifications · full Dark Mode · accessibility labels on
every control · tooltips throughout.

## Screenshots

> Add screenshots here. Suggested set:
>
> | | |
> |---|---|
> | `Docs/screenshot-download.png` | The download screen with a link analyzed |
> | `Docs/screenshot-queue.png` | The queue mid-download, showing speed and ETA |
> | `Docs/screenshot-history.png` | History with a search in progress |
> | `Docs/screenshot-settings.png` | The yt-dlp settings pane |

## Requirements

| | |
|---|---|
| **macOS** | 14.0 Sonoma or later |
| **Architecture** | Apple silicon and Intel |
| **Xcode** | 16 or later (to build) |
| **yt-dlp** | Required, installed separately |
| **ffmpeg** | Strongly recommended — needed to merge video with audio and to convert audio |

## Installing the tools

Both dependencies come from [Homebrew](https://brew.sh):

```bash
brew install yt-dlp ffmpeg
```

Or individually:

```bash
brew install yt-dlp
```

```bash
brew install ffmpeg
```

Without ffmpeg the app still works, but it can only download formats that already have video and
audio muxed together — which on most sites means a noticeable quality ceiling. The app says so
plainly when ffmpeg is missing rather than silently downloading something worse.

If yt-dlp lives somewhere unusual (pipx, a custom prefix, a manually downloaded binary), point
the app at it in **Settings › yt-dlp › Choose Executable**.

## Building

```bash
git clone https://github.com/<your-account>/YTDLP-GUI.git
```

```bash
cd YTDLP-GUI && open YTDLPGUI.xcodeproj
```

Then press ⌘R. The project uses ad-hoc code signing (`CODE_SIGN_IDENTITY = "-"`) so it builds
and runs without a developer account or team.

From the command line:

```bash
xcodebuild -scheme YTDLPGUI -configuration Release build
```

### Running the tests

```bash
xcodebuild test -scheme YTDLPGUI -destination 'platform=macOS'
```

The suite covers argument construction, progress parsing, JSON decoding, error classification,
line splitting, argument tokenising and formatting. There is also an integration suite that
drives the real `yt-dlp` binary end to end — it generates a short clip with ffmpeg and downloads
it over a `file://` URL, so it needs no network. That suite skips itself automatically if
yt-dlp or ffmpeg aren't installed.

## Usage

1. **Paste** a URL — ⇧⌘V, or drop a link onto the window.
2. **Analyze** it if you want to see what's on offer first (⌘I). Optional.
3. **Choose** Video or Audio and pick a quality.
4. **Download** (⌘↩). The item appears in the queue with live progress.

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⇧⌘V | Paste URL |
| ⌘I | Analyze URL |
| ⌘↩ | Start download |
| ⌘O | Choose output folder |
| ⇧⌘O | Reveal output folder in Finder |
| ⌘K | Clear the URL field |
| ⌘. | Cancel all downloads |
| ⌘1 / ⌘2 / ⌘3 | New Download / Queue / History |
| ⌘, | Settings |

### Filename templates

The output template is passed straight to yt-dlp's `--output`, so the
[full template syntax](https://github.com/yt-dlp/yt-dlp#output-template) is available. Common
placeholders are listed in the app under **Template placeholders**.

```
%(title)s.%(ext)s                                     Me at the zoo.mp4
%(uploader)s - %(title)s.%(ext)s                      jawed - Me at the zoo.mp4
%(playlist_title)s/%(playlist_index)02d - %(title)s.%(ext)s
```

## Architecture

MVVM, with a strict separation between the code that talks to yt-dlp and the code that draws
the interface. Everything is `@MainActor` except the child processes themselves, whose output
arrives as an `AsyncStream`, which keeps the model single-threaded and free of locks.

```
YTDLPGUI/
├── App/              Entry point, composition root, menu commands
├── Models/           Value types: options, media info, progress, failures, history
├── Services/         Everything that touches the outside world
│   ├── ProcessRunner.swift    Safe Process wrapper → AsyncStream of line events
│   ├── ToolLocator.swift      Finds yt-dlp / ffmpeg / brew
│   ├── ArgumentBuilder.swift  DownloadOptions → [String]  (pure)
│   ├── ProgressParser.swift   yt-dlp output → structured events  (pure)
│   ├── YTDLPService.swift     Metadata, downloads, updates
│   ├── HistoryStore.swift     JSON persistence
│   ├── AppSettings.swift      UserDefaults-backed preferences
│   └── NotificationService.swift
├── ViewModels/       Toolchain, DownloadQueue, DownloadComposer
├── Views/            SwiftUI, grouped by screen
└── Utilities/        Formatters, URL detection, quoting, Finder helpers
```

### Notable decisions

**Progress is parsed, not scraped.** yt-dlp runs with `--newline` and a custom
`--progress-template` that emits tab-separated machine-readable fields, plus a second template
for post-processing stages. Missing values arrive as the literal `NA` and become `nil`, so the
UI shows an indeterminate bar rather than a fake zero. The human-readable `[download]`,
`[Merger]` and `[ExtractAudio]` lines are parsed too, because they are the only place yt-dlp
reveals the final output path — which is what "Reveal in Finder" needs after a merge or an audio
conversion renames the file.

**No shell, ever.** Commands are launched with `Process.executableURL` and a fully-formed
`Process.arguments` array. Nothing is ever passed to `bash -c`, so a URL, a path, a filename
template or a custom argument cannot be reinterpreted as shell syntax. The free-form arguments
field is tokenised by a small parser that understands quotes and backslashes but performs no
expansion — no globbing, no variables, no command substitution. The URL is always passed after a
`--` separator so that a leading dash cannot become a flag. The command preview is shell-quoted
purely so it reads well and can be pasted into Terminal.

**The App Sandbox is deliberately off.** A sandboxed process may not execute arbitrary binaries
outside its container, which is precisely what this app exists to do. The app is distributed
outside the Mac App Store; the Hardened Runtime is enabled for Release builds so it can still be
notarized. See `YTDLPGUI/YTDLPGUI.entitlements`.

**A deliberately minimal child environment.** An app launched from Finder inherits almost no
useful `PATH`, so the child process is given an explicit one covering the standard package
manager locations, plus `--ffmpeg-location` when ffmpeg's path is known. `PYTHONUNBUFFERED` and
`PYTHONIOENCODING` are set so progress arrives line by line and non-ASCII titles survive.

**JSON is decoded leniently.** yt-dlp's output comes from over a thousand independent
extractors, and field presence and even field *types* vary between them. Every value is read
permissively and a missing or oddly-typed field never fails the whole decode.

**History is plain JSON, not SwiftData.** The data is a flat, append-mostly list of at most a
few thousand rows with no relationships and no migration story. A plain file at
`~/Library/Application Support/YTDLPGUI/history.json` is easier to inspect, back up and delete.
A corrupt file is moved aside rather than silently discarded.

### The application icon

The icon is generated programmatically — there is no binary source artwork to keep in sync.
`Tools/GenerateAppIcon.swift` defines the design once as a list of primitives and renders it
twice: through Core Graphics for every required PNG size, and as SVG markup for the vector
master. Fine detail (the film-strip perforations) is suppressed below 128px, where it would only
read as grit.

```bash
./Tools/generate-app-icon.sh
```

That rewrites `YTDLPGUI/Assets.xcassets/AppIcon.appiconset/` (PNGs plus `Contents.json`),
`Icon/AppIcon.svg` and `Icon/AppIcon.icns`. It needs nothing but a Swift toolchain.

## Contributing

Issues and pull requests are welcome.

- Keep the dependency list empty. This project deliberately uses only Apple frameworks.
- Pure logic belongs in `Services/` with tests. `ArgumentBuilder` and `ProgressParser` are pure
  functions specifically so they can be tested without launching anything.
- If you change how a command is built, add a test that asserts the resulting argument array.
  The command preview is a user-facing promise about what will run.
- Match the surrounding style: comments explain *why*, not *what*.
- Run `xcodebuild test -scheme YTDLPGUI -destination 'platform=macOS'` before opening a PR.

## Troubleshooting

**"Sign in to confirm you're not a bot"** — the site is gating requests. Turn on
**Advanced Options › Use cookies from browser** and pick a browser you're signed into. Updating
yt-dlp often helps too, since these checks change frequently.

**A download that used to work now fails** — update yt-dlp
(**Settings › yt-dlp › Update yt-dlp**). Extractors break whenever a site changes, and yt-dlp
ships fixes constantly.

**Quality is lower than expected** — check that ffmpeg is installed. Without it, only
pre-combined formats are available.

**Nothing happens when I click Download** — check the sidebar's dependency status. If yt-dlp is
missing, the app shows a setup screen with the install command.

## License

Released under the [MIT License](LICENSE).

## A note on affiliation

This project is an independent, unofficial graphical front end. It is **not affiliated with,
endorsed by, or connected to YouTube, Google, or the yt-dlp project** in any way. yt-dlp and
ffmpeg are separate projects distributed under their own licenses; this application neither
bundles nor redistributes them.

You are responsible for how you use it. Respect the terms of service of the sites you download
from and the copyright of the material you download.
