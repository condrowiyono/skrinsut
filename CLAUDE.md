# Skrinsut

macOS screenshot and screen-recording app (Swift/AppKit + SwiftUI settings), built with SwiftPM.

## Brand
- The product name is **Skrinsut**, from *skrin.sut*: “screen.shot”, the way it sounds in Indonesian.
- Write it as `Skrinsut` in UI text, `skrinsut` in identifiers, and `skrin.sut` only as the tagline.
- Bundle ID is `com.skrinsut.app`. The URL scheme is `skrinsut://`. The hotkey signature is `'SKRN'`.
- Don't reference, compare with, or credit other screenshot apps in code, comments, UI, or docs.

## Build & run
- Release app: `scripts/build-app.sh --run` → `build/Skrinsut.app` (universal, ad-hoc signed).
- Dev build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`. SwiftUI macros need the full Xcode toolchain, not Command Line Tools.
- Capture and recording need Screen Recording permission. Ad-hoc rebuilds may need it granted again.
- Recording encodes with an installed ffmpeg (auto-detected; Settings ▸ Video has a one-click install).

## Layout
- `Sources/Skrinsut/Capture`: ScreenCaptureKit capture, the area/window selector, OCR.
- `Sources/Skrinsut/Editor`: canvas, annotation model and renderer, toolbar, backdrop, snapping.
- `Sources/Skrinsut/Recording`: recorder (temp .mov), ffmpeg encoding, video settings, installer.
- `Sources/Skrinsut/Prefs`: settings window (General, Image, Video, Shortcuts, About, Help).
- `Sources/Skrinsut/Windows`: pin, thumbnail preview, toast.
