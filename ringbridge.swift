import Foundation
import IOKit
import IOKit.hid
import CoreGraphics

// Track Y-axis movement to detect swipe direction
var yValues: [(value: Int, time: Double)] = []
var lastNavTime: Double = 0
let COOLDOWN: Double = 0.5  // seconds between navigations
let MIN_SAMPLES = 4

func sendKey(_ keyCode: CGKeyCode) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

func checkSwipe() {
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastNavTime > COOLDOWN else { return }
    guard yValues.count >= MIN_SAMPLES else { return }

    // Only look at recent values (last 400ms)
    let recent = yValues.filter { now - $0.time < 0.4 }
    guard recent.count >= MIN_SAMPLES else { return }

    let first = recent.first!.value
    let last = recent.last!.value
    let delta = last - first

    // Need significant movement (Y range is ~200-3500)
    if abs(delta) > 800 {
        lastNavTime = now
        if delta > 0 {
            // Y increasing = swipe down = Page Down = next slide
            print("→ NEXT (PageDown) delta=\(delta)")
            sendKey(0x79)  // Page Down
        } else {
            // Y decreasing = swipe up = Page Up = previous slide
            print("← PREV (PageUp) delta=\(delta)")
            sendKey(0x74)  // Page Up
        }
        yValues.removeAll()
    }
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

let matching: [String: Any] = [
    kIOHIDVendorIDKey as String: 0xFFFF
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
print("Ring Bridge - JX-05 → PageUp/PageDown")
print("Found \(devices.count) device(s)")
for device in devices {
    let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
    print("  - \(product)")
}

if devices.isEmpty {
    print("ERROR: JX-05 not found! Make sure the ring is connected via Bluetooth.")
    exit(1)
}

let callback: IOHIDValueCallback = { context, result, sender, value in
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let intValue = IOHIDValueGetIntegerValue(value)
    let now = ProcessInfo.processInfo.systemUptime

    // Only process events from JX-05
    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender!).takeUnretainedValue()
    let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
    guard product == "JX-05" else { return }

    // Track Y-axis (usage 49) on Generic Desktop page (1)
    if usagePage == 1 && usage == 49 {
        yValues.append((value: Int(intValue), time: now))
        // Keep only last 500ms
        yValues = yValues.filter { now - $0.time < 0.5 }
        checkSwipe()
    }

    // Clear tracking on touch end (digitizer tip switch off)
    if usagePage == 13 && usage == 66 && intValue == 0 {
        yValues.removeAll()
    }
}

IOHIDManagerRegisterInputValueCallback(manager, callback, nil)

print("Listening... swipe ring clockwise=next, counter-clockwise=prev")
print("Press Ctrl+C to stop.\n")

CFRunLoopRun()
