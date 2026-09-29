# iOS dark interface refresh

The iPhone and iPad interface now uses a near-black canvas, blue accents, opaque content cards,
rounded typography and native Liquid Glass controls. The Download screen has a recessed link
field and distinct video/audio selection cards. Queue, History, Settings, advanced options and
media detail screens share the palette.

Glass is kept on actions and navigation. SwiftUI's native tabs, toolbars, `.glass` and
`.glassProminent` styles pick up the updated iOS 27 rendering. Related link controls share a
`GlassEffectContainer`. See Apple's [Liquid Glass guidance](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
and [SwiftUI updates](https://developer.apple.com/videos/play/wwdc2026/269/).

Dark is the default for new settings and Reset All Settings. Previously saved Light or System
choices are preserved. At accessibility text sizes, format choices stack vertically. Reduce
Transparency selects bordered controls and solid toast backgrounds; iOS 18 uses bordered
controls. The newly introduced analysis and toast animations respect Reduce Motion.

## Device evidence

Screenshots were captured on a physical iPhone 16 Pro Max running iOS 27.2, using Xcode 27.2.
The before image is the app installed before this change; the after images come from the UI
test attachments. The offline UI tests override appearance and text size without changing the
stored appearance preference. The format-selection test restores the original format.

[Open the screenshot gallery](index.html).

## Verification

**Final result: 28 passed, 0 failed, 0 skipped.** See [the exported result summary](test-summary.json), with the personal device name and identifier removed.

The focused run exercises `AppearanceUITests`, `AppSettingsTests` and `DownloadComposerTests`.
It covers dark and light rendering, the largest accessibility text size, video/audio selection,
Advanced Options navigation, all four tabs, default/reset appearance and option persistence.

The download engine and shared/macOS code were not changed. These checks do not validate a
new live download, iPad runtime layout, iOS 18 runtime rendering or a manual VoiceOver session.
Reduce Transparency and Reduce Motion fallbacks were reviewed in source, not toggled on the
physical device.
