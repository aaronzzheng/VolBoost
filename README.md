# VolBoost

Per-app output volume and boost for macOS, in the menu bar. No Dock icon, no window,
no dependencies, no App Store paperwork.

I got annoyed that macOS won't let me set the volume for one specific app, so I told
Claude to build this.

Requires macOS 14.2+ (Core Audio process taps) and Swift 5.9+.

## Build & run

```bash
./build-app.sh --install     # release build, copy to /Applications, launch
./build-app.sh               # just produce ./VolBoost.app
./build-app.sh --universal   # arm64 + x86_64
```

`swift build && .build/debug/VolBoost` also works for quick iteration, but the raw
binary has no `Info.plist`, so the audio-recording prompt and `LSUIElement` behavior
only work from the `.app` bundle.

The bundle is ad-hoc signed (`codesign --sign -`). No developer account, provisioning
profile, or notarization is involved.

## Permission

Tapping another process's audio requires macOS audio-recording access. The first time
you move a slider or hit mute, macOS prompts; VolBoost also shows a one-line
explanation if the tap is refused, with a button to
**System Settings → Privacy & Security → Microphone**.

Because the bundle is ad-hoc signed, its code identity is its binary hash — macOS
treats every rebuild as a different app and asks again. Build once, copy to
`/Applications`, grant once.

## Using it

Click the menu bar icon. Every app currently producing output gets a row:

| Control | Effect |
|---|---|
| Slider | 0–100% output gain, applied live |
| Speaker button | Mute / unmute that app |
| Bolt button | Enable boost — slider range becomes 0–400% |
| Launch at login | Registers the bundle via `SMAppService.mainApp` |

Volumes are remembered. Settings are keyed by bundle identifier and stored in
`UserDefaults`, so muting Discord or dropping it to 40% sticks — quit it, reboot, and
it comes back at 40% the moment it plays audio again. Drag an app back to 100% and
unmute it and VolBoost forgets it entirely rather than storing a no-op.

A process with no bundle identifier (some helpers) still works for the current
session, it just cannot be recognised next launch.

Right-click the menu bar icon (or use **Quit** in the popover) to exit.

VolBoost does not launch at login until you flip that switch — the popover reads its
state back from the system registry each time it opens, so it always agrees with
**System Settings → General → Login Items**. `SMAppService` registers whichever copy of
the bundle is running, so turn it on from the copy you intend to keep (`/Applications`),
not from a build directory.

## How it works

`Sources/VolBoost/`

- **`VolBoostApp.swift`** — `@main` + `AppDelegate`: status item, popover, `.accessory`
  activation policy.
- **`AudioTapManager.swift`** — all Core Audio logic. Polls
  `kAudioHardwarePropertyProcessObjectList` every 1.5s for processes with
  `kAudioProcessPropertyIsRunningOutput == 1`. When you first adjust an app, it builds a
  `TapSession`: a `CATapDescription(stereoMixdownOfProcesses:)` tap with
  `muteBehavior = .mutedWhenTapped`, wrapped in a private aggregate device whose main
  sub-device is the current default output. Its `AudioDeviceIOProc` reads the tapped
  float samples, multiplies by gain, and writes them to the output device — so the app's
  direct path is silenced and ours replaces it.
- **`PopoverView.swift`** — the SwiftUI popover.

`LoginItem` (in `VolBoostApp.swift`) holds no state of its own; `isEnabled` is derived
from `SMAppService.mainApp.status`, so toggling it off in System Settings is reflected
the next time the popover opens.

Gain is a single `Float` in heap storage: written from the main thread, read by the
render callback. One aligned 32-bit store is atomic on every supported architecture, so
the realtime path takes no locks and does no allocation.

Above unity, samples pass through a soft limiter — linear below 0.7, then asymptotic
toward 1.0, continuous in value and slope — so 400% saturates instead of turning into
square waves.

## Known limits

- A remembered volume is re-applied silently when the app next plays audio. If that
  fails, VolBoost does not retry for that app until you touch its slider again —
  otherwise the refresh timer would re-alert every 1.5 seconds.
- A tap pipeline is created on first adjustment and kept until the process exits. Dragging
  back to exactly 100% is a passthrough `memcpy`; tearing the aggregate device down
  mid-drag would glitch the audio instead.
- Output is re-rendered to the **default** output device. An app deliberately playing to a
  different device gets moved to the default one once you control it.
- The tap is a stereo mixdown. On a >2-channel output device, only the first two channels
  are fed; the rest are silenced for that app.
- Adding the tap inserts one extra buffer of latency into that app's path.
