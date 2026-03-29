// Library entry point - exports public modules for tests and external use

// Export all modules
pub mod auth;
pub mod ble_global;
pub mod ble_scanner;
pub mod bridge;
pub mod config;
#[allow(dead_code)] // Deferred subsystem (not in active runtime path).
pub mod credentials;
pub mod error;
pub mod idempotency;
pub mod launcher;
pub mod pairing;
#[allow(dead_code)] // Deferred subsystem (not in active runtime path).
pub mod policy;
pub mod proximity;
pub mod ratelimit;
#[allow(dead_code)] // Deferred subsystem (not in active runtime path).
pub mod recovery;
pub mod secrets;
#[allow(dead_code)] // Deferred subsystem (not in active runtime path).
pub mod session;
pub mod sinks;
pub mod trust;
#[allow(dead_code, deprecated)] // Deferred subsystem; generic-array migration pending.
pub mod vault;
#[allow(dead_code)] // Deferred subsystem (not in active runtime path).
pub mod webext_host;
pub mod wrap;

// PR2: TLS certificate rotation
pub mod audit;
pub mod origin;
pub mod rotation_controller;
pub mod startup;
pub mod time; // M1.5: Clock abstraction
pub mod tls_config;
#[allow(dead_code, unused_imports)] // Deferred subsystem (not in active runtime path).
pub mod totp; // M2: TOTP engine for remote approvals

// Re-export commonly used types at crate root for backwards compatibility
// (imports in bridge.rs and main.rs use `crate::Type` instead of `crate::module::Type`)
pub use auth::{AuthPolicy, AuthState};
pub use pairing::PairingManager;
pub use policy::Policy;
pub use proximity::{ProxMode, Proximity};
pub use sinks::SinkRegistry;
pub use trust::TrustController;
pub use vault::Vault;
