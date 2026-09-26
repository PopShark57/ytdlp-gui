# iOS Codebase Improvement Audit

Audit of the iOS side of YTDLP GUI at commit `bf94ff4` (2026-09-26). Covered:

- the app (`YTDLPGUI-iOS/`);
- the Share extension (`YTDLPGUI-iOS-Share/`);
- the `Shared/` code it compiles in;
- the Python host bundled into the app (`PythonHost/ytdlpgui_host/`);
- the iOS test targets.

No production source file was changed.

**How this was checked**

- **Read in full:**
  - the app, view-model, service and engine-runtime layers;
  - the C bridge;
  - the history, queue and settings-engine views;
  - the Share extension's model and inbox code;
  - the Python host's `dispatch`, `bridge`, `engine`, `jobs`, `options`, `downloads`, `compat`, `javascript` and `updates` modules.
- **Read in part:**
  - the media operation types: the facade, merger, passthrough and sample-transfer code in full; `AudioExtractor`, `MetadataEmbedder`, `RangeRemover`, `ImageConverter` and `ChapterTrack` searched only;
  - the remaining Download and Settings sub-views;
  - `postprocessors.py`: its first part and `MergerPP` only;
  - the Share extension's UI.

  Findings are limited to code that was actually read.
- The main flows were traced end to end: launch, analysis, queueing, the engine job, events, requests, completion, cancellation, background expiry, updates, and links from elsewhere.
- The Python host suite was run on Python 3.14.0rc2 against the pinned wheels (`yt_dlp 2026.8.19`, `yt_dlp_ejs 0.8.0`): **87 pass, 47 skipped**. The skips are mostly tests that need ffmpeg, which this container doesn't have, plus the live test.
- Finding **P1-1** was reproduced with the host's real `updates._replace_directory` (script under P1-1).
- The yt-dlp behaviour findings rely on was confirmed in the pinned wheel's source:
  - lazy extractor imports;
  - `yt_dlp_ejs` reading its scripts at call time;
  - no locking of `.part` files;
  - `Config.hide_login_info`.
- Platform behaviour was checked against Apple's documentation and DTS answers (see [References](#references)).
- **Not done here:** Swift wasn't compiled and the iOS tests weren't run, because the container is Linux without Xcode. `Continuation.md` records the last device run: 173 unit and integration tests passing on an iPhone 16 Pro Max.

**Labels used below**

- **Definite bug:** the code path was traced and the failure follows from it.
- **Potential risk:** plausible, but not measured or reproduced.
- **⚠ Behaviour change:** the fix changes what the person sees, so it needs regression testing.

---

## Executive Summary

**Overall state.** The iOS codebase is unusually disciplined for its size: about 12k lines of iOS and Share-extension Swift, 3k of `Shared/` Swift, 0.5k of C and 2.2k of Python.

- Responsibilities are cleanly separated.
- Threading rules are written down next to the code that depends on them.
- There are no force-unwraps, `try!`, `fatalError`, TODOs or stray `print`s.
- Errors are typed and phrased for people.
- Accessibility is considered throughout.
- Test coverage of the engine protocol, queue, composer and media processing is broad.

The hard problem, running yt-dlp in-process on iOS, is solved deliberately:

- dedicated 16 MB-stack threads keep blocking work off the cooperative pool;
- a GIL-aware C bridge connects Swift and Python;
- cancellation works both by flag and by asynchronous interrupt;
- every media output is written to a staging file and renamed into place;
- argument safety has two layers (Swift policy, then a Python post-parse check).

**Strongest parts**

- `EngineCallbackHub` / `EngineJob`: a per-job lock guarantees "nothing after the result".
- `FirstOutcome` and the host cancellation handshake (`jobs.Job.run` / `_absorb_pending_interrupt`).
- The AVFoundation replacements for ffmpeg (`PassthroughCopy`, `SampleTransfer`, `MediaFiles.writeAtomically`).
- `DownloadOptionsResolver`: container paths are never trusted across launches.
- Continued-processing registration registers each unique identifier just before submitting. That is the pattern Apple DTS recommends, and it avoids a known wildcard-matching crash.

**Biggest technical risks.** There is no P0. The six P1 findings, most important first:

1. **P1-1 (definite).** Installing a yt-dlp update, or choosing *Use Bundled Version*, changes or deletes the files the running interpreter still imports lazily. Downloads in the same session can then mix two yt-dlp versions or fail with `ModuleNotFoundError`.
2. **P1-2 (definite gap; corruption plausible).** The same link can run as two jobs at once. yt-dlp doesn't lock its temporary files, and both jobs write the same `.part` files.
3. **P1-6 (definite).** Passwords and proxy credentials typed into custom arguments appear in the command preview and in each download's shareable log. yt-dlp itself masks them.
4. **P1-3, P1-4, P1-5 (definite).** Three user-facing correctness bugs:
   - *Edit Options and Download* bypasses the tested history-loading path;
   - notification taps after a relaunch open "Download Removed";
   - multi-file (playlist) downloads keep only the last file in history. For a video whose parts couldn't be merged, that "last file" is the audio track.

**Highest-leverage improvements**

- Make update installs never touch the folder in use (P1-1). It removes a whole class of hard-to-diagnose failures.
- Enforce one duplicate-link rule inside `DownloadQueue` (P1-2).
- Make one additive, backward-compatible change to `HistoryEntry` (`downloadID`, `outputPaths`). It unlocks both P1-4 and P1-5.

---

## Architecture Overview

### Layers

| Layer | Types (files) | Notes |
|---|---|---|
| Entry and composition | `YTDLPGUIMobileApp`, `AppModel` (`App/`) | `AppModel` builds every service once, holds tab and navigation state, and routes links from `ytdlpgui://`, the Share inbox, Shortcuts and the clipboard. It turns scene-phase changes into background work and persistence. It reaches views through `.environment(model)`. |
| View models (`@MainActor @Observable`) | `DownloadComposer`, `DownloadQueue`, `EngineController` (`ViewModels/`) | Composer: URL field, analysis, options, preview, queueing. Queue: scheduling, event application, completion (history, notifications, Photos), persistence. Controller: engine state and updates. |
| Services | `AppSettings`, `HistoryStore` (Shared), `QueueStore`, `StorageManager`, `CookieStore`, `NotificationService`, `MediaLibrary`, `BackgroundActivity`, `SharedLinkInbox`, `ClipboardLinkDetector` | Mostly `@MainActor`. Persistence is JSON files and `UserDefaults`. |
| Engine seam | `DownloadEngine`, `AnalysisEngine`, `EngineRuntime` (`Services/EngineInterfaces.swift`) | Narrow protocols. `YTDLPEngine.shared` conforms to all three, and the tests use fakes. |
| Engine (Swift) | `YTDLPEngine`, `EngineThread`, `EngineCallbackHub` / `EngineJob`, `EngineRequestRouter`, `PythonRuntime`, the decoders (`Engine/Runtime/`) | Thread-safe (`Sendable`, `Mutex`). Every blocking call runs on a dedicated `Thread`. |
| Bridge (C) | `PythonBridge.c/.h` | The only code that touches the CPython API. Sets up an isolated interpreter and the `_ytdlpgui` module (`emit`, `request`, `interrupt`), and calls `ytg_call` into the host's `dispatch`. |
| Host (Python) | `ytdlpgui_host`: `dispatch`, `engine` (configure / import), `options` (parse and refuse), `jobs`, `downloads`, `postprocessors` (AVFoundation stand-ins), `javascript` (the `jsc` runtime), `compat`, `updates` | Runs yt-dlp through its own extension points. |
| Media (Swift) | `MediaProcessor` facade over `MediaMerger`, `AudioExtractor`, `MetadataEmbedder`, `RangeRemover`, `ImageConverter`, `MediaSource` (`Engine/Media/`) | Answers `media.*` requests. |
| JS (Swift) | `JavaScriptChallengeRunner` | Answers `js.run` with a fresh `JSContext` per run, on its own thread, with a timeout. |
| Share extension | `ShareViewController`, `ShareSheetModel`, `LinkExtractor`, `InboxWriter` | Writes `Inbox/<ts>-<uuid>.json` into the App Group, which the app drains when it becomes active. |

