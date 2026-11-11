# XMNative

A macOS menu bar app for Sony and Bose headphones. Change noise cancelling, the EQ and the other settings from
the Mac instead of reaching for the Sony or Bose app on your phone.

I wrote it for my WH-1000XM4, but it talks to the headphones the same way Sony's Sound Connect app does, so other
Sony models should work too (see [Supported headphones](#supported-headphones)).

This is a personal project and has nothing to do with Sony or Bose.

## Features

- Noise cancelling, wind reduction, ambient sound (with level and "focus on voice"), off
- EQ presets and the custom EQ, including Clear Bass
- Speak-to-Chat, with sensitivity and timeout
- NC Optimizer
- Battery level and the Bluetooth codec in use
- Play/pause, next, previous and volume
- Automatic power off, pause when taken off
- DSEE, sound quality vs. connection stability
- What the NC/AMB button does (noise control, Google Assistant, Alexa)
- Touch controls, connection to two devices, voice guidance

On Bose headphones (QuietComfort Ultra family):

- Listening modes: switch, create, edit and delete your own modes (announced name, own name, noise cancelling
  strength, Noise Control on/off, ActiveSense, Wind Block, Immersive Audio off / still / motion), and choose
  which modes the mode button cycles through
- Noise control outside of modes (on/off and strength)
- The 3-band EQ (bass, mid, treble) with the Bose presets and your own saved presets
- Battery, play/pause, next, previous, volume and what's playing
- Auto-off, wear detection (pause when taken off, answer calls), multipoint, voice prompts, the shortcut button,
  hearing yourself during calls

The app asks the headphones what they support and only shows those settings, so the list depends on the model.

On any headphones or speakers:

- A Mac-wide equalizer with 10 or 31 bands (Apple's built-in AUGraphicEQ), presets, your own presets, preamp
  and clipping protection. It processes everything the Mac plays through a Core Audio process tap
  (needs the "System Audio Recording" permission) and follows the selected output device. It only affects
  sound from the Mac.

## Supported headphones

Sony uses two versions of this protocol:

- The WH-1000XM4 generation and older (WH-1000XM4, WF-1000XM4, …). This is what the app was developed on.
- The WH-1000XM5 generation and newer (WH-1000XM5, WH-1000XM6, WF-1000XM5, …). Implemented from Sony's app,
  but not tried on real headphones yet. If you own one, please open an issue and say what works and what doesn't.

Bose: the QuietComfort Ultra Headphones (2nd Gen) and other headphones the Bose app talks to over BMAP
(QC Ultra, QuietComfort Headphones, QC45, NC 700, …). Implemented from the Bose app 13.4.2 and tested on the
QuietComfort Ultra Headphones (2nd Gen). Other Bose models haven't been tried yet.

## Install

Requires macOS 26 or later.

1. Download the latest `XMNative-…zip` from [Releases](https://github.com/arno4000/xmnative/releases) and unzip it.
2. Move `XMNative.app` to Applications.
3. The app isn't notarized, so macOS blocks the first launch. Try to open it once, then go to
   **System Settings → Privacy & Security** and click **Open Anyway**. Or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/XMNative.app
   ```
4. Allow Bluetooth access when macOS asks.

## Usage

Pair the headphones with your Mac and connect them as usual. Then click the headphones icon in the menu bar and
press **Connect**. After that the app connects on its own whenever the headphones connect to the Mac. You can turn
that off under **Settings → App**, where you'll also find "Open at login".

The menu bar popover has the things you change often. **Settings** opens a window with everything else.

## Building

You need Xcode 26 (or just the Command Line Tools) on macOS 26 or later.

```sh
scripts/test.sh       # run the tests
scripts/bundle.sh     # build build/XMNative.app
```

`UNIVERSAL=1 scripts/bundle.sh` builds for Apple silicon and Intel. Pushing a tag like `v0.2.0` makes GitHub
Actions build the app and publish a release.

## How it works

Sony headphones offer a Bluetooth serial (RFCOMM) service that the Sound Connect app uses to read and change
settings. I decompiled Sound Connect 13.3.0 for Android to find the message format and the commands.
[docs/PROTOCOL.md](docs/PROTOCOL.md) describes everything this app uses, down to the bytes.

Bose headphones speak Bose's "BMAP" protocol over the standard serial port service. I decompiled the Bose app
13.4.2 for Android for that; [docs/BOSE-PROTOCOL.md](docs/BOSE-PROTOCOL.md) has the details.

The code is split so the parts that don't depend on macOS can be reused, for example in a Linux version:

| Folder | What's in it |
|---|---|
| `Sources/HeadphoneKit` | Brand-neutral model of headphone settings and the driver interface. No Apple frameworks. |
| `Sources/SonyMDR` | The Sony protocol: framing, acknowledgements, both command sets. No Apple frameworks. |
| `Sources/BoseBMAP` | The Bose protocol: packets, requests, listening modes and settings. No Apple frameworks. |
| `Sources/MacBluetooth` | Finding paired devices and opening the RFCOMM channel with IOBluetooth. |
| `Sources/MacAudio` | The Mac equalizer: process tap, aggregate device and Apple's graphic EQ. |
| `Sources/XMNative` | The SwiftUI app. |
| `Tests/SonyMDRTests` | Byte-level tests and a simulated WH-1000XM4. |
| `Tests/BoseBMAPTests` | Byte-level tests and a simulated QC Ultra Headphones (2nd Gen). |
| `Tests/MacAudioTests` | The equalizer measured offline with test tones. |

Adding another brand means writing a driver in a new module that implements
`HeadphoneDriver` and `HeadphoneDriverFactory` from `HeadphoneKit`, and adding it to `AppModel.factories`.
The UI shows whatever the driver reports, so it doesn't need changes.

## Not supported yet

Managing paired devices, voice guidance language and volume, Adaptive Sound Control, 360 Reality Audio
and firmware updates.
