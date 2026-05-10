use hidapi::HidApi;
use serde::Deserialize;
use std::env;
use std::fs;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

// --- Configuration ---

const COOLDOWN_MS: u64 = 500;
const WINDOW_MS: u64 = 400;
const MIN_SAMPLES: usize = 4;
const SWIPE_THRESHOLD: i32 = 800;
const TAP_THRESHOLD: i32 = 200;

#[derive(Debug, Clone, Copy)]
struct KeyMapping {
    swipe_up: u16,
    swipe_down: u16,
    swipe_left: u16,
    swipe_right: u16,
    tap: u16,
}

#[derive(Deserialize, Default)]
struct ConfigFile {
    swipe_up: Option<String>,
    swipe_down: Option<String>,
    swipe_left: Option<String>,
    swipe_right: Option<String>,
    tap: Option<String>,
}

// Windows virtual key codes
const VK_PRIOR: u16 = 0x21;
const VK_NEXT: u16 = 0x22;
const VK_LEFT: u16 = 0x25;
const VK_RIGHT: u16 = 0x27;
const VK_SPACE: u16 = 0x20;
const VK_RETURN: u16 = 0x0D;
const VK_ESCAPE: u16 = 0x1B;
const VK_TAB: u16 = 0x09;
const VK_UP: u16 = 0x26;
const VK_DOWN: u16 = 0x28;
const VK_F5: u16 = 0x74;
const VK_F11: u16 = 0x7A;

fn lookup_key(name: &str) -> Option<u16> {
    match name.to_lowercase().as_str() {
        "pageup" => Some(VK_PRIOR),
        "pagedown" => Some(VK_NEXT),
        "left" => Some(VK_LEFT),
        "right" => Some(VK_RIGHT),
        "up" => Some(VK_UP),
        "down" => Some(VK_DOWN),
        "space" => Some(VK_SPACE),
        "return" => Some(VK_RETURN),
        "escape" => Some(VK_ESCAPE),
        "tab" => Some(VK_TAB),
        "f5" => Some(VK_F5),
        "f11" => Some(VK_F11),
        s if s.len() == 1 && s.as_bytes()[0].is_ascii_alphabetic() => {
            Some(s.to_uppercase().as_bytes()[0] as u16)
        }
        _ => None,
    }
}

impl Default for KeyMapping {
    fn default() -> Self {
        Self {
            swipe_up: VK_PRIOR,
            swipe_down: VK_NEXT,
            swipe_left: VK_LEFT,
            swipe_right: VK_RIGHT,
            tap: VK_SPACE,
        }
    }
}

fn load_config() -> KeyMapping {
    let mut mapping = KeyMapping::default();

    let config_path = if cfg!(windows) {
        env::var("APPDATA")
            .map(|d| format!("{}\\ringbridge\\config.json", d))
            .ok()
    } else {
        dirs_config_path()
    };

    let path = match config_path {
        Some(p) => p,
        None => return mapping,
    };

    let data = match fs::read_to_string(&path) {
        Ok(d) => d,
        Err(_) => return mapping,
    };

    let cfg: ConfigFile = match serde_json::from_str(&data) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Warning: failed to parse config: {}", e);
            return mapping;
        }
    };

    if let Some(ref name) = cfg.swipe_up {
        if let Some(vk) = lookup_key(name) { mapping.swipe_up = vk; }
    }
    if let Some(ref name) = cfg.swipe_down {
        if let Some(vk) = lookup_key(name) { mapping.swipe_down = vk; }
    }
    if let Some(ref name) = cfg.swipe_left {
        if let Some(vk) = lookup_key(name) { mapping.swipe_left = vk; }
    }
    if let Some(ref name) = cfg.swipe_right {
        if let Some(vk) = lookup_key(name) { mapping.swipe_right = vk; }
    }
    if let Some(ref name) = cfg.tap {
        if let Some(vk) = lookup_key(name) { mapping.tap = vk; }
    }

    println!("Loaded config from {}", path);
    mapping
}

fn dirs_config_path() -> Option<String> {
    env::var("HOME")
        .map(|h| format!("{}/.config/ringbridge/config.json", h))
        .ok()
}

// --- Keystroke Injection ---

