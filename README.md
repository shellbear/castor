# Castor 🦫

**Stream any video from your Mac to Apple TV, Chromecast, and Smart TVs — native, fast, open source.**

Castor lives in your menu bar. Pick a video, pick a device, and it plays on
your TV at the highest quality the device can decode — bit-exact original
streams whenever possible, Apple Silicon hardware encoding when conversion is
unavoidable.

[![CI](https://github.com/shellbear/castor/actions/workflows/ci.yml/badge.svg)](https://github.com/shellbear/castor/actions/workflows/ci.yml)

> ⚠️ **Early development (v0.1).** The core works; edges are rough. Issues and
> PRs welcome.

## Features

- 📺 **AirPlay & Chromecast** — Google Cast protocol implemented natively in
  Swift; AirPlay through AVKit external playback
- 🎯 **Quality first** — a decision engine picks the cheapest path:
  *direct play* (serve original bytes) → *remux* (repackage, no re-encode) →
  *transcode* (VideoToolbox hardware encoder, last resort)
- ⚡ **Fast** — remuxing runs at hundreds of times realtime; a full movie is
  ready to seek in seconds. Transcodes run on the media engine at a few
  percent CPU
- 🔍 **Full seeking, even mid-transcode** — a predicted VOD playlist plus
  keyframe-aligned encoder restarts means the seek bar always spans the whole
  film
- 💬 **Subtitles** — embedded text tracks (SRT/ASS) converted to WebVTT and
  side-loaded; forced tracks enabled automatically to match the audio language
- ⏯️ **Resumable** — progress is saved continuously; quit mid-movie and pick
  up where you left off, on any device
- 🔗 **Scriptable** — `castor://` URL scheme (`cast`, `toggle`, `stop`,
  `resume-last`) for Raycast, Shortcuts, or shell scripts

## How it works

Casting protocols don't push video — they hand the TV a URL and the TV pulls.
Castor runs a local HTTP server and tells each device to fetch from it:

```
 file ──► ffprobe ──► planner ──┬──► direct play (Range requests, bit-exact)
                                ├──► remux-ahead (-c copy → fMP4 HLS, ~500× realtime)
                                └──► transcode  (VideoToolbox H.264, seekable VOD HLS)
                                          │
                              local HTTP server (CORS + Range)
                                          │
                     ┌────────────────────┼────────────────────┐
                 Chromecast          Apple TV               Smart TV
              (CASTv2 protocol)  (AVPlayer external      (DLNA — roadmap)
                                     playback)
```

Measured on an M3 Pro with a 1080p 10-bit HEVC BluRay rip (82 min):

| Path | Speed | CPU |
|---|---|---|
| Remux to fMP4 HLS (`-c copy`) | **517× realtime** — whole movie in 9.5 s | ~1 s total CPU |
| HEVC 10-bit → H.264 12 Mbps (VideoToolbox) | **8.5× realtime** | ~10 % |

Because compatible files are never re-encoded, what your TV decodes is the
same bitstream a Blu-ray player would send over HDMI. When transcoding is
required, color metadata is preserved and bitrate is spent generously — the
LAN doesn't care.

## Requirements

- macOS 14+
- [ffmpeg](https://ffmpeg.org): `brew install ffmpeg` (bundled, signed
  binaries are on the roadmap)

## Building

```sh
brew install xcodegen ffmpeg
git clone https://github.com/shellbear/castor && cd castor
make build   # generates Castor.xcodeproj, builds the app
make run
```

`make test` runs the engine test suite (protocol codec, planner matrix, HTTP
range serving, HLS session integration).

On first cast, macOS will ask for **Local Network** permission — Castor needs
it to discover devices and serve them media.

## Architecture

The repo is a thin SwiftUI app over a UI-free Swift package:

```
App/                      menu bar UI (SwiftUI MenuBarExtra)
Packages/CastorEngine/
  Discovery/              Bonjour browsing (_googlecast._tcp)
  Probe/                  ffprobe wrapper → MediaInfo
  Planner/                direct play / remux / transcode decisions
  Streamer/               ffmpeg sessions, HLS playlists, seek-restart
  Server/                 HTTP server: Range, CORS, HLS routes
  Cast/                   CASTv2: protobuf codec, TLS channel, media controller
  AirPlay/                AVPlayer external playback
  History/                resume positions (JSON)
  Subtitles/              text tracks → WebVTT
```

Everything protocol-shaped is unit-tested; `CastorEngine` never imports UI
frameworks.

## Roadmap

- DLNA/UPnP for Smart TVs without Cast or AirPlay
- Bitmap subtitle burn-in (PGS/VobSub) and styled-ASS fidelity
- Bundled LGPL ffmpeg binaries (no Homebrew dependency)
- HDR passthrough & tone mapping
- Multi-audio HLS renditions (switch language without restarting)
- Raycast extension on top of the `castor://` scheme
- Sparkle auto-updates, notarized DMG releases

## Why "Castor"?

*Castor* is French for **beaver** — an industrious builder who lives in
streams. It's also a star in Gemini and happens to contain "cast". The name
was too good to pass up.

## License

[MIT](LICENSE)
