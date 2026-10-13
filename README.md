# Skrinsut

**skrin.sut**: “screen.shot”, the way it sounds in Indonesian.

A fast macOS screenshot and screen-recording tool written in Swift/AppKit: capture, annotate,
recognize text, beautify, pin, and record to MP4/GIF.

Requires macOS 14+ and Xcode (the SwiftUI macros need the full toolchain).

```sh
scripts/build-app.sh --run     # builds build/Skrinsut.app (universal, ad-hoc signed) and launches it
swift build                    # dev build (set DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer if CLT is selected)
```

Recording needs **ffmpeg**. Settings ▸ Video has a one-click **Install ffmpeg** button (via Homebrew; if Homebrew is missing it opens a Terminal installer). Without ffmpeg, recordings are kept as .mov.

On first capture, grant **Screen Recording** to Skrinsut in System Settings → Privacy & Security, then relaunch.
Ad-hoc signatures change on every rebuild, so macOS may ask again. Set `SIGN_IDENTITY="Apple Development: …"` to keep the permission across builds.

## Features

| Area | Implemented |
|---|---|
| Capture | Fullscreen (display under cursor), Area (frozen screen, crosshair, pixel loupe with hex, size badge, ⇧ for square), Window (hover-highlight; Space toggles area/window; click in area mode grabs the window under it), Repeat area, Delayed 3 s |
| Window background | Wallpaper (window on the real desktop picture with a margin, other windows and icons hidden), transparent with shadow, trimmed shadow, or solid color |
| Screen recording | Record Area (⇧⌘6 to start/stop), Window or Fullscreen from the menu bar. A dashed border marks the area and the menu-bar item turns into a ● 0:12 stop button. The capture is recorded to a temporary .mov, then **ffmpeg** encodes it to MP4 (H.264 or HEVC) or GIF with the options in Settings ▸ Video, saves it to the Save Location, copies the file to the clipboard and reveals it in Finder. No audio, no editor |
| OCR | Vision text recognition plus QR/barcode detection; result copied with a toast |
| After capture | Show (opens the editor), Copy, Save, set independently. If all three are off, the capture is still copied |
| Thumbnail | Copy, Save, Edit, Pin, OCR, Close, click to edit, drag the image out as a file |
| Editor | Tools: Select `V`, Arrow `A`, Text `T` (Background style by default; ⇧↩ for a new line), Ruler `U` (hover to auto-measure the gap or element under the cursor and click to place it, or drag to measure manually; Δx × Δy shown for diagonals), Rectangle `R`, Oval `O`, Line `L`, Freehand `D`, Highlighter `H` (Stabilo-style freehand marker with a flat chisel tip; ⇧ for a straight stroke; keeps its own color, yellow by default), Blur/pixelate `B`, Spotlight `S`, Counter `C`, Magnifier `M`, Crop `K` (↩ apply, esc cancel). Snapping (Draw ▸ Snap to Objects, on by default; hold ⌘ to skip): moving, drawing, resizing and crop corners snap to screenshot edges, other objects and the canvas edges/center, with pink guides. Move/select objects, endpoint handles, ⇧ snaps to 45° or squares, arrow keys nudge, delete removes, undo/redo, rasterize, reset crop, color palette + well, size, fill with adjustable opacity (translucent fills keep a solid border), zoom (pinch/⌘+/⌘−/⌘0/⌘1/⌘2), pixel coordinate and color readout (click to copy hex), drag-out, print |
| Add Capture | Toolbar image button or ⇧⌘A: capture a new area, paste (⌘V), or pick a file; inserted as a movable object that resizes with its aspect ratio kept, under other markup |
| Backdrop / beautify | Sidebar (✨ button in the editor toolbar): 16 gradient presets + randomize, solid color, or desktop wallpaper (with blur); padding, corner radius, outer radius, shadow, aspect ratio (Auto, 1:1, 4:3, 3:2, 16:9, 16:10, 9:16). Live preview; applied to copy/save/pin/drag-out at full resolution; last style is remembered |
| Pin | Floating always-on-top image: drag to move, scroll to resize, double-click to edit, right-click for 50/100/200%, semi-transparent, copy, close; esc closes |
| Hotkeys | Global (Carbon), recordable in Settings ▸ Shortcuts. Defaults: ⇧⌘1 fullscreen, ⇧⌘2 area, ⇧⌘7 window, ⇧⌘8 OCR, ⇧⌘9 repeat |
| Settings | System Settings–style window with a sidebar: **General** (save location, launch at login), **Image** (after-screenshot Show/Copy/Save, save format, Retina downscale, window background, snapping), **Video** (format, max resolution, frame rate, cursor, codec H.264/HEVC, software/hardware encoder, constant quality or target bitrate, speed, GIF frame rate/colors/dithering, ffmpeg status with one-click install) **Shortcuts** (recordable global hotkeys plus editor key reference), then **About** (version, macOS and ffmpeg versions, credits) and **Help** (getting started with your current hotkeys, Screen Recording permission status, troubleshooting FAQ) |
| Deep links | `skrinsut://grab/fullscreen`, `grab/area`, `grab/window`, `grab/repeat`, `ocr`, `load/clipboard` (off by default; there's no switch in Settings) |
| Files | Open file, open from clipboard, "Open With" for png/jpeg/gif |

Roadmap: scrolling capture with stitching, cloud/S3 upload, a screenshot library,
and color-format/contrast tools.

## Layout

```
Sources/Skrinsut/
  AppDelegate.swift, MainMenu.swift, HotKeys.swift, Settings.swift, Exporter.swift
  Capture/   Capturer (ScreenCaptureKit, PixelSampler), RegionSelector (overlay), OCR (Vision)
  Editor/    Annotation (model + Renderer), CanvasView, EditorWindowController
  Editor/    Backdrop, BackdropPanel, Snapping, EditorChrome (toolbar pieces)
  Recording/ ScreenRecorder (ScreenCaptureKit → .mov), FFmpeg, VideoSettings, DependencyInstaller, RecordingController
  Windows/   PreviewWindowController (thumbnail), PinWindowController, Toast
  Prefs/     PreferencesWindow (SwiftUI settings: General, Image, Video, Shortcuts, About, Help)
```
