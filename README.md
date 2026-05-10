# JX-05 Presenter

<img src="jx05-ring.png" alt="JX-05 Ring Remote" width="200" align="right">

A macOS utility that turns the JX-05 Bluetooth ring remote into a presentation controller.

The JX-05 ring registers as a BLE digitizer/touchpad rather than a keyboard, which means it doesn't work out of the box with presentation software. This tool bridges the gap by reading the ring's raw HID touch events and converting gestures into keystrokes.

Supports five gestures: swipe up, swipe down, swipe left, swipe right, and center tap — all with configurable key mappings.

Works with any presentation tool that supports keyboard navigation: Keynote, Google Slides, PowerPoint, reveal.js, etc.

## Requirements

- macOS (tested on macOS 15+)
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
2. Start the service:

```bash
brew services start jx05presenter
```

   This runs in the background and starts automatically on login.

3. Open your presentation and use the ring:
   - **Swipe up/down** = Previous / Next slide (Page Up / Page Down)
   - **Swipe left/right** = Left / Right arrow keys
   - **Center tap** = Space bar
   - Try both directions to see which is which — it depends on how you wear the ring

To stop the service:

```bash
brew services stop jx05presenter
```

To run manually instead (foreground):

```bash
ringbridge
```

### Accessibility Permission

The first time you press a button on the ring, macOS will show a permission dialog. To enable it:

1. Click **"Open System Settings"** in the dialog
2. In **Privacy & Security > Accessibility**, enable **ringbridge**
3. You may need to restart the service after granting permission:

```bash
brew services restart jx05presenter
```

This is required for the tool to inject keystrokes.

## How it works

The JX-05 ring presents itself as a BLE digitizer device (HID Usage Page 13) with a circular touchpad. When you swipe around the ring, it sends a stream of X/Y coordinate updates.

This tool:

1. Opens the HID device matching the JX-05's product name
2. Tracks X and Y axis position changes over a 400ms sliding window
3. When it detects significant movement (delta > 800 on a 0-3500 range), it determines the dominant axis (horizontal vs vertical) and fires the corresponding keystroke via `CGEvent`
4. When a touch ends with minimal movement, it registers as a center tap
5. Applies a 500ms cooldown between gestures to prevent double-triggers

## Configuration

### Key Mappings

Create `~/.config/ringbridge/config.json` to customize which keys the ring gestures produce:

```bash
mkdir -p ~/.config/ringbridge
cat > ~/.config/ringbridge/config.json << 'EOF'
{
  "swipe_up": "pageup",
  "swipe_down": "pagedown",
  "swipe_left": "left",
  "swipe_right": "right",
  "tap": "space"
}
EOF
```

The values shown above are the defaults. You only need to create this file if you want to change them. Restart the service after editing:

```bash
brew services restart jx05presenter
```

Available key names: `pageup`, `pagedown`, `left`, `right`, `up`, `down`, `space`, `return`, `escape`, `tab`, `f5`, `f11`, `a`-`z`.

### Tuning

You can adjust these constants in `ringbridge.swift`:

| Constant | Default | Description |
|----------|---------|-------------|
| `COOLDOWN` | `0.5` | Seconds between gestures |
| `MIN_SAMPLES` | `4` | Minimum data points before detecting a swipe |
| `SWIPE_THRESHOLD` | `800` | Minimum axis movement to trigger a swipe |
| `TAP_THRESHOLD` | `200` | Maximum movement to register as a tap |

## Upgrade

```bash
brew upgrade jx05presenter
brew services restart jx05presenter
```

## Uninstall

### Homebrew

```bash
brew uninstall jx05presenter
```

### From source

```bash
sudo make uninstall
```

## License

MIT
