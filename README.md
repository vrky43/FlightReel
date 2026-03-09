# FlightReel

**FlightReel** is a macOS app for FPV drone pilots and racers. Load your GPS flight log, tune start/finish gates, count laps, and export a beautiful animated video overlay of your flight — all in one place.

---

## Features

- **GPX & Betaflight Blackbox support** — open `.gpx` files from GPS trackers or `.bfl` / `.bbl` logs straight from your flight controller
- **Interactive gate placement** — drag start and finish gates directly on the map, or fine-tune position, width, and angle with sliders
- **Automatic lap detection** — counts laps with optional direction filtering (great for circuits and figure-8 tracks)
- **Split timing** — divide each lap into 2–10 splits with individually draggable split gates
- **Live telemetry** — as you scrub the gate slider, see real-time data from your log: speed, altitude, satellite count, heading
- **Map styles** — Standard, Satellite, or Mapy.cz aerial/tourist tiles (free API key at developer.mapy.cz)
- **Animated video export** — renders an MP4 or MOV with your flight path animated over the map at 720p–4K, 10–30 fps

---

## Requirements

- macOS 15.0 or later
- Apple Silicon or Intel Mac

---

## Installation

### Pre-built app (easiest)

1. Download **FlightReel.zip** from the [latest release](../../releases/latest)
2. Unzip and drag `FlightReel.app` to your Applications folder
3. First launch: **right-click → Open** to bypass Gatekeeper (app is not notarized)

### Build from source

```bash
git clone https://github.com/vrky43/FlightReel.git
cd FlightReel
xcodegen generate
xcodebuild -scheme FlightReel -configuration Release build
```

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

---

## Usage

1. **File › Open…** (⌘O) or click **Open…** in the sidebar — select a `.gpx`, `.bfl`, or `.bbl` file
2. Move the **Start Gate** and **Finish Gate** sliders (or drag the pins on the map) to the right positions on track
3. Enable **Count laps** in the Detection panel — laps appear in the list on the right
4. Optionally add **Splits** to break each lap into sectors
5. **File › Export Animation…** (⌘⇧E) — choose resolution, frame rate, and background map, then export

---

## Supported File Formats

| Format | Source |
|--------|--------|
| `.gpx` | GPS devices, Garmin, phone apps |
| `.bfl` | Betaflight Blackbox (binary) |
| `.bbl` | Betaflight Blackbox (binary, alternate extension) |

---

## License

MIT
