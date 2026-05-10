# Windows Port Plan — JX-05 Presenter

## Overview

Port ringbridge to Windows as a native C application using Win32 APIs.
The core swipe/tap detection algorithm is platform-independent math —
only HID reading and keystroke injection need platform-specific code.

## Architecture

```
JX-05 Ring (Bluetooth HID)
        |
        v
  Windows HID API (hid.dll + SetupAPI)
  - Enumerate devices, find "JX-05" by product string
  - Open device handle with CreateFile
  - Read HID reports with ReadFile (overlapped I/O)
        |
        v
  Gesture Detection (shared logic)
  - Track X/Y axis values over sliding window
  - Detect swipes (up/down/left/right) and center taps
        |
        v
  SendInput (Win32)
  - Inject keystrokes (VK_PRIOR, VK_NEXT, VK_LEFT, VK_RIGHT, VK_SPACE)
  - No special permissions required (unlike macOS Accessibility)
```

## Implementation Steps

### Step 1: Device Discovery

Use SetupAPI + HID API to find the JX-05 ring.

```c
#include <windows.h>
#include <hidsdi.h>
#include <setupapi.h>

// 1. Get HID GUID
GUID hidGuid;
HidD_GetHidGuid(&hidGuid);

// 2. Enumerate HID devices via SetupAPI
HDEVINFO devInfo = SetupDiGetClassDevs(&hidGuid, NULL, NULL,
    DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);

// 3. For each device:
//    - Open with CreateFile (non-exclusive, read-only)
//    - Call HidD_GetProductString() to check for "JX-05"
//    - If match, keep the handle open for reading
```

Link against: `hid.lib`, `setupapi.lib`.

### Step 2: Reading HID Reports

The JX-05 sends digitizer reports. Read them in a loop.

```c
// Open device for async reads
HANDLE hDevice = CreateFile(devicePath,
    GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
    NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);

// Determine report size from preparsed data
PHIDP_PREPARSED_DATA preparsed;
HidD_GetPreparsedData(hDevice, &preparsed);
HIDP_CAPS caps;
HidP_GetCaps(preparsed, &caps);
int reportSize = caps.InputReportByteLength;

// Read loop (on background thread or with overlapped I/O)
BYTE report[256];
DWORD bytesRead;
while (ReadFile(hDevice, report, reportSize, &bytesRead, &overlapped)) {
    // Parse HID report for X, Y, tip switch
    // Feed values into gesture detection
}
```

Parsing HID reports: use `HidP_GetUsageValue()` to extract:
- Usage Page 1 (Generic Desktop), Usage 48 (X) — horizontal position
- Usage Page 1 (Generic Desktop), Usage 49 (Y) — vertical position
- Usage Page 13 (Digitizer), Usage 66 (Tip Switch) — touch state

### Step 3: Gesture Detection

Port the swipe/tap detection algorithm directly. This is pure C math
with no platform dependencies — identical logic to the macOS version:

- Track X/Y values with timestamps in a sliding window (400ms)
- Detect dominant axis and direction when threshold exceeded (delta > 800)
- Detect taps on touch-end with minimal movement
- Cooldown between gestures (500ms)

### Step 4: Keystroke Injection

```c
void sendKey(WORD vkCode) {
    INPUT inputs[2] = {0};
    inputs[0].type = INPUT_KEYBOARD;
    inputs[0].ki.wVk = vkCode;
    inputs[1].type = INPUT_KEYBOARD;
    inputs[1].ki.wVk = vkCode;
    inputs[1].ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(2, inputs, sizeof(INPUT));
}

// Key codes:
// VK_PRIOR  (0x21) — Page Up
// VK_NEXT   (0x22) — Page Down
// VK_LEFT   (0x25) — Left Arrow
// VK_RIGHT  (0x27) — Right Arrow
// VK_SPACE  (0x20) — Space
```

No Accessibility permission needed — `SendInput` works out of the box.

### Step 5: Config File

Read the same JSON config format as the macOS version:

```
%APPDATA%\ringbridge\config.json
```

```json
{
  "swipe_up": "pageup",
  "swipe_down": "pagedown",
  "swipe_left": "left",
  "swipe_right": "right",
  "tap": "space"
}
```

Use a minimal JSON parser (or just manual string parsing — the format
is simple enough). Map key names to VK_ codes at startup.

### Step 6: Device Hot-Plug (Optional)

Listen for `WM_DEVICECHANGE` messages to detect when the ring
connects/disconnects via Bluetooth, and re-enumerate automatically.

Without this, the user would need to restart the app after pairing.

### Step 7: System Tray App (Optional)

Wrap the console app in a system tray application:

- Tray icon with right-click menu (Start/Stop, Edit Config, Quit)
- Auto-start via Registry key (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`)
- Balloon notification when ring connects

This is nicer UX than a headless service on Windows. Could use a
minimal Win32 window with `Shell_NotifyIcon`.

## Build & Distribution

### Build
```
cl ringbridge.c /link hid.lib setupapi.lib user32.lib
```

Or with MinGW:
```
gcc ringbridge.c -o ringbridge.exe -lhid -lsetupapi -luser32
```

### Distribution Options (pick one)
1. **GitHub Releases** — single .exe, no installer needed
2. **WinGet** — `winget install savikko.jx05presenter`
3. **Scoop** — `scoop install jx05presenter`

A single-file .exe with no dependencies is the simplest.
The app is small enough that an installer is overkill.

## Differences from macOS Version

| Aspect | macOS | Windows |
|--------|-------|---------|
| Language | Swift | C |
| HID API | IOKit | hid.dll + SetupAPI |
| Keystroke injection | CGEvent | SendInput |
| Permissions | Accessibility required | None required |
| HID reading model | Callback-based | Read loop (thread) |
| Background service | launchd | System tray app or Registry auto-start |
| Config location | ~/.config/ringbridge/config.json | %APPDATA%\ringbridge\config.json |

## Estimated Scope

- ~150-200 lines of C for core functionality
- Device discovery and HID parsing is the most code (~60 lines)
- Gesture detection is a direct port (~40 lines)
- Everything else is small: config parsing, keystroke injection, main loop

## Alternative: Cross-Platform with hidapi

The [hidapi](https://github.com/libusb/hidapi) library provides a single
C API for HID access on macOS, Windows, and Linux. Using it, the entire
app (minus keystroke injection) could share one codebase:

```c
#include <hidapi.h>

hid_device *dev = hid_open(0xFFFF, 0x0000, NULL);  // or enumerate by name
unsigned char buf[256];
while (hid_read(dev, buf, sizeof(buf)) > 0) {
    // parse and detect gestures
}
```

This would simplify maintenance if both platforms need to be supported
long-term. Keystroke injection would still need a platform #ifdef
(CGEvent vs SendInput).
