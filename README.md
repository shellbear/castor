# Castor 🦫

**Stream any video from your Mac to Apple TV, Chromecast, and Smart TVs.**

Castor is a native macOS menu bar app, fully open source. Pick a file, pick a
device, and it plays on your TV — original quality whenever the device supports
it, hardware-accelerated conversion when it doesn't.

> ⚠️ Early development. Not ready for daily use yet.

## Why Castor?

- **Native & light** — a Swift menu bar app, not an Electron wrapper.
- **Quality first** — compatible files are streamed bit-exact (no re-encode).
  When conversion is needed, it runs on the Apple Silicon media engine at a few
  percent CPU.
- **Resumable** — quit mid-movie, relaunch, continue where you left off.
- **Open** — MIT licensed.

## Requirements

- macOS 14+
- [ffmpeg](https://ffmpeg.org) (`brew install ffmpeg`) — bundled builds are on
  the roadmap

## Building

```sh
brew install xcodegen ffmpeg
make build   # generates Castor.xcodeproj and builds the app
make test    # engine unit tests
make run
```

## License

[MIT](LICENSE)
