# Continuation notes — iOS app for YTDLP GUI

Handoff for the next session. Written 2026-09-24, updated 2026-09-25. The iOS app was merged in
PR #3 (`feat/ios-app`). The follow-up work in "Done on 2026-09-25" below is on the branch
`claude/magical-dirac-95o34m`.

## What exists

The native iPhone/iPad version of the macOS app is built and tested on a real device.

- **Architecture:** `Docs/iOS-Architecture.md`. Read it first; it is the authoritative design and
  describes the Swift ⇄ Python JSON protocol.
- **Engine.** iOS can't launch processes, so yt-dlp runs in-process in an embedded CPython 3.14
  (BeeWare `Python.xcframework`):
  - AVFoundation replaces ffmpeg;
  - JavaScriptCore solves YouTube's JS challenges, through a custom yt-dlp EJS provider named `jsc`.
- **Layout:**

  | Path | Contents |
  |---|---|
  | `Shared/` | platform-neutral Swift, compiled into both apps |
  | `YTDLPGUI/` | the macOS app |
  | `YTDLPGUI-iOS/` | the iOS app: `App/`, `Engine/{Runtime,JavaScript,Media}/`, `ViewModels/`, `Services/`, `Views/`, `Intents/` |
  | `YTDLPGUI-iOS-Share/` | the Share extension |
  | `YTDLPGUI-iOSTests/` | iOS unit and integration tests, including a local HTTP server and fixtures |
  | `YTDLPGUI-iOSUITests/` | a UI walkthrough; runs only when `YTDLPGUI_LIVE_TESTS=1` |
  | `PythonHost/ytdlpgui_host/` | the Python side of the engine, with tests in `PythonHost/tests/` |
  | `Tools/fetch-ios-dependencies.sh` | downloads pinned, SHA-verified Python and wheels into git-ignored `Vendor/` |
  | `Tools/install-ios-python.sh` | the Xcode build phase that installs Python into the app bundle |

- **Xcode:**
  - targets: `YTDLPGUI-iOS`, `YTDLPGUI-iOSTests`, `YTDLPGUI-iOSUITests`, `YTDLPGUI-iOS-Share`;
  - scheme: `YTDLPGUI-iOS`;
  - the macOS target now also compiles `Shared/`.

## Verified state (at the time of writing)

| Suite | Result |
|---|---|
| macOS: `xcodebuild test -scheme YTDLPGUI -destination 'platform=macOS'` | **176 tests pass** |
| Python host: `PYTHONPATH=Vendor/python-packages:PythonHost python3 -m unittest discover -s PythonHost/tests -t PythonHost` | **129 pass**, 1 skipped (live) |
| iOS unit + integration, **on Sergey's iPhone** (iPhone 16 Pro Max) | **173 pass** |
| Live YouTube tests on the iPhone | **4 pass** |
| UI walkthrough on the iPhone, from a fresh install | **passes** |

The iOS integration run covers:

- a real embedded engine;
- an HTTP download;
- a DASH merge via AVFoundation;
- AAC and FLAC extraction;
- cancellation and concurrent downloads.

The live run confirmed `[jsc:javascriptcore] Solving JS challenges using jsc` on the device.

The UI walkthrough went: link → analysis → download → queue → details → History → Settings.

## How to build and test on the device

**The user asked not to use the Simulators.** They're malfunctioning; use the physical iPhone.

- Device id: `00008140-0002452A21C0801C`.
- Team: the free Personal Team `7RLDYXQTNX`. Pass it on the command line; don't write it into the project.
- **Free teams can't use App Groups**, so device builds must pass `CODE_SIGN_ENTITLEMENTS=` (empty).
  The Share extension then falls back to "Copy Link". A paid team would enable the App Group
  `group.io.github.ytdlpgui.YTDLPGUI`.

```bash
./Tools/fetch-ios-dependencies.sh   # once; fills Vendor/
xcodebuild test -scheme YTDLPGUI-iOS -destination 'id=00008140-0002452A21C0801C' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=7RLDYXQTNX CODE_SIGN_ENTITLEMENTS= \
  -only-testing:YTDLPGUI-iOSTests
# Live YouTube + UI walkthrough (the user approved testing with "Me at the zoo", jNQXAC9IVRw):
TEST_RUNNER_YTDLPGUI_LIVE_TESTS=1 xcodebuild test ... -only-testing:YTDLPGUI-iOSTests/LiveYouTubeTests
TEST_RUNNER_YTDLPGUI_LIVE_TESTS=1 xcodebuild test ... -only-testing:YTDLPGUI-iOSUITests -resultBundlePath /tmp/ui.xcresult
```

**Screenshots:**

- `xcrun devicectl device capture screenshot --device <id> --destination x.png`
- or export the UI-test attachments: `xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>`

**Fast type-check without Xcode:**

```bash
xcrun --sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios18.0-simulator -swift-version 6 \
  -import-objc-header YTDLPGUI-iOS/Engine/Runtime/YTDLPGUI-iOS-Bridging-Header.h \
  -Xcc -I -Xcc Vendor/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Headers \
  $(find Shared YTDLPGUI-iOS -name '*.swift')
```

