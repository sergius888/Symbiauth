#![no_main]
use libfuzzer_sys::fuzz_target;

// Fuzz UDS frame parsing: length prefix + JSON payload
fuzz_target!(|data: &[u8]| {
    // Must handle all inputs gracefully without panicking
    
    // Simulate UDS length-prefix parsing
    if data.len() >= 4 {
        let len_bytes = [data[0], data[1], data[2], data[3]];
        let frame_length = u32::from_be_bytes(len_bytes) as usize;
        
        // Validate frame size (should not panic on large values)
        if frame_length > 0 && frame_length <= 65536 && data.len() >= 4 + frame_length {
            let frame_data = &data[4..4 + frame_length];
            
            // Try to parse as JSON (agent expects JSON messages)
            let _ = serde_json::from_slice::<serde_json::Value>(frame_data);
        }
    }
});