### State ownership

- `AppModel` owns every service, `selectedTab` and `focusedQueueItemID`.
- `DownloadQueue.items: [DownloadItem]` is the single source of truth for this session's downloads:
  - `DownloadItem` is a `@MainActor @Observable` class with immutable `options`;
  - the runtime-only side tables (`runners`, `jobIDs`, `producedFiles`, `photoSaveStates`, `interruptedIDs`, `resumableIDs`) are `@ObservationIgnored`.
- Only unfinished or resumable items are written to `queue.json`. Completed items live on only as `HistoryEntry` rows in `history.json`, and a history entry has its own `id`, unrelated to the item's.
- `DownloadComposer.options` holds what the person is editing. Queued items carry resolved copies, with this launch's paths.
- `AppSettings.storedOptions` holds the last-used options.

### Main flows

```
Paste ──► DownloadComposer.setURLText ──► analyze() ──► YTDLPEngine.analyze ──► EngineThread ──► ytg_call("analyze")
                                                                                     │ (log lines via emit → EngineJob.deliver → onLog)
          ◄── MediaInfoDecoder.decode ◄── EngineReplyDecoder.analysisInfo ◄──────────┘
Download ─► AppModel.startDownload ─► composer.startDownload ─► resolver.resolve ─► DownloadQueue.enqueue
          ─► startEligibleItems ─► Task { run(item) } ─► engine.startIfNeeded ─► ArgumentBuilder.embeddedDownloadArguments
          ─► for await update in YTDLPEngine.download(argv:jobID:)   (AsyncStream, .unbounded)
                 Task.detached ─► EngineThread ─► ytg_call("download") ─► host: options.parse ─► EngineYoutubeDL.download
                    events: progress/log/postprocess/item/file ─► _ytdlpgui.emit ─► EngineCallbackHub ─► continuation.yield
                    requests: media.* / js.run ─► _ytdlpgui.request ─► hub.answerRequest (semaphore) ─► EngineRequestRouter
          ◄─ .finished(EngineJobResult) ─► finish(item) ─► HistoryStore.add, NotificationService, MediaLibrary (auto-save)
Cancel ──► DownloadQueue.cancel ─► YTDLPEngine.cancel ─► job flag + cancel request tasks + host "cancel" (retried until found)
            host: Job.cancel sets flag, _ytdlpgui.interrupt raises JobCancelled in the job thread
Background ► BackgroundActivity: iOS 26 BGContinuedProcessingTask (per-batch unique id), else beginBackgroundTask;
            expiry ─► DownloadQueue.interruptActiveDownloads ─► resumeInterruptedDownloads on .active
Update ───► EngineController.installUpdate ─► YTDLPEngine.installLatestUpdate ─► host updates.install_update
            (downloads, verifies SHA-256, unpacks to staging, renames over Application Support/Engine/yt-dlp)
```

### Concurrency model

- UI state is on the main actor.
- The engine layer is `Sendable`, with `Mutex`-protected state.
- Blocking Python calls run on dedicated `Thread`s (`EngineThread`) with a 16 MB stack, never on the cooperative pool.
- Python-to-Swift requests block the calling Python thread (with the GIL released) on a `DispatchSemaphore` while a detached `Task` does async AVFoundation or JavaScriptCore work. This is safe because the waiting thread is never a pool thread. It is documented in `EngineCallbackHub.answerRequest`.
- Download events travel as an `AsyncStream` consumed by a main-actor `Task` per item.
- Swift 6 language mode is on (`SWIFT_VERSION = 6.0`).

### Error propagation

- The host never raises across the bridge. `dispatch` returns `{"ok": false, "error", "traceback"}`, and `PythonBridge.c` builds the same shape without Python if the interpreter itself fails.
- Swift decodes replies into `EngineError`, `EngineJobResult.hostError` or `MediaProcessingError`.
- The queue classifies failures from yt-dlp's `ERROR:` log lines using the shared `DownloadFailure.classify`.
- Services surface errors as user-facing strings (`storageError`, `lastError`, `UpdateState.failed`).

---

## Priority 0 — Critical

**None found.** No issue plausibly causes data loss of existing files, a security vulnerability, frequent crashes or broken core functionality in normal use. The closest candidates are all P1:

- **P1-1** breaks downloads only for the rest of a session, after an update is installed while an earlier update is running.
- **P1-2** can corrupt only the download being duplicated.
- **P1-6** leaks secrets only when a person shares a log or a screenshot.

---

## Priority 1 — High Impact

### P1-1. Installing or reverting a yt-dlp update swaps out files the running engine still imports

**Definite bug. Reproduced.**

**Files / components involved**

- `PythonHost/ytdlpgui_host/updates.py`: `install_update` (l. 59), `_replace_directory` (l. 252–263), the `finally: shutil.rmtree(work_dir)` (l. 81).
- `PythonHost/ytdlpgui_host/engine.py`: `_start` / `_import_and_integrate` (`sys.path.insert(0, update_dir)`, l. 129).
- `YTDLPGUI-iOS/Engine/Runtime/YTDLPEngine.swift`: `installLatestUpdate` (l. 254), `revertToBundledVersion` (l. 270–273).
- `YTDLPGUI-iOS/Engine/Runtime/EngineConfiguration.swift`: `updateDirectory`, `hasInstalledUpdate`, `prepareUpdateFolder`.
- `YTDLPGUI-iOS/ViewModels/EngineController.swift`: `installUpdate`, `revertToBundledVersion`.
- `YTDLPGUI-iOS/Views/Settings/EngineSettingsSection.swift`: the Install and *Use Bundled Version* buttons.

**Current behaviour**

- When an update is installed, the running interpreter imported yt-dlp from `Application Support/Engine/yt-dlp` (`sys.path[0]`).
- *Install* renames that folder into the staging area, renames the new release into its place, then deletes the old one (`shutil.rmtree(work_dir)`).
- *Use Bundled Version* deletes the folder outright, on the main actor.
- Both are allowed while downloads run. Both claim to "take effect at the next launch".

**Problem**

yt-dlp imports most of its code lazily:

- `LazyLoadExtractor.real_class` calls `importlib.import_module(cls._module)` the first time an extractor is used. That covers 942 extractor modules in the pinned wheel.
- `yt_dlp_ejs.yt.solver.core()` / `lib()` read the solver JavaScript from the package folder on every call.

After the swap, the path in `sys.path` points at different files, and Python's `FileFinder` re-checks directory mtimes. So in the same session:

- **After Install (while running a previous update):** the next site not yet used imports its extractor from the *new* release against the *old* core, which is version skew. The EJS solver script is read from the new release and fails yt-dlp's pinned-hash check (`EJSBaseJCP._ALLOWED_HASHES`), falling back to other sources.
- **After *Use Bundled Version*:** every not-yet-imported extractor fails with `ModuleNotFoundError`.
- **Between the two `os.rename` calls:** any lazy import fails.

The failures surface as generic yt-dlp errors ("Download failed") that give no hint that a restart would fix them.

Reproduction with the real `_replace_directory` (Python 3.11, fake package):

```
core loaded: A
extractor loaded later: B (core is still A)        # after installing a second update
after revert: ModuleNotFoundError No module named 'fakeyt.extractor.youtube'   # after deleting the folder
```

<details><summary>Reproduction script</summary>