#[cfg(windows)]
fn send_key(vk: u16) {
    use std::mem;
    use winapi::um::winuser::{
        SendInput, INPUT, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP,
    };

    let mut inputs: [INPUT; 2] = unsafe { mem::zeroed() };

    inputs[0].type_ = INPUT_KEYBOARD;
    unsafe {
        *inputs[0].u.ki_mut() = KEYBDINPUT {
            wVk: vk,
            wScan: 0,
            dwFlags: 0,
            time: 0,
            dwExtraInfo: 0,
        };
    }

    inputs[1].type_ = INPUT_KEYBOARD;
    unsafe {
        *inputs[1].u.ki_mut() = KEYBDINPUT {
            wVk: vk,
            wScan: 0,
            dwFlags: KEYEVENTF_KEYUP,
            time: 0,
            dwExtraInfo: 0,
        };
    }

    unsafe {
        SendInput(2, inputs.as_mut_ptr(), mem::size_of::<INPUT>() as i32);
    }
}

#[cfg(not(windows))]
fn send_key(vk: u16) {
    println!("  [send_key 0x{:02X} - not on Windows, skipping]", vk);
}

// --- Gesture Detection ---

#[derive(Clone)]
struct Sample {
    value: i32,
    time_ms: u64,
}

struct GestureState {
    x_values: Vec<Sample>,
    y_values: Vec<Sample>,
    last_nav_time: u64,
    swipe_fired: bool,
    start: Instant,
    config: KeyMapping,
    debug: bool,
}

impl GestureState {
    fn new(config: KeyMapping, debug: bool) -> Self {
        Self {
            x_values: Vec::new(),
            y_values: Vec::new(),
            last_nav_time: 0,
            swipe_fired: false,
            start: Instant::now(),
            config,
            debug,
        }
    }

    fn now_ms(&self) -> u64 {
        self.start.elapsed().as_millis() as u64
    }

    fn add_sample(values: &mut Vec<Sample>, value: i32, now: u64) {
        values.retain(|s| now - s.time_ms < 500);
        values.push(Sample {
            value,
            time_ms: now,
        });
    }

    fn recent_range(values: &[Sample], now: u64) -> Option<(i32, i32, usize)> {
        let recent: Vec<_> = values
            .iter()
            .filter(|s| now - s.time_ms < WINDOW_MS)
            .collect();
        if recent.len() < MIN_SAMPLES {
            return None;
        }
        Some((recent.first().unwrap().value, recent.last().unwrap().value, recent.len()))
    }

    fn check_swipe(&mut self) {
        let now = self.now_ms();
        if now - self.last_nav_time < COOLDOWN_MS {
            return;
        }

        // Check vertical swipe
        if let Some((first, last, _)) = Self::recent_range(&self.y_values, now) {
            let delta = last - first;
            if delta.abs() > SWIPE_THRESHOLD {
                self.last_nav_time = now;
                self.swipe_fired = true;
                if delta > 0 {
                    println!("SWIPE DOWN (next) delta={}", delta);
                    send_key(self.config.swipe_down);
                } else {
                    println!("SWIPE UP (prev) delta={}", delta);
                    send_key(self.config.swipe_up);
                }
                self.x_values.clear();
                self.y_values.clear();
                return;
            }
        }

        // Check horizontal swipe
        if let Some((first, last, _)) = Self::recent_range(&self.x_values, now) {
            let delta = last - first;
            if delta.abs() > SWIPE_THRESHOLD {
                self.last_nav_time = now;
                self.swipe_fired = true;
                if delta > 0 {
                    println!("SWIPE RIGHT delta={}", delta);
                    send_key(self.config.swipe_right);
                } else {
                    println!("SWIPE LEFT delta={}", delta);
                    send_key(self.config.swipe_left);
                }
                self.x_values.clear();
                self.y_values.clear();
            }
        }
    }

    fn check_tap(&mut self) {
        if self.swipe_fired {
            return;
        }
        let now = self.now_ms();
        if now - self.last_nav_time < COOLDOWN_MS {
            return;
        }

        let delta_y = if self.y_values.len() >= 2 {
            (self.y_values.last().unwrap().value - self.y_values.first().unwrap().value).abs()
        } else {
            0
        };
        let delta_x = if self.x_values.len() >= 2 {
            (self.x_values.last().unwrap().value - self.x_values.first().unwrap().value).abs()
        } else {
            0
        };

        if delta_y < TAP_THRESHOLD && delta_x < TAP_THRESHOLD {
            self.last_nav_time = now;
            println!("TAP (center)");
            send_key(self.config.tap);
        }
    }

    fn on_touch_end(&mut self) {
        self.check_tap();
        self.x_values.clear();
        self.y_values.clear();
        self.swipe_fired = false;
    }
}

// --- HID Report Parsing ---
// The JX-05 sends raw HID reports. We need to find X, Y, and tip switch
// values from the report bytes. The report structure is device-specific,
// so we detect the layout from the first few reports.

