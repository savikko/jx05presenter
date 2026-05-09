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
            print("→ NEXT (PageDown) delta=\(delta)")
            sendKey(0x79)  // Page Down
        } else {
            print("← PREV (PageUp) delta=\(delta)")
            sendKey(0x74)  // Page Up
        }
        yValues.removeAll()
    }
}

let callback: IOHIDValueCallback = { context, result, sender, value in
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let intValue = IOHIDValueGetIntegerValue(value)
    let now = ProcessInfo.processInfo.systemUptime

    // Track Y-axis (usage 49) on Generic Desktop page (1)
    if usagePage == 1 && usage == 49 {
        yValues.append((value: Int(intValue), time: now))
        yValues = yValues.filter { now - $0.time < 0.5 }
        checkSwipe()
    }

    // Clear tracking on touch end (digitizer tip switch off)
    if usagePage == 13 && usage == 66 && intValue == 0 {
        yValues.removeAll()
    }
}

// Find JX-05 devices and register callbacks directly on them
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, nil)  // match all to find JX-05
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

print("Ring Bridge - JX-05 → PageUp/PageDown")
print("Found \(jx05Devices.count) JX-05 device(s) (out of \(allDevices.count) total)")

if jx05Devices.isEmpty {
    print("ERROR: JX-05 not found! Make sure the ring is connected via Bluetooth.")
    exit(1)
}

// Register callback only on JX-05 devices, not the manager
for device in jx05Devices {
    IOHIDDeviceRegisterInputValueCallback(device, callback, nil)
    let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
    print("  Listening on: \(product)")
}

print("Press Ctrl+C to stop.\n")

CFRunLoopRun()
