// STATUS: ACTIVE
// PURPOSE: mac idle time detection — queries IOKit HIDIdleTime to detect user inactivity

/// Seconds since last keyboard/mouse input on this Mac.
/// Returns 0 on error (fail-safe: treat as active, allow GRACE instead of instant lock).
pub fn idle_secs() -> u64 {
    let output = std::process::Command::new("ioreg")
        .args(["-c", "IOHIDSystem", "-d", "4"])
        .output();

    if let Ok(out) = output {
        let text = String::from_utf8_lossy(&out.stdout);
        for line in text.lines() {
            if line.contains("HIDIdleTime") {
                // Line format: "HIDIdleTime" = 1234567890 (nanoseconds)
                if let Some(val) = line.split('=').nth(1) {
                    if let Ok(ns) = val.trim().parse::<u64>() {
                        return ns / 1_000_000_000;
                    }
                }
            }
        }
    }
    0 // fail-safe: assume active
}
