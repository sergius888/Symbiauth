// Manual test harness for certificate rotation
// Run with: cargo run --bin test-rotation

use agent_macos::{rotation_controller::RotationController, tls_config::TlsConfig};
use std::path::Path;

fn main() {
    println!("🔄 Certificate Rotation Test Harness\n");

    // Use default config path
    let config_path = TlsConfig::default_path();
    println!("Config path: {:?}\n", config_path);

    // Initialize controller
    let controller = RotationController::new(&config_path);

    // Check if config exists
    if !config_path.exists() {
        println!("⚠️  Config file doesn't exist yet.");
        println!("Creating initial config with dummy cert...\n");

        let initial_config = TlsConfig::new(
            "/tmp/dummy_current.pem",
            "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        );

        if let Err(e) = initial_config.save(&config_path) {
            eprintln!("❌ Failed to create initial config: {}", e);
            return;
        }

        println!("✅ Initial config created\n");
    }

    // Show current status
    match controller.status() {
        Ok(status) => {
            println!("📊 Current Status:");
            println!("  Rotating: {}", status.is_rotating);
            println!("  Current FP: {}", status.fp_current);
            if let Some(next) = &status.fp_next {
                println!("  Next FP: {}", next);
                if let Some(days) = status.days_remaining {
                    println!("  Days remaining: {}", days);
                }
                println!("  Window expired: {}", status.window_expired);
            }
            println!();
        }
        Err(e) => {
            eprintln!("❌ Failed to get status: {}", e);
            return;
        }
    }

    // Check command line args
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 2 {
        println!("Usage:");
        println!("  cargo run --bin test-rotation stage <cert-path>");
        println!("  cargo run --bin test-rotation promote");
        println!("  cargo run --bin test-rotation cancel");
        println!("  cargo run --bin test-rotation status");
        return;
    }

    match args[1].as_str() {
        "stage" => {
            if args.len() < 3 {
                eprintln!("❌ Usage: stage <cert-path>");
                return;
            }

            let cert_path = &args[2];
            println!("🔧 Staging rotation with cert: {}\n", cert_path);

            match controller.stage(cert_path) {
                Ok(()) => {
                    println!("✅ Rotation staged successfully!\n");

                    // Show updated status
                    if let Ok(status) = controller.status() {
                        println!("📊 Updated Status:");
                        println!("  Current FP: {}", status.fp_current);
                        println!("  Next FP: {}", status.fp_next.unwrap_or_default());
                        println!("  Days remaining: {}", status.days_remaining.unwrap_or(0));
                    }
                }
                Err(e) => {
                    eprintln!("❌ Stage failed: {}", e);
                }
            }
        }

        "promote" => {
            println!("⬆️  Promoting rotation...\n");

            match controller.promote() {
                Ok(()) => {
                    println!("✅ Rotation promoted successfully!");
                    println!("⚠️  Restart TLS server to apply new certificate\n");

                    // Show updated status
                    if let Ok(status) = controller.status() {
                        println!("📊 Updated Status:");
                        println!("  Rotating: {}", status.is_rotating);
                        println!("  Current FP: {}", status.fp_current);
                    }
                }
                Err(e) => {
                    eprintln!("❌ Promote failed: {}", e);
                }
            }
        }

        "cancel" => {
            println!("🚫 Canceling rotation...\n");

            match controller.cancel() {
                Ok(()) => {
                    println!("✅ Rotation canceled successfully!\n");

                    // Show updated status
                    if let Ok(status) = controller.status() {
                        println!("📊 Updated Status:");
                        println!("  Rotating: {}", status.is_rotating);
                        println!("  Current FP: {}", status.fp_current);
                    }
                }
                Err(e) => {
                    eprintln!("❌ Cancel failed: {}", e);
                }
            }
        }

        "status" => {
            // Already shown above
            println!("✅ Status displayed above");
        }

        _ => {
            eprintln!("❌ Unknown command: {}", args[1]);
            println!("\nAvailable commands: stage, promote, cancel, status");
        }
    }
}
