// Hash-chained audit log
// Append-only NDJSON// PR4a: Audit module - tamper-evident logging

pub mod record;
pub mod verifier;
pub mod writer;

// Re-export main types
pub use record::AuditEvent;
pub use writer::AuditWriter;