## Fixes made in the last session

- **Cookie import:** `CookieStore` failed on Windows (CRLF) cookie files, because Swift treats
  `"\r\n"` as a single `Character`. It now splits on any newline.
- **AAC bitrate:** AAC re-encoding now uses a constant bitrate, so a chosen bitrate means what it
  does to ffmpeg.
- **DASH m4a fix-up:** the Python host now replaces yt-dlp's DASH-m4a fix-up with an AVFoundation
  rewrap (`FixupM4aPP`). Every YouTube audio download used to warn "Install ffmpeg".
- **Notification permission:** it is now asked when a download starts (`AppModel.startDownload`),
  not on top of a finished download.
- **Settings › Engine:** the status row had a tall empty gap.
- **"Site" row:** shows the page's domain instead of yt-dlp's extractor key.
- **UI test target:** added (`YTDLPGUI-iOSUITests`), plus `accessibilityIdentifier("startDownloadButton")`.

## Done on 2026-09-25 (cloud session, Linux: no Xcode or device)

- **README.md** has an iOS section: requirements, the fetch script, signing and the free-team
  App Group caveat, sideload-only distribution (App Review Guideline 5.2.3), the differences from
  macOS, the Files location, the Share extension, Shortcuts and the URL scheme, cookies, updating
  yt-dlp, background downloads and tests. Also: a combined architecture tree, the iOS icon and
  `AccentColor` outputs of the icon generator, the bundled components' licences, and a corrected
  affiliation note (the iOS app *does* bundle yt-dlp).
- **`Docs/iOS-Architecture.md`**: the video selector now matches
  `ArgumentBuilder.embeddedVideoFormatSelector`; `FixupM4aPP` is in the post-processor table; the
  cookie handling and the UI-test target are described.
- **Cookie-file race, fixed in the Python host** (`options.engine_params` →
  `_private_cookie_copy`). Each job reads the `--cookies` file when it starts and hands yt-dlp an
  `io.StringIO` copy, which `cookiefile` accepts. yt-dlp's save-on-close then only rewrites that
  job's copy, so the imported file is never written. A missing file becomes "no cookies"
  (`None`). An unreadable one is left as a path, so yt-dlp reports the error itself. Five new
  tests are in `PythonHost/tests/test_options.py` (`CookieFileTests`); three of them fail
  without the fix.
  - Deliberate consequence: cookies that a site refreshes during a download aren't persisted.
    The imported file stays exactly as imported, which also keeps the Cookies screen's
    summary (count and domains) true.
- Python host suite: **134 pass**, 1 skipped (live). This was run with Python 3.14.0rc2 from
  `uv` and ffmpeg from apt, against the pinned wheels.

## Remaining work (suggested order)

1. **Rebuild and run the iOS tests on the iPhone.** No Swift changed in this session, so nothing
   should break. But the Python host changed and is bundled into the app. The live YouTube tests
   run with cookies only if some are imported.
2. **Not yet exercised on the device:**
   - the Share extension UI;
   - BGContinuedProcessingTask background continuation (iOS 26+);
   - Save to Photos;
   - the yt-dlp update install;
   - the App Intent / Shortcuts;
   - iPad layout;
   - light mode.

   The UI test only covers dark mode on iPhone.
3. **A cosmetic AVFoundation log** during metadata embedding: "FigUserDataSerializerAddItem …
   Value has invalid iso data type". It's harmless: the downloads succeed. It wasn't changed
   this session, because pinning down the offending item needs AVFoundation, which Linux
   doesn't have, and a web search found nothing on the message. "FigUserData" is Core Media's
   `udta` user-data writer. "iso" most likely means the ISO/3GPP user-data key space that
   `AVAssetWriter` derives from the iTunes tags (see the comment on `MetadataTags.merged`).
   - **Suspects, in order:**
     1. `.iTunesMetadataReleaseDate` written as a UTF-8 "YYYY-MM-DD" string. Its 3GPP
        counterpart, `yrrc`, is a 16-bit year.
     2. The `trkn` item written as raw data.
     3. An item carried over from the source file.
   - **To find it:** in a device test that calls `MetadataEmbedder.embed`, embed one tag at a
     time and watch the console. Then fix that item's data type, or drop its derived copy, in
     `YTDLPGUI-iOS/Engine/Media/MetadataTags.swift`.
4. A Release-configuration device build hasn't been tried; only Debug has.

## Other sessions and tasks

- **A separate session is changing `Shared/Utilities/CustomArgumentPolicy.swift`** ("Fix inline
  --exec custom-argument policy test"). It already changed its value-skipping loop, and that test now
  passes. It must keep the `Context` API.
- **A cloud task is blocking abbreviated long options** ("Block abbreviated and --use-postprocessor
  exec bypasses", `task_b73c4776`). It covers options like `--exec-b` and `--use-postprocessor Exec:…`
  getting past the macOS denylist. On iOS, the Python host's post-parse safety check is the backstop.
- The parallel build workflow (`wf_de21722a-1e4`) is stopped. **The user asked not to use
  subagents**, so continue the work directly.
