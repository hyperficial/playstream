# PlayStream

A PS5 Remote Play client for macOS on Apple Silicon, built around low latency and picture quality.

This is a personal project and a work in progress. Expect rough edges.

## What it does

- Finds, pairs with and wakes a PS5 on the local network
- Streams 1080p at 60 fps in HEVC, with HDR, at up to 100 Mbit/s
- Metal renderer that presents on the display's variable refresh rate, with frame pacing
- Upscaling: bicubic, MetalFX spatial, FSR 1
- Frame generation for 30 fps games (experimental)
- DualSense: haptics, adaptive triggers, touchpad, motion, light bar
- Audio with an adaptive jitter buffer, plus dynamics (light, night), tone presets and a voice boost
- Records the stream untouched (HEVC and AAC) to `~/Movies/PlayStream`
- Debugging tools: a control channel (`scripts/psctl`), a flight recorder for the incoming stream, per-frame traces, and swapping a new build into a running session

4K is not available: the console does not offer it for Remote Play.

## Requirements

- macOS 26 on Apple Silicon
- Xcode and [Homebrew](https://brew.sh)

```sh
brew install xcodegen pkgconf miniupnpc libevent protobuf json-c opus openssl@4 curl cmake ninja
```

## Build

```sh
git clone --recursive https://github.com/hyperficial/playstream.git
cd playstream
./scripts/build-chiaki.sh        # builds the protocol core into build/chiaki
./scripts/build-app.sh Release   # builds build/release/PlayStream.app
```

The app is signed ad hoc by default. To sign it with your own Apple Development certificate, put your team id in a file named `Local.xcconfig` next to `project.yml`:

```
DEVELOPMENT_TEAM = XXXXXXXXXX
```

That file is ignored by git.

## Layout

| Path | Contents |
|---|---|
| `App/` | The SwiftUI app |
| `Sources/PSCore` | Session, settings, control channel, debugging tools |
| `Sources/PSVideo` | Decoding, pacing, rendering, upscaling, frame generation |
| `Sources/PSAudio` | Jitter buffer, output, sound shaping |
| `Sources/PSInput` | Controller input and feedback |
| `Sources/PSPairing` | Discovery, registration, PSN sign-in for the account id |
| `Sources/PSRecording` | Recording |
| `Sources/CPSBridge` | C bridge to the protocol core |
| `Sources/*Harness` | Command-line test hosts for each module |
| `patches/` | Patches applied to the vendored core at build time |
| `vendor/chiaki-ng` | The protocol core (git submodule) |

Pairing keys are stored on your Mac in `~/Library/Application Support/PlayStream/pairing.json`, readable only by your user account. The PSN sign-in talks only to Sony's servers and is used once, to look up the account id the console asks for.

## Credits and licence

The Remote Play protocol implementation is [chiaki-ng](https://github.com/streetpea/chiaki-ng), licensed AGPL-3.0-only with an OpenSSL exception. Because PlayStream links it, PlayStream is licensed under the GNU Affero General Public License version 3; see `LICENSE`.

The FSR 1 upscaler is a port of AMD FidelityFX Super Resolution 1.0, used under the MIT licence; the notice is in `Sources/PSVideo/FSR1.swift`.

PlayStream is not affiliated with or endorsed by Sony Interactive Entertainment. PlayStation, PS5 and DualSense are trademarks of Sony Interactive Entertainment Inc.