fn parse_report(data: &[u8], state: &mut GestureState) {
    // The JX-05 sends reports with digitizer data.
    // Based on observed HID descriptors for this class of device:
    //
    // Report format (typical for BLE digitizer rings):
    //   Byte 0: Report ID
    //   Byte 1: Tip switch (bit 0) + other flags
    //   Byte 2-3: X value (little-endian 16-bit)
    //   Byte 4-5: Y value (little-endian 16-bit)
    //
    // However, the exact layout may vary. We use a heuristic approach:
    // look for plausible axis values in the expected range (0-3500).

    if data.len() < 6 {
        return;
    }

    let now = state.now_ms();

    // Try common digitizer report layout
    let report_id = data[0];
    let tip_switch = data[1] & 0x01;

    // For reports that carry coordinate data, extract 16-bit LE values
    // The ring sends different report types for different button directions:
    // - Up/down buttons: Y-axis data only
    // - Left/right buttons: X-axis data only
    // - Center: brief touch

    // Try to read X and Y as 16-bit little-endian from bytes 2-5
    let x_val = u16::from_le_bytes([data[2], data[3]]) as i32;
    let y_val = u16::from_le_bytes([data[4], data[5]]) as i32;

    if state.debug {
        print!("HID: id={} tip={} x={} y={}", report_id, tip_switch, x_val, y_val);
        if data.len() > 6 {
            print!(" raw=");
            for b in data {
                print!("{:02x} ", b);
            }
        }
        println!();
    }

    // Only process when tip is down (touching)
    // Track values and detect when they change meaningfully
    static mut PREV_TIP: u8 = 0;

    let prev_tip = unsafe { PREV_TIP };

    if tip_switch == 1 {
        // Check if Y value is in plausible range and changing
        if y_val > 0 && y_val < 4000 {
            GestureState::add_sample(&mut state.y_values, y_val, now);
            state.check_swipe();
        }
        if x_val > 0 && x_val < 4000 {
            GestureState::add_sample(&mut state.x_values, x_val, now);
            state.check_swipe();
        }
    }

    if prev_tip == 1 && tip_switch == 0 {
        state.on_touch_end();
    }

    unsafe {
        PREV_TIP = tip_switch;
    }
}

// --- Main ---

fn main() {
    let args: Vec<String> = env::args().collect();
    let debug = args.iter().any(|a| a == "--debug");

    let config = load_config();

    println!("Ring Bridge - JX-05 Gesture Controller (Windows)");
    println!(
        "Mappings: up=0x{:02X} down=0x{:02X} left=0x{:02X} right=0x{:02X} tap=0x{:02X}",
        config.swipe_up, config.swipe_down, config.swipe_left, config.swipe_right, config.tap
    );

    let api = HidApi::new().expect("Failed to initialize HID API");

    // Find JX-05 device
    let device_info = api
        .device_list()
        .find(|d| {
            d.product_string()
                .map(|s| s.contains("JX-05"))
                .unwrap_or(false)
        });

    let info = match device_info {
        Some(i) => {
            println!(
                "Found JX-05: vendor=0x{:04X} product=0x{:04X}",
                i.vendor_id(),
                i.product_id()
            );
            i.clone()
        }
        None => {
            eprintln!("ERROR: JX-05 not found! Make sure the ring is connected via Bluetooth.");
            if debug {
                println!("\nAll HID devices:");
                for d in api.device_list() {
                    println!(
                        "  {:04X}:{:04X} \"{}\"",
                        d.vendor_id(),
                        d.product_id(),
                        d.product_string().unwrap_or("?")
                    );
                }
            }
            std::process::exit(1);
        }
    };

    let device = info
        .open_device(&api)
        .expect("Failed to open JX-05. Try running as Administrator.");

    if cfg!(windows) {
        println!("Config: %APPDATA%\\ringbridge\\config.json");
    } else {
        println!("Config: ~/.config/ringbridge/config.json");
    }
    println!("Press Ctrl+C to stop.\n");

    let running = Arc::new(AtomicBool::new(true));
    let r = running.clone();
    ctrlc_handler(r);

    let mut state = GestureState::new(config, debug);
    let mut buf = [0u8; 256];

    // Set non-blocking so we can check the running flag
    device
        .set_blocking_mode(false)
        .expect("Failed to set non-blocking mode");

    while running.load(Ordering::Relaxed) {
        match device.read_timeout(&mut buf, 100) {
            Ok(0) => continue, // timeout, no data
            Ok(n) => {
                parse_report(&buf[..n], &mut state);
            }
            Err(e) => {
                eprintln!("Read error: {}", e);
                break;
            }
        }
    }

    println!("\nStopped.");
}

fn ctrlc_handler(running: Arc<AtomicBool>) {
    let _ = ctrlc::set_handler(move || {
        running.store(false, Ordering::Relaxed);
    });
}
