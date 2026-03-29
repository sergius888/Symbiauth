// Audit record structure

use serde::{Deserialize, Serialize};

/// Audit event types
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuditEvent {
    Startup,
    Shutdown,
    PolicyLoaded {
        hash: String,
    },
    PresenceEnter,
    PresenceLeave,
    ProximityModeChanged {
        mode: String,
    },
    AuthRequest {
        origin: String,
        action: String,
    },
    AuthOk {
        origin: String,
        action: String,
    },
    AuthCancel {
        origin: String,
    },
    AuthTimeout {
        origin: String,
    },
    Decision {
        origin: String,
        action: String,
        decision: String,    // "allow" | "deny" | "step_up"
        via: Option<String>, // "proximity" | "remote" | "token" | "step_up"
    },
    CredGet {
        origin: String,
    },
    CredWrite {
        origin: String,
    },
    VaultRead,
    VaultWrite,
    RemoteGrant {
        origin: String,
        action: String,
    },
    RemoteRevoke {
        origin: String,
    },
    CertRotateStaged {
        old_fp: String,
        new_fp: String,
    },
    CertRotatePromoted {
        new_fp: String,
    },
    CertRotateCancel {
        fp: String,
    },
    AuditDrop {
        count: u64,
    },
    AuditTamperDetected {
        seq: u64,
        line: String,
    },
    AuditRotate {
        new_file: String,
    },
    LauncherEvent {
        event: String,
        launcher_id: String,
        run_id: String,
        trust_id: Option<String>,
        pid: u32,
        result: String,
        reason: Option<String>,
    },
    SecretEvent {
        event: String,
        name: String,
        result: String,
    },
}

/// Single audit record (one line of NDJSON)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditRecord {
    /// ISO 8601 timestamp
    pub ts: String,

    /// Sequence number (monotonically increasing)
    pub seq: u64,

    /// Hash of previous record (base64)
    pub prev_hash: String,

    /// Hash of this record's payload (base64)
    /// Computed as SHA-256(prev_hash || payload_bytes_without_this_hash)
    pub this_hash: String,

    /// Event type and details
    #[serde(flatten)]
    pub event: AuditEvent,

    /// Correlation ID (if available)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub corr_id: Option<String>,

    /// Agent fingerprint
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_fp: Option<String>,

    /// Device name
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,

    /// Latency in milliseconds
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latency_ms: Option<u64>,

    /// Error code (if applicable)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub err_code: Option<String>,
}

impl AuditRecord {
    /// Create a new audit record
    pub fn new(seq: u64, prev_hash: String, event: AuditEvent) -> Self {
        let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);

        Self {
            ts,
            seq,
            prev_hash,
            this_hash: String::new(), // Computed after serialization
            event,
            corr_id: None,
            agent_fp: None,
            device: None,
            latency_ms: None,
            err_code: None,
        }
    }

    /// Compute hash of this record
    /// Hash = SHA-256(prev_hash || payload_bytes_without_this_hash)
    pub fn compute_hash(&self) -> String {
        use sha2::{Digest, Sha256};

        // Serialize without this_hash
        let mut record_copy = self.clone();
        record_copy.this_hash = String::new();

        let payload_bytes =
            serde_json::to_vec(&record_copy).expect("Failed to serialize audit record");

        // Compute hash: SHA-256(prev_hash || payload)
        let mut hasher = Sha256::new();
        hasher.update(self.prev_hash.as_bytes());
        hasher.update(&payload_bytes);
        let hash = hasher.finalize();

        // Encode as base64
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, hash)
    }

    /// Verify this record's hash
    pub fn verify_hash(&self) -> bool {
        let computed = self.compute_hash();
        computed == self.this_hash
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hash_computation() {
        let record = AuditRecord::new(1, "genesis".to_string(), AuditEvent::Startup);

        let hash = record.compute_hash();
        assert!(!hash.is_empty());
        assert_ne!(hash, "genesis");
    }

    #[test]
    fn test_hash_verification() {
        let mut record = AuditRecord::new(1, "genesis".to_string(), AuditEvent::Startup);

        record.this_hash = record.compute_hash();
        assert!(record.verify_hash());

        // Tamper with hash
        record.this_hash = "invalid".to_string();
        assert!(!record.verify_hash());
    }

    #[test]
    fn test_hash_chain() {
        let rec1 = AuditRecord::new(1, "genesis".to_string(), AuditEvent::Startup);
        let hash1 = rec1.compute_hash();

        let rec2 = AuditRecord::new(2, hash1.clone(), AuditEvent::Shutdown);
        let hash2 = rec2.compute_hash();

        // Hashes should be different
        assert_ne!(hash1, hash2);

        // Chain should link
        assert_eq!(rec2.prev_hash, hash1);
    }
}