```python
import importlib, os, shutil, sys, tempfile
sys.path.insert(0, 'PythonHost')
from ytdlpgui_host import updates

root = tempfile.mkdtemp(); update_dir = os.path.join(root, 'Engine', 'yt-dlp')
def make_pkg(base, version):
    pkg = os.path.join(base, 'fakeyt'); os.makedirs(os.path.join(pkg, 'extractor'))
    open(os.path.join(pkg, '__init__.py'), 'w').write(f'VERSION = "{version}"\n')
    open(os.path.join(pkg, 'extractor', '__init__.py'), 'w').write('')
    for name in ('vimeo', 'youtube'):
        open(os.path.join(pkg, 'extractor', f'{name}.py'), 'w').write(f'VERSION = "{version}"\n')

make_pkg(update_dir, 'A'); sys.path.insert(0, update_dir)
import fakeyt, fakeyt.extractor
work = os.path.join(root, 'staging', 'w'); unpacked = os.path.join(work, 'unpacked'); make_pkg(unpacked, 'B')
updates._replace_directory(update_dir, unpacked, work); shutil.rmtree(work)
print(importlib.import_module('fakeyt.extractor.vimeo').VERSION, fakeyt.VERSION)   # B A
shutil.rmtree(update_dir)
importlib.import_module('fakeyt.extractor.youtube')                              # ModuleNotFoundError
```
</details>

When a bundled engine installs its first update, sessions are unaffected, because the running engine doesn't have the update folder on `sys.path`. The bug needs a second update, or a revert, in a session that is running an update. That is the normal state for anyone who keeps yt-dlp current.

**Recommendation.** Never modify or delete a folder the running interpreter may import from:

- install each update into a new versioned folder and switch a small pointer file;
- make revert remove the pointer;
- delete unused versions at the next launch, before Python starts.

**Why it matters.** Updating yt-dlp is the documented fix when a site breaks, so people will do it mid-session. Today that can make downloads fail in ways the app can't explain. The fix also makes it unnecessary to disable Install and Revert while downloads run.

**Implementation direction.** Keep all layout knowledge in Swift so the Python host needs almost no change.

1. `EngineConfiguration`:
   - add `updateRoot` = `Application Support/Engine/yt-dlp`, `versionsDirectory` = `updateRoot/versions` and `pointerFile` = `updateRoot/current`;
   - `activeUpdateDirectory: URL?` reads `current`, which holds one path component, validated with no `/` and no `..`, and returns `versions/<name>` if that folder contains `yt_dlp/`;
   - `makeNewUpdateDirectory()` returns `versions/<UUID>`, which doesn't exist yet;
   - `activate(_:)` writes `current` with `Data.write(options: .atomic)`;
   - `deactivate()` removes `current`.
2. **Migration** (legacy flat layout, where `updateRoot/yt_dlp` exists directly): in `YTDLPEngine.startSynchronously`, before `PythonRuntime.start`, move `yt_dlp/` and `yt_dlp_ejs/` into `versions/legacy-<UUID>/` and activate it. Nothing is imported yet at that point, so this is safe.
3. **Garbage collection:** in the same pre-start step, delete every `versions/*` except the active one, and delete `staging/`.
4. `startSynchronously` passes `activeUpdateDirectory` as `update_dir`. The host's `_start` is unchanged.
5. `installLatestUpdate` passes `update_dir = makeNewUpdateDirectory()`. `_replace_directory` then only performs the final `os.rename(unpacked, update_dir)`, because nothing exists there. On success Swift calls `activate`.
6. `revertToBundledVersion` becomes `deactivate()`, a single `unlink` that is fine on the main actor. The `restartRequired` logic stays as it is.
7. Update the "App data on device" table in `Docs/iOS-Architecture.md`.

**Risk / effort:** Risk **Medium** (touches engine start-up; a mistake would make an installed update fall back to the bundled copy). Effort **Medium**.

⚠ **Behaviour change.** The on-disk layout changes, and the migration must be tested:

- starting from the legacy layout;
- starting with no update;
- with a corrupt pointer file;
- with a pointer to a missing folder.

---

### P1-2. The same link can run as two jobs at once, writing the same temporary files

**Definite gap. Corruption plausible.**

**Files / components involved**

- `YTDLPGUI-iOS/ViewModels/DownloadQueue.swift`:
  - `enqueue(url:options:info:)` (l. 119) doesn't check for duplicates;
  - `enqueue(urls:options:)` (l. 139–146) does;
  - `retry(_:)`.
- `YTDLPGUI-iOS/ViewModels/DownloadComposer.swift`: `startDownload`, the analysed single-link branch (l. 347).
- `YTDLPGUI-iOS/App/AppModel.swift`: `downloadAgain` (l. 317–323).

**Current behaviour**

- Only the multi-link path skips links already waiting or running ("Those downloads are already in the queue.").
- These paths call `enqueue(url:options:info:)`, which always appends:
  - an analysed single link;
  - *Download Again* from history;
  - *Retry* of a cancelled or failed item while another item for the same link runs.
- With the default limit of two, both copies start immediately.

**Problem**

- yt-dlp names temporary files after the video (`Title [id].f137.mp4.part`, `….f140.m4a.part`, `.part-FragN`) in the shared `Partial Downloads` folder.
- The HTTP downloader opens them with `wb`/`ab` and no locking (`yt_dlp/downloader/http.py`).
- Two jobs for the same link therefore interleave writes into, or rename away, each other's files. youtube-dl issue [#21449](https://github.com/ytdl-org/youtube-dl/issues/21449) documents malformed output from exactly this.
- Different quality choices for one link still share the `.fNNN` audio stream, so the check must be by link, not by options. The existing multi-link rule already works that way.

**Recommendation.** Move the duplicate rule into the single-link `enqueue` so every entry point obeys it, and let callers react.

**Why it matters.** It prevents corrupted or failed downloads and duplicate history rows, and makes all entry points behave the same way.

**Implementation direction**

```swift
enum EnqueueOutcome {
    case added(DownloadItem)
    case alreadyPending(DownloadItem)
}

/// The waiting or running item for this link. yt-dlp names its temporary files after the video,
/// so two jobs for one link would write the same `.part` files.
func pendingItem(forURL url: String) -> DownloadItem? {
    let key = url.trimmingCharacters(in: .whitespacesAndNewlines)
    return items.first { !$0.state.isFinished && $0.sourceURL == key }
}
```

