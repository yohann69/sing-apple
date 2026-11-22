# Contributing to Sing!

Thanks for helping. A few rules keep the project easy to work on.

## Layout

- `Packages/SingKit`: everything shared. `SingCore` (models, lyrics parsers, protocol), `SingDesign` (SwiftUI views shared by the Mac TV window, the pads and the Apple TV), `SingClient` (pad networking), `SingHost` (the Mac: audio, separation, server, database).
- `Apps/SingMac`, `Apps/SingPad`, `Apps/SingTV`: thin apps on top of the package.
- `project.yml`: the Xcode project is generated with `xcodegen`; never commit changes made only in Xcode's project editor.
- The Android app lives in its own repo, `sing-android`, and follows `protocol/README.md`.

## Working

1. Branch from `main` (`feat/…`, `fix/…`), commit small steps.
2. `cd Packages/SingKit && swift test` before pushing. Tests that need real songs read `SongDataExample` next to the repo and are skipped without it; `scripts/import-samples.sh` sets that folder up.
3. Comments only where the code cannot say it.
4. Any change to the pad protocol goes in `protocol/README.md` and in the Android models in the same pull request, and old fields keep decoding.

## Models

The Core ML models are not in git. `scripts/convert_*.py` rebuild them from the original open-source weights, and `scripts/install-model.sh` puts them where the app looks. Model licenses are listed in `README.md`.
