import Foundation
import IOKit
import IOKit.hid
import CoreGraphics

// --- Configuration ---

struct KeyMapping {
    var swipeUp: CGKeyCode = 0x74    // Page Up
    var swipeDown: CGKeyCode = 0x79  // Page Down
    var swipeLeft: CGKeyCode = 0x7B  // Left Arrow
    var swipeRight: CGKeyCode = 0x7C // Right Arrow
    var tap: CGKeyCode = 0x31        // Space
}

let keyNameToCode: [String: CGKeyCode] = [
    "pageup": 0x74, "pagedown": 0x79,
    "left": 0x7B, "right": 0x7C, "up": 0x7E, "down": 0x7D,
    "space": 0x31, "return": 0x24, "escape": 0x35, "tab": 0x30,
    "f5": 0x60, "f11": 0x67,
    "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E,
    "f": 0x03, "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26,
    "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D, "o": 0x1F,
    "p": 0x23, "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11,
    "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07, "y": 0x10,
    "z": 0x06,
]

func loadConfig() -> KeyMapping {
    var mapping = KeyMapping()
    let configPath = NSString(string: "~/.config/ringbridge/config.json").expandingTildeInPath

    guard FileManager.default.fileExists(atPath: configPath),
          let data = FileManager.default.contents(atPath: configPath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
        return mapping
    }

    if let name = json["swipe_up"], let code = keyNameToCode[name.lowercased()] { mapping.swipeUp = code }
    if let name = json["swipe_down"], let code = keyNameToCode[name.lowercased()] { mapping.swipeDown = code }
    if let name = json["swipe_left"], let code = keyNameToCode[name.lowercased()] { mapping.swipeLeft = code }
    if let name = json["swipe_right"], let code = keyNameToCode[name.lowercased()] { mapping.swipeRight = code }
    if let name = json["tap"], let code = keyNameToCode[name.lowercased()] { mapping.tap = code }

    print("Loaded config from \(configPath)")
    return mapping
}

// --- Gesture Detection ---

var xValues: [(value: Int, time: Double)] = []
var yValues: [(value: Int, time: Double)] = []
var lastNavTime: Double = 0
var swipeFired = false
let COOLDOWN: Double = 0.5
let MIN_SAMPLES = 4
let SWIPE_THRESHOLD = 800
let TAP_THRESHOLD = 200

let config = loadConfig()

func sendKey(_ keyCode: CGKeyCode) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

func checkSwipe() {
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastNavTime > COOLDOWN else { return }
    guard yValues.count >= MIN_SAMPLES && xValues.count >= MIN_SAMPLES else { return }

    let recentY = yValues.filter { now - $0.time < 0.4 }
    let recentX = xValues.filter { now - $0.time < 0.4 }
    guard recentY.count >= MIN_SAMPLES && recentX.count >= MIN_SAMPLES else { return }

    let deltaY = recentY.last!.value - recentY.first!.value
    let deltaX = recentX.last!.value - recentX.first!.value

    guard abs(deltaY) > SWIPE_THRESHOLD || abs(deltaX) > SWIPE_THRESHOLD else { return }

    lastNavTime = now
    swipeFired = true

    if abs(deltaY) >= abs(deltaX) {
        // Vertical swipe dominant
        if deltaY > 0 {
            print("SWIPE DOWN (next) deltaY=\(deltaY)")
            sendKey(config.swipeDown)
        } else {
            print("SWIPE UP (prev) deltaY=\(deltaY)")
            sendKey(config.swipeUp)
        }
    } else {
        // Horizontal swipe dominant
        if deltaX > 0 {
            print("SWIPE RIGHT deltaX=\(deltaX)")
            sendKey(config.swipeRight)
        } else {
            print("SWIPE LEFT deltaX=\(deltaX)")
            sendKey(config.swipeLeft)
        }
    }

    xValues.removeAll()
    yValues.removeAll()
}

func checkTap() {
    let now = ProcessInfo.processInfo.systemUptime
    guard !swipeFired else { return }
    guard now - lastNavTime > COOLDOWN else { return }
    guard yValues.count >= 2 && xValues.count >= 2 else { return }

    let deltaY = abs((yValues.last?.value ?? 0) - (yValues.first?.value ?? 0))
    let deltaX = abs((xValues.last?.value ?? 0) - (xValues.first?.value ?? 0))

    if deltaY < TAP_THRESHOLD && deltaX < TAP_THRESHOLD {
        lastNavTime = now
        print("TAP (center)")
        sendKey(config.tap)
    }
}

let hidCallback: IOHIDValueCallback = { context, result, sender, value in
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let intValue = IOHIDValueGetIntegerValue(value)
    let now = ProcessInfo.processInfo.systemUptime

    if usagePage == 1 {
        if usage == 48 {
            // X-axis
            xValues.append((value: Int(intValue), time: now))
            xValues = xValues.filter { now - $0.time < 0.5 }
            checkSwipe()
        } else if usage == 49 {
            // Y-axis
            yValues.append((value: Int(intValue), time: now))
            yValues = yValues.filter { now - $0.time < 0.5 }
            checkSwipe()
        }
    }

    // Touch end — check for tap, then clear
    if usagePage == 13 && usage == 66 && intValue == 0 {
        checkTap()
        xValues.removeAll()
        yValues.removeAll()
        swipeFired = false
    }
}

// --- Device Setup ---

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

let allDevices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
var jx05Devices: [IOHIDDevice] = []

for device in allDevices {
    let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
    if product == "JX-05" {
        jx05Devices.append(device)
    }
}

print("Ring Bridge - JX-05 Gesture Controller")
print("Mappings: up=\(config.swipeUp) down=\(config.swipeDown) left=\(config.swipeLeft) right=\(config.swipeRight) tap=\(config.tap)")
print("Found \(jx05Devices.count) JX-05 device(s) (out of \(allDevices.count) total)")

if jx05Devices.isEmpty {
    print("ERROR: JX-05 not found! Make sure the ring is connected via Bluetooth.")
    exit(1)
}

for device in jx05Devices {
    IOHIDDeviceRegisterInputValueCallback(device, hidCallback, nil)
    let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
    print("  Listening on: \(product)")
}

print("Config: ~/.config/ringbridge/config.json")
print("Press Ctrl+C to stop.\n")

CFRunLoopRun()