- `enqueue(url:options:info:) -> EnqueueOutcome`. Implement `enqueue(urls:)` on top of it.
- **Composer:** on `.alreadyPending`, show "That link is already in the queue." (don't clear the field) and return `false`.
- **`AppModel.downloadAgain`:** on `.alreadyPending(item)`, call `showQueueItem(item.id)` and show a status message.
- **`retry(_:)` / `retryAllFailed()`:** skip an item when `pendingItem(forURL:)` returns a different item, and report it.
- **Optional:** `run(_:)` can also assert, before starting, that no other *active* item has the same URL. This is a cheap backstop.

**Risk / effort:** Risk **Low**. Effort **Small–Medium**, because callers change signature.

⚠ **Behaviour change.** Intentionally downloading the same link twice with different options, at the same time, is no longer possible. It still works sequentially.

---

### P1-3. "Edit Options and Download" bypasses `AppModel.loadIntoComposer`

**Definite bug.**

**Files / components involved**

- `YTDLPGUI-iOS/Views/History/HistoryEntryActions.swift`: `editAndDownload()` (l. 62–68).
- `YTDLPGUI-iOS/App/AppModel.swift`: `loadIntoComposer(_:)` (l. 338). It is only called from `AppModelTests.loadIntoComposer`.
- `YTDLPGUI-iOS/ViewModels/DownloadComposer.swift`: `loadOptions(_:)` (l. 197).

**Current behaviour.** The history context menu and the detail screen run their own copy of the logic:

```swift
if let options = entry.options { model.composer.options = options }
model.composer.setURLText(entry.sourceURL, analyzeIfEnabled: true)
```

The tested method, `AppModel.loadIntoComposer`, instead does four things:

- goes through `composer.loadOptions`, which resets the app-managed fields: `outputDirectory`, `downloadArchivePath`, `cookieFilePath`, `cookieBrowser`, `ignoreUserConfig`;
- strips refused custom arguments and says which it removed;
- for entries without saved options, sets `kind` from the entry;
- clears the clipboard suggestion.

**Problem.** Compared with the tested behaviour, the UI path:

- loads refused custom arguments (for example `--exec`, `--update`) verbatim. The Download button is then disabled by the block advisory, with no hint that *Download Again* would have removed them automatically;
- copies a previous install's absolute paths into `composer.options`. `startDownload` then persists them with `settings.rememberOptions(options)`. They are harmless only because every consumer resolves paths again;
- for entries without options (older history), keeps whatever kind the composer had, so an audio entry can reload as video.

The existing test `AppModelTests.loadIntoComposer` asserts exactly the behaviour the UI doesn't use.

**Recommendation.** Make the view call `model.loadIntoComposer(entry)` and delete the inline copy.

**Why it matters.** One tested path, consistent safety messaging, and no stale paths in stored settings.

**Implementation direction**

```swift
Button { model.loadIntoComposer(entry) } label: {
    Label("Edit Options and Download", systemImage: "slider.horizontal.3")
}
```

Decide whether loading should auto-analyse. The UI passes `true` today and `loadIntoComposer` passes `false`. Analysing is more useful, because the person sees formats before editing. If you choose that, change `loadIntoComposer` to `analyzeIfEnabled: true` and update the test.

**Risk / effort:** Risk **Low**. Effort **Small**.

⚠ **Behaviour change.** Refused arguments are now removed with a message instead of blocking.

---

### P1-4. Tapping a download notification after a relaunch opens "Download Removed"

**Definite bug.**

**Files / components involved**

- `YTDLPGUI-iOS/Services/NotificationService.swift`: `deliver` stores `downloadItemID` (l. 90); `NotificationResponder`.
- `YTDLPGUI-iOS/App/AppModel.swift`: `onOpenDownload` → `showQueueItem` (l. 157, 354).
- `YTDLPGUI-iOS/Views/Queue/QueueItemDetailView.swift`: "Download Removed" (l. 50); `retainedItem` (l. 76); `.onChange(of: isInQueue)` (l. 78).
- `YTDLPGUI-iOS/ViewModels/DownloadQueue.swift`: `persistNow` saves only unfinished and resumable items (l. 726–728).
- `Shared/Models/DownloadItem.swift`: `makeHistoryEntry()` (l. 137).
- `Shared/Models/HistoryEntry.swift`.

**Current behaviour**

- Notifications are posted only while the app is in the background, and carry the `DownloadItem.id`.
- Tapping one sets `focusedQueueItemID`.
- Completed and failed items aren't saved with the queue, and a history entry gets a fresh `id` with no link back to the item.

**Problem**

- If iOS terminated the app after the notification was posted (common for a backgrounded app), the item no longer exists. The same happens if the person cleared finished items.
- The Queue tab then pushes `QueueItemDetailView` for an unknown ID. It shows "Download Removed — This download is no longer in the queue". `onChange(of: isInQueue)` never fires because the value never changes, so the misleading screen stays.
- The download actually succeeded and is in History.

**Recommendation.** Link history entries to the download that produced them, and route notification taps to the queue when the item is there, otherwise to the history entry.

**Why it matters.** A "Download complete" notification is the main way back to a background download. Today it leads to a screen that suggests the download is gone.

**Implementation direction**

1. `HistoryEntry`: add `var downloadID: UUID?`. It is optional, so synthesized `Codable` decodes old files, and it is in `Shared/`, so it is additive for macOS. `DownloadItem.makeHistoryEntry()` passes `downloadID: id`. A retried item produces several entries with the same `downloadID`. `entries` is newest first, so `first(where:)` picks the latest.
2. `AppModel.openDownload(_ id: DownloadItem.ID)`:
   - if `queue.item(withID:)` finds it, call `showQueueItem(id)`;
   - else if a history entry has that `downloadID`, set `selectedTab = .history` and `focusedHistoryEntryID = entry.id`;
   - else switch to History and show a status message.

   Wire `notifications.onOpenDownload` to it.
3. `HistoryView`: drive its `NavigationStack(path:)` from `model.focusedHistoryEntryID`, the same way `QueueView.path` mirrors `focusedQueueItemID`.
4. While there: when `QueueItemDetailView` opens for an ID that is not in the queue and has no retained item, clear `focusedQueueItemID` in `.onAppear`, or route through `openDownload`, instead of showing "Download Removed" indefinitely.

**Risk / effort:** Risk **Low**. Effort **Small–Medium**.

**Interaction:** do the `HistoryEntry` schema change together with P1-5 (one migration, one set of decoding tests).

---

### P1-5. Multi-file downloads (playlists) keep only the last file

**Definite bug.**

**Files / components involved**

- `YTDLPGUI-iOS/ViewModels/DownloadQueue.swift`: `run` sets `item.outputURL = files.last` (l. 388) and `completedFileSize` to the sum over all files (l. 389). `producedFiles` holds the full list in memory only (l. 383), and `photoFiles(for:)` (l. 670) reads it.
- `Shared/Models/DownloadItem.swift`: `makeHistoryEntry()` stores only `outputURL` (l. 141).
- `Shared/Models/HistoryEntry.swift`: `outputPath: String?`.
- `YTDLPGUI-iOS/Views/History/HistoryEntryActions.swift`, `HistoryDetailView.swift`.
- `YTDLPGUI-iOS/Views/Queue/QueueItemDetailView.swift`: `fileSection`.
- `PythonHost/ytdlpgui_host/jobs.py`: `FileReporterPP`, `_final_paths`.
- `PythonHost/ytdlpgui_host/postprocessors.py`: `MergerPP._keep_separate`.
- `YTDLPGUI-iOS/Engine/Runtime/EngineEventDecoder.swift`: the `file` event.

**Current behaviour**

- A 20-video playlist produces 20 files. The queue item and its history entry point at the last one.
- "Size" shows the total of all 20, while "File" names one.
- In History, *Open*, *Share* and *Save to Photos* reach only that one file.
- The complete list lives in `producedFiles`, which is lost on relaunch.
- **Single videos are affected too.** When AVFoundation can't merge a pair (for example WebM-only DASH), `MergerPP._keep_separate` keeps both files, and `jobs._final_paths` reports the main video first and the kept audio after it. `files.last` therefore makes the queue row, the "File" name and the history entry point at the **audio** file, not the video.

**Problem**

- History, the durable record, misdescribes playlist downloads and can't act on them.
- "File moved or deleted" is judged by one file only.
- For kept-separate downloads, *Open* and *Share* offer the audio track instead of the video.

**Recommendation.** Record every output file.

**Why it matters.** Playlists are a headline feature, and today their history entries are only partly usable.

**Implementation direction**

1. `DownloadItem`: add `var outputURLs: [URL] = []`, set from `files` in `run`. Keep `outputURL` as the primary file for existing UI and macOS, but stop choosing it with `files.last`:
   - either mark the main file in the host's `file` event (`{"type": "file", "path", "main": true|false}` from `FileReporterPP`, where `False` is a `KEPT_FILES_KEY` companion), decode it in `EngineEventDecoder`, and use the last *main* file;
   - or, as a smaller change, use the first file reported.

   Add a queue test in which a job reports a video and then a kept audio file, and assert that `outputURL` is the video.
2. `HistoryEntry`:
   - add `var outputPaths: [String]?`, optional and additive;
   - add `var outputURLs: [URL]` that resolves each path with the existing `HistoryEntry.resolve(storedPath:documentsDirectory:)` and falls back to `[outputURL]`;
   - cap what is stored (for example the first 500 paths) so `history.json` stays bounded.
3. **History detail:** when there is more than one file, add a "Files (n)" section listing the names. For *Share*, use `ShareLink(items: existingURLs)`. For *Open*, use `.quickLookPreview($selection, in: existingURLs)`. *Save to Photos* iterates the eligible files, the same way `DownloadQueue.saveToPhotos` does.
4. Judge "missing" as "all files missing", or show "3 of 20 files missing".
5. **Optional:** for playlists (files in a common subfolder), offer "Show in Files" with a `shareddocuments://` URL for that folder, built the same way as `StorageManager.filesAppURL`.

**Risk / effort:** Risk **Low–Medium** (a `Shared` model change; macOS keeps compiling because the fields are optional). Effort **Medium**.

⚠ **Behaviour change** in the history UI.

**Interaction:** P2-2 (file-status cache) should account for multiple paths. P2-3 (Photos eligibility) touches the same `producedFiles` code.

---

### P1-6. Passwords and proxy credentials appear in the command preview and each download's log

**Definite bug. Security / privacy.**

**Files / components involved**

- `YTDLPGUI-iOS/ViewModels/DownloadQueue.swift`: `run` appends `"$ " + ShellQuoting.commandLine(...)` to `item.log` (l. 354).
- `YTDLPGUI-iOS/ViewModels/DownloadComposer.swift`: `commandPreview` (l. 105).
- `Shared/Utilities/ShellQuoting.swift`: `commandLine` (l. 27).
- `YTDLPGUI-iOS/Views/Components/LogConsoleView.swift`: `ShareLink` of the log.
- Persistence: `HistoryEntry.options`, `AppSettings.rememberOptions`, `QueueStore`.

**Current behaviour**

- The app explicitly tells people to put credentials in custom arguments:
  - `compat.py`: "Pass it in the custom arguments instead, for example with --password or --twofactor";
  - `options.py`: "Pass the password with --password as well".
- `--proxy http://user:pass@host` has its own field.
- The full argument vector, secrets included, is:
  - shown in the Command Preview, with a Copy button;
  - written as the first line of every download's log, which has a Share button.
- yt-dlp masks these for its own output (`Config.hide_login_info`: `-p`, `--password`, `-u`, `--username`, `--video-password`, `--ap-password`, `--ap-username` become `PRIVATE`). The app's own echo of the command masks nothing.

**Problem**

- Logs are what people attach to bug reports. Credentials leak through a feature meant for diagnosis.
- Separately, the same secrets are persisted in plain JSON in `history.json` and in `UserDefaults`, both of which are included in device backups.
- Cookies, by contrast, are deliberately kept out of backups (`CookieStore.store`: "Session cookies are credentials").

**Recommendation**

- **(a)** Redact secrets wherever the command line is shown or logged. The argument vector passed to the engine is unchanged.
- **(b)** Decide, as a product decision, how secret-bearing options are persisted.

**Why it matters.** It matches yt-dlp's own behaviour and the app's own stance on cookies.

**Implementation direction**

- **(a)** In `Shared/Utilities/ShellQuoting.swift`, add `static func redactingSecrets(_ arguments: [String]) -> [String]`:
  - **Plain secret options:** mirror yt-dlp's list plus `-2`/`--twofactor` and `--client-certificate-password`. Handle both `--opt value` and `--opt=value`, like yt-dlp's `_scrub_eq`.
  - **Proxies:** replace the userinfo of `--proxy` and `--geo-verification-proxy` values (`scheme://PRIVATE@host:port`).
  - **Headers:** mask `--add-headers` values whose header name is `Authorization`, `Proxy-Authorization` or `Cookie`.

  Use it in `DownloadQueue.run`'s log line and in `DownloadComposer.commandPreview`. Keep the preview footer honest, for example "Passwords are shown as PRIVATE". The macOS app shares this utility and benefits too.
- **(b)** Options, which need a decision:
  1. Strip secret-bearing arguments from the `options` stored in `HistoryEntry` and in `rememberOptions`. *Download Again* then reports "Removed ‘--password’", like refused arguments today.
  2. Keep them, but exclude `history.json` from backup. That loses history on restore, so it's the weaker option.

  `queue.json` must keep them so interrupted downloads resume. Mark it `isExcludedFromBackup`, which is cheap because it is transient.

**Risk / effort:** Risk **Low** for (a). **Medium** for (b), which changes replay behaviour. Effort **Small** for (a), **Small–Medium** for (b).

⚠ **Behaviour change:** *Copy Command* copies the redacted form.

---

## Priority 2 — Medium Impact

### P2-1. Timed-out JavaScript solver runs are abandoned with no bound

**Potential risk.**

**Files / components involved**

- `YTDLPGUI-iOS/Engine/JavaScript/JavaScriptChallengeRunner.swift`: `run` (l. 66–83), which uses `EngineThread.detach` (l. 70) and a `DispatchQueue` deadline (l. 77).
- `PythonHost/ytdlpgui_host/javascript.py`: `SOLVER_TIMEOUT = 60`.

**Current behaviour.** On timeout or cancellation, the caller gets an error immediately. The evaluation thread (16 MB stack reservation, its own `JSVirtualMachine` holding a multi-megabyte player script) keeps interpreting until the script ends. This is documented and deliberate: JavaScriptCore has no public API to interrupt a running script.

**Problem.** Nothing limits how many abandoned evaluations run at once. On a slow device where solving approaches the 60 s limit, every retry or new YouTube job starts another CPU-bound interpreter competing with the ones still running. Each run then gets slower, so more runs time out: a feedback loop that burns battery, and holds memory while the app is in the background. Solving normally takes well under a second, which is why this is a risk, not a bug.

**Recommendation.** Cap concurrent evaluations and make abandoned runs visible in diagnostics.

**Why it matters.** It stops a pathological player from consuming CPU and memory without limit.

**Implementation direction**

- Add a process-wide `Mutex<Int>` counting running evaluation threads. It is incremented before `detach` and decremented when `evaluate` returns, including for abandoned runs.
- When the count is at a cap (for example 2 + `ProcessInfo.activeProcessorCount / 2`), fail fast with a new `JavaScriptRunnerError.busy`, or wait for a slot within the same deadline. yt-dlp then reports the challenge failure normally.
- Log with `os.Logger` when a run is abandoned and when it finally finishes, including elapsed time, so on-device reports show it.

The private `JSContextGroupSetExecutionTimeLimit` (`JSContextRefPrivate.h`) could interrupt scripts. It is SPI and its watchdog [polls only once per VM entry](https://github.com/BabylonJS/JsRuntimeHost/issues/241). It isn't recommended even for a sideloaded app.

**Risk / effort:** Risk **Low**. Effort **Small**.

---

### P2-2. History views check the file system on the main thread, per row, on every render

**Potential risk (performance).**

**Files / components involved**

- `Shared/Models/HistoryEntry.swift`: `outputURL` (l. 53; `fileExists`, then re-rooting under each `Documents` component), `fileExists` (l. 93).
- `YTDLPGUI-iOS/Views/History/HistoryRowView.swift`: `isFileMissing` (l. 50), which is evaluated twice per row (in the body and in `accessibilityStatus`); `existingOutputURL` (l. 55).
- `YTDLPGUI-iOS/Views/History/HistoryView.swift`: the toolbar's `.disabled(!history.entries.contains(where: \.isFileMissing))` (l. 124).

**Current behaviour**

- Each `isFileMissing` costs 2–4 `stat` calls, more for stale paths from an earlier install.
- The toolbar check walks all entries (up to `HistoryStore.maximumEntries = 1_000`) on every evaluation of `HistoryView.body`. That includes every keystroke in the search field, because `searchText` is `@State` of that view.

**Problem.** Main-thread file-system work in proportion to history size, on the typing path. P1-5 multiplies it by the number of files per entry.

**Recommendation.** Resolve file locations once, off the main actor, and have views read the cached result.

**Why it matters.** It keeps the History tab smooth for heavy users and makes P1-5 affordable.

**Implementation direction**

- In `HistoryStore` (Shared), add `private(set) var fileStatus: [HistoryEntry.ID: FileStatus]`. `FileStatus` holds the resolved existing URLs, or `.missing`.
- Fill it in `refreshFileStatus()`, which runs `Task.detached` over a snapshot of entries. Call it after `load()`, after `add`, and when the scene becomes active: files can be deleted in the Files app while the app is backgrounded.
- Rows, the detail view and `removeMissingFiles()` read the cache. `hasMissingFiles` becomes a stored property that is updated with it.
- Measure first with Instruments (Time Profiler, History tab, 1,000 entries, typing in search) to confirm the gain.

**Risk / effort:** Risk **Low–Medium** (a cache can go stale, so refresh on `.active`). Effort **Medium**.

---

### P2-3. Photos eligibility is decided with synchronous AVFoundation checks from view bodies

**Potential risk (performance).**

**Files / components involved**

- `YTDLPGUI-iOS/Services/MediaLibrary.swift`: `canSaveToPhotos` calls `UIVideoAtPathIsCompatibleWithSavedPhotosAlbum` (l. 54).
- `YTDLPGUI-iOS/ViewModels/DownloadQueue.swift`: `canSaveToPhotos` / `photoFiles(for:)` (l. 636, 670), also called from `finish` (l. 573).
- `YTDLPGUI-iOS/Views/Queue/QueueItemDetailView.swift` (l. 128).
- `YTDLPGUI-iOS/Views/Queue/QueueItemActions.swift` (l. 24).
- `YTDLPGUI-iOS/Views/History/HistoryEntryActions.swift` (l. 26).

**Current behaviour.** Each call inspects every produced video to decide compatibility, synchronously on the main actor, from inside view bodies and context menus. A finished 50-video playlist's detail view inspects 50 files every time its body is evaluated.

**Problem.** This can cause jank on the Queue detail screen and in context menus, and it gets worse with P1-5.

**Recommendation.** Decide eligibility once, when an item completes (off the main actor), store the result, and have views read it. For history, decide lazily in the detail view's `.task`.

**Why it matters.** It removes synchronous media inspection from the render path.

**Implementation direction**

- In `finish`, start `Task.detached { files.filter(MediaLibrary.isPhotosCompatible) }`. That needs a `nonisolated static` variant.
- Store the result as `photoEligibleFiles[item.id]` next to `producedFiles`, and have `canSaveToPhotos(item)` read it.
- Start the auto-save only after eligibility is known.

**Risk / effort:** Risk **Low**. Effort **Small**.

**Interaction:** do this together with P1-5.

---

## Priority 3 — Nice to Have

### P3-1. Logging uses two subsystems, and download lifecycle transitions aren't logged

**Files / components involved**

- `io.github.ytdlpgui.YTDLPGUI`: `YTDLPEngine`, `EngineCallbackHub`, `MediaProcessor`, `SharedLinkInbox`, `HistoryStore`.
- `io.github.ytdlpgui.YTDLPGUI.iOS`: `DownloadQueue`, `QueueStore`, `BackgroundActivity`, `NotificationService`, `StorageManager`, `CookieStore`.

**Current behaviour.** A `log stream --predicate 'subsystem == …'` sees half the app. `DownloadQueue` logs only failure titles, not starts, cancellations, background interruptions, resumes or job IDs.

**Problem.** Diagnosing a download that stalled in the background on a device requires rebuilding with extra logging.

**Recommendation.** Use one subsystem (the bundle identifier) through a small `enum AppLog { static let engine = Logger(…) … }`. Log queue transitions at `info`: item ID, job ID, state, and the URL with `privacy: .private`.

**Risk / effort:** Risk **Low**. Effort **Small**.

### P3-2. Host failures are missing from the download's log

**Files / components involved:** `DownloadQueue.run`, the `result.hostError` branch.

**Current behaviour.** A host error (for example "yt-dlp rejected the arguments: no such option: --foo") becomes `DownloadFailure(kind: .unknown, underlyingMessage:)` but is never appended to `item.log`.

**Problem.** *Show Log* and *Share log* omit the one line that explains the failure.

**Recommendation.** Append `"ERROR: \(hostError)"` to `item.log` before `finish`, so the log reads like the command-line tool's output.

**Risk / effort:** Risk **Low**. Effort **Small**.

### P3-3. `detectedURLs` is re-parsed many times per render

**Files / components involved:** `DownloadComposer.detectedURLs` (l. 80), used by `hasValidURL`, `isMultipleURLs`, `canAnalyze`, `canDownload`, `downloadButtonTitle`, `commandPreview` and `LinkSection`.

**Current behaviour.** Each access calls `URLDetection.urlsFromLines`. For text that isn't a bare URL, that creates a new `NSDataDetector` each time.

**Problem.** The same work repeats many times per keystroke while typing or pasting free text. The cost is small but pointless.

**Recommendation.** Make it `private(set) var detectedURLs: [String] = []`, recomputed in `urlText`'s `didSet`, the only input. This is derived state stored once.

**Risk / effort:** Risk **Low** (`didSet` already runs on every change). Effort **Small**.

### P3-4. Log console rows are identified by array offset

**Files / components involved:** `LogConsoleView` (`ForEach(Array(visibleLines.enumerated()), id: \.offset)`, l. 90).

**Current behaviour.** Once `LogBuffer` reaches its 2,000-line cap, every new line shifts every offset.

**Problem.** Every visible row changes identity on each new line: rows are rebuilt and text selection is lost while a download is live.

**Recommendation.** Identify a line by its absolute number, `totalLineCount - lines.count + offset`, computed before filtering.

**Risk / effort:** Risk **Low**. Effort **Small**.

### P3-5. The app-wide status message belongs to the composer

**Files / components involved**

- `DownloadComposer.showStatus` / `statusMessage` (l. 434), rendered by `RootView`'s `StatusToastHost`.
- Called from `AppModel`, `HistoryDetailView`, `HistoryView`, `HistoryEntryActions` and `QueueItemDetailView` ("Link copied.", "Saved to Photos.").

**Problem.** History and Queue views depend on the Download screen's view model for an unrelated concern.

**Recommendation.** Move `statusMessage` and `showStatus` to `AppModel`, or to a small `@Observable StatusCenter` that `AppModel` owns. The composer keeps calling it through `AppModel`.

**Risk / effort:** Risk **Low**. Effort **Small**.

### P3-6. iPad multi-window would share navigation state (verify first)

**Files / components involved**

- `YTDLPGUIMobileApp` (`WindowGroup`).
- `AppModel.selectedTab` and `focusedQueueItemID`.
- `INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES`, with no explicit `UIApplicationSupportsMultipleScenes`.

**Current behaviour.** Not verified. If the generated manifest enables multiple scenes, every window shares one `AppModel`, so changing tabs or opening an item in one window changes all of them.

**Recommendation.** Check the built `Info.plist`. If multi-window is on and not wanted, set `INFOPLIST_KEY_UIApplicationSupportsMultipleScenes = NO`. If it is wanted, move `selectedTab` and the navigation paths into per-scene `@SceneStorage` or `@State`, and keep `AppModel` for shared data.

**Risk / effort:** Risk **Low**. Effort **Small** (disable) to **Medium** (per-scene state).

### P3-7. Last-used options are remembered in two places, one with resolved paths

**Files / components involved:** `DownloadQueue.enqueue(url:options:info:)` (l. 132) and `DownloadComposer.startDownload` (l. 359), both calling `settings.rememberOptions`.

**Current behaviour**

- The queue remembers the *resolved* options (absolute cookie, archive and output paths) on every enqueue: Share sheet, Shortcuts, *Download Again*, and each link of a multi-link paste.
- The composer then overwrites them with the unresolved ones.

**Problem**

- Which flows change "last used options" is implicit.
- Stale absolute paths reach `UserDefaults`. `AppSettings.init` resets only `outputDirectory`.
- A 50-link paste encodes and writes the options 51 times.

**Recommendation**

- Remove the call from `DownloadQueue`.
- Have `rememberOptions` store the editable form, with managed fields cleared (`DownloadComposer.editableOptions`).
- Call it from the explicit-choice entry points: the composer, and *Download Again* if that is intended.

**Risk / effort:** Risk **Low**. Effort **Small**.

⚠ **Behaviour change** in which options the Share sheet and Shortcuts use next.

---

## Testing Recommendations

The existing fakes cover every test below: `FakeDownloadEngine`, `FakeAnalysisEngine`, `FakeEngineRuntime`, `AppTestEnvironment` (including `makeRelaunchedQueue()` and `makeAppModel()`), and the Python `tests/support.py`.

### Python host (`PythonHost/tests/test_updates.py`)

- **An engine running from an update keeps working after a second install.** Configure from update A, install B into a new folder (P1-1 layout), then import an extractor module that wasn't loaded yet. It must come from A. Guards against the version skew.
- **Installing into a folder that doesn't exist.** `install_update` with a fresh `update_dir` leaves no `previous` folder and deletes nothing outside `staging_dir`. Guards the new contract.

### Swift engine (`YTDLPGUI-iOSTests/Engine/`)

- **`EngineConfiguration` layout** (temporary directories):
  - legacy flat layout migrates to `versions/legacy-*` with the pointer set;
  - a pointer naming a missing folder, `..`, or a nested path means "no update";
  - garbage collection keeps only the active version;
  - `deactivate()` deletes nothing but the pointer.

  Guards P1-1 and its migration.
- **`JavaScriptChallengeRunner` cap.** With more long-running scripts than the cap, the extra `run` fails with `.busy` promptly, and a slot frees when an abandoned script ends. Guards P2-1.

### Queue and AppModel (`YTDLPGUI-iOSTests/App/`)

- **Duplicate links.** For analysed single links, *Download Again* and *Retry*: enqueueing a link that is waiting or running returns `.alreadyPending` and starts no second job (`FakeDownloadEngine` job count stays 1). Guards P1-2.
- **Edit Options and Download:**
  - an entry with `--exec … --no-mtime` loads with `--no-mtime` only and a status message;
  - an entry without options loads with the entry's `kind`;
  - `composer.options.cookieFilePath` is empty.

  Test through `AppModel.loadIntoComposer`, which the view must call. Guards P1-3.
- **Notification routing:**
  - finish an item and call `openDownload(id)`: it goes to the queue detail;
  - build `makeRelaunchedQueue()` or clear finished items, then call `openDownload(id)`: it goes to the History tab with `focusedHistoryEntryID` set to the entry whose `downloadID == id`;
  - an unknown ID goes to History with no pushed screen.

  Guards P1-4.
- **Multi-file results.** A job that sends three `.file` events and succeeds produces a history entry with three `outputPaths`, `fileSizeBytes` equal to their sum, and `outputURLs` that resolve after re-rooting (`makeDownloadedFile`). Guards P1-5.
- **Kept-separate video.** A job reports `clip.mp4`, then `clip.m4a` (a kept companion), and succeeds. `item.outputURL` and the history entry's primary file are `clip.mp4`. Guards the `files.last` bug in P1-5. On the Python side (`test_download.py`), assert that `FileReporterPP` marks the companion as not main, if you choose the `main` flag.
- **Log redaction.** A download with custom arguments `--password s3cret --proxy http://u:p@h:1` has a first log line without `s3cret` or `u:p`, while `FakeDownloadEngine` received the unredacted argv. Guards P1-6 and ensures the engine still gets real credentials.
- **Host error in log.** `job.fail(hostError: "boom")` produces a failed item whose `log.lines` contains `ERROR: boom`. Guards P3-2.
- **`BackgroundActivity`** (untested today; construct with `requestsBackgroundTime: false` and an injected `setIdleTimerDisabled`):
  - the idle timer is disabled only while `keepScreenAwake && activeCount > 0 && phase == .active`;
  - it is re-enabled when the queue drains or the scene leaves `.active`.

  Guards the screen-lock behaviour the Settings toggle promises.
- **`EngineController` updates** (untested today; use `FakeEngineRuntime`):
  - `checkForUpdates` → `.available` / `.upToDate`;
  - `installUpdate` → `.installed` with `isRestartRequired == true`;
  - `revertToBundledVersion` → `.idle`, with `isRestartRequired` following the runtime;
  - repeated taps while `.installing` are ignored.

  Guards the Settings › Engine state machine.

### Shared (macOS test target `YTDLPGUITests`, which already covers `Shared/`)

- **`ShellQuoting.redactingSecrets`:**
  - `--password x`, `--password=x`, `-p x` and `-2 123456` are masked;
  - `-u` / `--username` are masked, as yt-dlp does;
  - `--proxy socks5://a:b@h:1` becomes `socks5://PRIVATE@h:1`;
  - `--add-headers "Authorization:Bearer t"` is masked;
  - `--add-headers "Referer:x"` is kept;
  - a missing value at the end of the list doesn't crash.
- **`HistoryEntry` backward compatibility.** Decoding a `history.json` written before `downloadID` and `outputPaths` existed succeeds, with both `nil`. Extend `DownloadOptionsDecodingTests`, which already decodes a history entry.

---

## Modernization Opportunities

Only migrations with a concrete payoff are listed. The codebase already uses current APIs throughout: `@Observable`, `Mutex`, typed throws, `ScrollPosition`, `onGeometryChange`, `Tab`/`sidebarAdaptable`, `ContentUnavailableView`, App Intents and `BGContinuedProcessingTask`.

1. **`ShareLink(items:)` and `quickLookPreview(_:in:)`** for multi-file entries (with P1-5). The payoff is sharing or previewing a whole playlist in one action instead of one file.
2. **`Observations` (SE-0475) instead of re-arming `withObservationTracking`**, once the deployment target is iOS 26. `DownloadQueue.observeConcurrencyLimit` re-registers itself on every change. A `for await limit in Observations({ settings.maximumConcurrentDownloads })` loop is simpler and can't be forgotten. `Observations` [requires OS 26](https://useyourloaf.com/blog/swift-observations-asyncsequence-for-state-changes/), and the target is iOS 18, so **defer** this.
3. **`@SceneStorage` for per-window navigation**, only if P3-6 finds multi-window enabled and wanted.

**Not recommended:**

- Swift 6.2 default main-actor isolation: a sweeping annotation change with no behavioural gain.
- SwiftData for history: `HistoryStore` documents why JSON was chosen, and that still holds.
- Replacing the semaphore bridge in `EngineCallbackHub.answerRequest`: the C callback is synchronous by design.
- Replacing the `DispatchQueue` deadline in `JavaScriptChallengeRunner`: it works, and `FirstOutcome` already handles the race.

---

## Simplification / Cleanup Opportunities

- **Remove duplicated logic:** the inline `editAndDownload()` in `HistoryEntryActions.swift`, replaced by `AppModel.loadIntoComposer` (P1-3).
- **Remove dead code (iOS):**
  - `EngineError.notStarted`: never thrown by production code. Only `FakeAnalysisEngine`'s default outcome in `AppTestSupport.swift` uses it; switch that to `.cancelled` or a test error when you remove it.
  - `YTDLPEngine.isStarted`: unused.
  - `MediaLibrary.requestAuthorizationIfNeeded()`: unused; `saveToPhotos` asks for authorization itself.
  - `AppModel.hasWorkInProgress`: used only by a test. Remove it or use it.
- **Consolidate option resolution:**
  - `DownloadOptionsResolver` is built three times (`AppModel`, `DownloadQueue`, `DownloadComposer`);
  - options are resolved up to three times per queued link (`AppModel.receiveSharedLinks`, `enqueueFromShortcut` and `downloadAgain`, then `DownloadQueue.enqueue`, then `DownloadQueue.run`).

  Inject one resolver, and resolve only in `enqueue` and in `run`: `run` must resolve because saved items can come from an earlier container. Drop the pre-resolution in `AppModel`.
- **One owner for "last used options"** (P3-7).
- **Share-inbox format in one file.** `SharedLinkInbox.swift` and `YTDLPGUI-iOS-Share/InboxWriter.swift` duplicate the schema "keep the two in step" by comment. Put the `Entry` type, `formatVersion`, `appGroupIdentifier` and the file-name format in one small file that is a member of both targets. An extension can compile a source file even though it can't link the app. The duplication, and the drift risk with it, disappears.
- **`HistoryStore.flush()` rewrites even when nothing is pending.** `saveTask` is never reset after a successful save. Set `saveTask = nil` at the end of the scheduled task. This is in `Shared/`, a trivial fix.
- **Optional split of `DownloadQueue`** (745 lines). Photo-save state and actions (`photoSaveStates`, `producedFiles`, `photoFiles`, `saveToPhotos`, `canSaveToPhotos`) form a separate concern and are what P1-5 and P2-3 touch. Extract a small `@MainActor` `PhotoSaveCoordinator` if those changes make the file harder to follow. Don't split scheduling and event application: they share state tightly.

---

## Suggested Implementation Order

1. **P1-3** (Edit Options → `loadIntoComposer`). Tiny, isolated, and removes a duplicate path before other option-flow changes.
2. **P1-2** (duplicate-link rule in `DownloadQueue`). Independent. Adds the `EnqueueOutcome` API that later steps (*Download Again*, routing) use.
3. **P1-6 (a)** (redaction in `Shared/ShellQuoting`). Independent; add tests to both targets. Decide **P1-6 (b)** with the product owner. It changes how history is replayed, so do it before step 5 settles the `HistoryEntry` shape.
4. **P1-1** (versioned update folders and pointer). Engine-only, independent of UI work. Test the migration on device (the Settings › Engine flow is listed as not yet exercised in `Continuation.md`).
5. **`HistoryEntry` schema:** add `downloadID` and `outputPaths` in one change, with backward-compatibility decoding tests, and build the macOS target. This unblocks steps 6 and 7.
6. **P1-5 with P2-3** (multi-file output, then Photos eligibility computed once). Same code (`producedFiles`, `photoFiles`). Consider the optional `PhotoSaveCoordinator` extraction here.
7. **P1-4** (notification routing: `AppModel.openDownload`, the History path binding). Needs `downloadID` from step 5.
8. **P2-2** (history file-status cache). After step 6, because multi-file entries change what is checked.
9. **P2-1** (JavaScript cap).
10. **P3** items and cleanups, in any order. P3-7 fits naturally after step 1; P3-1 logging helps verify steps 4 and 7 on device.

---

## Final Review Checklist

Status 2026-09-26: ticked items are implemented on `claude/vigilant-ritchie-nmba4d`. The Python host suite passes there, but no Swift was compiled or run (no Xcode in that environment). See `Continuation.md` for what to verify on a Mac and a device.

- [x] Installing a second yt-dlp update, or choosing *Use Bundled Version*, never renames or deletes the folder the running engine imported. A download of a not-yet-used site still works in the same session.
- [x] Old update folders are removed at the next launch. A legacy flat update folder is migrated and still used.
- [x] A link that is waiting or running can't be queued again from the composer, *Download Again* or *Retry*. The person is told and shown the existing item.
- [x] *Edit Options and Download* calls `AppModel.loadIntoComposer`, and the inline copy is gone. Refused arguments are removed with a message, and an entry without options loads its own kind.
- [x] Tapping a completion notification after a relaunch or after *Clear Finished* opens that download's History entry, not "Download Removed".
- [x] A playlist's history entry lists, shares and saves to Photos all of its files, and its size matches the files it lists.
- [x] When video and audio are kept separately, the queue row and history entry name the video file, not the audio.
- [x] The command preview and every download log show `PRIVATE` for passwords, the two-factor code, the client certificate password, proxy credentials and auth headers. The engine still receives the real values.
- [x] A decision on persisting secret-bearing options is recorded and implemented. `queue.json` is excluded from backup.
- [x] Abandoned JavaScript solver runs are capped and logged.
- [x] The History tab does no per-row file-system work in view bodies. Queue and History views do no synchronous Photos-compatibility checks.
- [x] One logging subsystem is used throughout, and queue transitions are logged with item and job IDs.
- [x] Host errors appear in the download's log.
- [ ] `history.json` files written before this change still decode, and the macOS target builds and passes its tests. *(Decoding test added; not yet run.)*
- [ ] The new tests listed in *Testing Recommendations* exist and pass: Python host suite, iOS unit tests on device, macOS suite. *(All exist; the Python host suite passes; the iOS and macOS suites haven't been run yet.)*
- [x] `Docs/iOS-Architecture.md` reflects the new update layout and the `HistoryEntry` fields.

---

## References

Sources used to verify platform and library behaviour cited above:

- yt-dlp 2026.8.19 (pinned wheel) source:
  - `yt_dlp/extractor/lazy_extractors.py` (`LazyLoadExtractor.real_class` → `importlib.import_module`);
  - `yt_dlp/extractor/youtube/jsc/_builtin/ejs.py` (hash-checked solver scripts);
  - `yt_dlp/downloader/http.py` (`open_mode` `wb`/`ab`, no locking);
  - `yt_dlp/utils/_utils.py` (`Config.hide_login_info`).
- `yt_dlp_ejs` 0.8.0: `yt_dlp_ejs/yt/solver/__init__.py` (`importlib.resources` read per call).
- Python `importlib`: [FileFinder caches directory contents and re-checks with stat calls](https://docs.python.org/3/library/importlib.html).
- youtube-dl: [Multiple instances downloading the same video causes malformed output (#21449)](https://github.com/ytdl-org/youtube-dl/issues/21449).
- Apple: [UNUserNotificationCenter delegate must be set before the app finishes launching](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate/usernotificationcenter(_:didreceive:withcompletionhandler:)). The app sets it in `AppModel.init`, from `App.init`, so this is fine.
- Apple: [`beginBackgroundTask(expirationHandler:)`: the expiration handler runs on the main thread](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(expirationhandler:)). That justifies `MainActor.assumeIsolated` in `BackgroundActivity`.
- Apple Developer Forums, DTS: [register each unique `BGContinuedProcessingTask` identifier before submitting; registration after launch is allowed](https://developer.apple.com/forums/thread/799126). This matches `BackgroundActivity.submitContinuedProcessing`.
- WebKit: [`JSContextRefPrivate.h` (`JSContextGroupSetExecutionTimeLimit` is private)](https://github.com/WebKit/webkit/blob/main/Source/JavaScriptCore/API/JSContextRefPrivate.h); [watchdog polls once per VM entry](https://github.com/BabylonJS/JsRuntimeHost/issues/241).
- Swift: [SE-0475 `Observations`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0475-observed.md), [available from OS 26 only](https://useyourloaf.com/blog/swift-observations-asyncsequence-for-state-changes/).
