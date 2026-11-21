# Sing! for Apple platforms

A home karaoke system. The Mac does all the work: it separates vocals on device with Demucs on Core ML, finds synced lyrics, shows them on the TV like Apple Music, mixes the microphone and keeps the history. iPads and iPhones find the Mac on the Wi‑Fi and control the queue.

## What is in here

- `Packages/SingKit`: shared Swift package
  - `SingCore`: models, TTML and LRC parsers, lyrics providers (Sing API, LRCLIB), pad protocol
  - `SingDesign`: theme (`sing-theme.json`), Liquid Glass components, animated album-color background, karaoke line, TV stage, settings forms
  - `SingHost` (macOS): SQLite database (GRDB), library import, song cache, vocal separation, playback and mic engines, queue, stats, suggestions, pad server and Bonjour
  - `SingClient`: pad side networking (HTTP, live WebSocket, Bonjour browser)
- `Apps/SingMac`: the host app with the control window and the TV window
- `Apps/SingPad`: the iPad and iPhone remote
- `protocol/`: the pad protocol, shared with the Android app
- `scripts/`: model conversion and installation

## Build

Needs Xcode 27 and macOS 26 or later on Apple silicon.

```bash
brew install xcodegen
xcodegen generate
open Sing.xcodeproj
```

Install the separation model once (about 200 MB, converted locally from the MIT-licensed Demucs weights):

```bash
scripts/install-model.sh
```

Run the tests:

```bash
cd Packages/SingKit && swift test
```

Set `SING_SAMPLES=/path/to/folder` to run the import and end-to-end tests against your own audio files, and `SING_MODEL` with `SING_REF` to compare separation against PyTorch.

## Using it

1. Launch Sing! on the Mac and drop music files on the Library.
2. Plug the TV over HDMI: the TV window opens on it (Cmd-Shift-T toggles it). Pick the audio output in Settings.
3. On the iPad, open Sing!, pick the Mac and type the host code shown in the Mac's Pads screen. Guests scan the QR on the TV.

## License

MIT. The Demucs model is MIT licensed by Meta.
