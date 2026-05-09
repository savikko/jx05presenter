# JX-05 Presenter

A macOS utility that turns the JX-05 Bluetooth ring remote into a presentation controller. Swipe clockwise to go to the next slide, counter-clockwise for the previous slide.

The JX-05 ring registers as a BLE digitizer/touchpad rather than a keyboard, which means it doesn't work out of the box with presentation software. This tool bridges the gap by reading the ring's raw HID touch events and converting swipe gestures into Page Down / Page Up keystrokes.

Works with any presentation tool that supports Page Up/Page Down: Keynote, Google Slides, PowerPoint, reveal.js, etc.

## Requirements

- macOS (tested on macOS 15+)
- Swift compiler (included with Xcode or Xcode Command Line Tools)
- JX-05 ring remote paired via Bluetooth

## Install

### Homebrew (recommended)

```bash
brew install savikko/tap/jx05presenter
```

### From source

```bash
# Install Xcode Command Line Tools (if not already installed)
xcode-select --install

# Clone and build
git clone https://github.com/savikko/jx05presenter.git
cd jx05presenter
make build
```

To install system-wide:

```bash
sudo make install
```

This copies the binary to `/usr/local/bin/ringbridge`.

## Usage

1. Pair the JX-05 ring with your Mac via Bluetooth Settings
2. Run the bridge:

```bash
./ringbridge
```

3. Open your presentation and start swiping:
   - **Clockwise** = Next slide (Page Down)
   - **Counter-clockwise** = Previous slide (Page Up)

4. Press `Ctrl+C` to stop

### Accessibility Permission

The first time you run it, macOS will ask you to grant Accessibility permissions (System Settings > Privacy & Security > Accessibility). This is required for the tool to inject keystrokes.

## How it works

The JX-05 ring presents itself as a BLE digitizer device (HID Usage Page 13) with a circular touchpad. When you swipe around the ring, it sends a stream of X/Y coordinate updates.

This tool:

1. Opens the HID device matching the JX-05's vendor ID (`0xFFFF`)
2. Tracks Y-axis position changes over a 400ms sliding window
3. When it detects a significant directional movement (delta > 800 on a 0-3500 range), it fires a Page Down or Page Up keystroke via `CGEvent`
4. Applies a 500ms cooldown between navigations to prevent double-triggers

## Configuration

You can adjust these constants in `ringbridge.swift`:

| Constant | Default | Description |
|----------|---------|-------------|
| `COOLDOWN` | `0.5` | Seconds between slide changes |
| `MIN_SAMPLES` | `4` | Minimum data points before detecting a swipe |
| Delta threshold | `800` | Minimum Y-axis movement to trigger (in `checkSwipe()`) |

## Uninstall

```bash
sudo make uninstall
```

## License

MIT
