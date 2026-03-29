// Audit log verifier
// Validates hash chain integrity

use super::record::AuditRecord;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

#[derive(Debug)]
pub struct VerificationResult {
    pub valid: bool,
    pub total_records: u64,
    pub last_valid_seq: u64,
    pub last_valid_hash: String,
    pub first_error: Option<VerificationError>,
}

#[derive(Debug)]
pub struct VerificationError {
    pub line: u64,
    pub kind: ErrorKind,
    pub message: String,
}

#[derive(Debug)]
pub enum ErrorKind {
    InvalidJson,
    HashMismatch,
    ChainBroken,
    SequenceGap,
}

/// Verify audit log hash chain
pub fn verify_chain(path: impl AsRef<Path>) -> std::io::Result<VerificationResult> {
    let path = path.as_ref();
    let file = File::open(path)?;
    let reader = BufReader::new(file);
    
    let mut total_records = 0;
    let mut last_valid_seq = 0;
    let mut last_valid_hash = "genesis".to_string();
    let mut first_error = None;
    
    for (line_num, line_result) in reader.lines().enumerate() {
        let line_no = (line_num + 1) as u64;
        
        let line = match line_result {
            Ok(l) if !l.trim().is_empty() => l,
            Ok(_) => continue, // Skip empty lines
            Err(e) => {
                if first_error.is_none() {
                    first_error = Some(VerificationError {
                        line: line_no,
                        kind: ErrorKind::InvalidJson,
                        message: format!("Read error: {}", e),
                    });
                }
                break;
            }
        };
        
        // Parse record
        let record: AuditRecord = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                if first_error.is_none() {
                    first_error = Some(VerificationError {
                        line: line_no,
                        kind: ErrorKind::InvalidJson,
                        message: format!("JSON parse error: {}", e),
                    });
                }
                break;
            }
        };
        
        total_records += 1;
        
        // Verify hash
        if !record.verify_hash() {
            if first_error.is_none() {
                first_error = Some(VerificationError {
                    line: line_no,
                    kind: ErrorKind::HashMismatch,
                    message: format!(
                        "Hash mismatch: expected computed hash, got={}",
                        record.this_hash
                    ),
                });
            }
            break;
        }
        
        // Verify chain link
        if record.prev_hash != last_valid_hash {
            if first_error.is_none() {
                first_error = Some(VerificationError {
                    line: line_no,
                    kind: ErrorKind::ChainBroken,
                    message: format!(
                        "Chain broken: expected prev_hash={}, got={}",
                        last_valid_hash,
                        record.prev_hash
                    ),
                });
            }
            break;
        }
        
        // Verify sequence
        if record.seq != last_valid_seq + 1 {
            if first_error.is_none() {
                first_error = Some(VerificationError {
                    line: line_no,
                    kind: ErrorKind::SequenceGap,
                    message: format!(
                        "Sequence gap: expected {}, got={}",
                        last_valid_seq + 1,
                        record.seq
                    ),
                });
            }
            break;
        }
        
        // Update state
        last_valid_seq = record.seq;
        last_valid_hash = record.this_hash;
    }
    
    Ok(VerificationResult {
        valid: first_error.is_none(),
        total_records,
        last_valid_seq,
        last_valid_hash,
        first_error,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audit::record::{AuditEvent, AuditRecord};
    use std::io::Write;
    use tempfile::NamedTempFile;
    
    #[test]
    fn test_verify_valid_chain() {
        let mut file = NamedTempFile::new().unwrap();
        
        // Write valid chain
        let rec1 = AuditRecord::new(1, "genesis".to_string(), AuditEvent::Startup);
        let mut rec1 = rec1;
        rec1.this_hash = rec1.compute_hash();
        writeln!(file, "{}", serde_json::to_string(&rec1).unwrap()).unwrap();
        
        let rec2 = AuditRecord::new(2, rec1.this_hash.clone(), AuditEvent::Shutdown);
        let mut rec2 = rec2;
        rec2.this_hash = rec2.compute_hash();
        writeln!(file, "{}", serde_json::to_string(&rec2).unwrap()).unwrap();
        
        file.flush().unwrap();
        
        // Verify
        let result = verify_chain(file.path()).unwrap();
        assert!(result.valid);
        assert_eq!(result.total_records, 2);
        assert_eq!(result.last_valid_seq, 2);
    }
    
    #[test]
    fn test_verify_tampered_chain() {
        let mut file = NamedTempFile::new().unwrap();
        
        // Write valid first record
        let rec1 = AuditRecord::new(1, "genesis".to_string(), AuditEvent::Startup);
        let mut rec1 = rec1;
        rec1.this_hash = rec1.compute_hash();
        writeln!(file, "{}", serde_json::to_string(&rec1).unwrap()).unwrap();
        
        // Write tampered second record (wrong hash)
        let rec2 = AuditRecord::new(2, rec1.this_hash.clone(), AuditEvent::Shutdown);
        let mut rec2 = rec2;
        rec2.this_hash = "invalid_hash".to_string(); // Tampered!
        writeln!(file, "{}", serde_json::to_string(&rec2).unwrap()).unwrap();
        
        file.flush().unwrap();
        
        // Verify
        let result = verify_chain(file.path()).unwrap();
        assert!(!result.valid);
        assert_eq!(result.total_records, 2); // Both parsed
        assert_eq!(result.last_valid_seq, 1); // Only first valid
        assert!(result.first_error.is_some());
        
        if let Some(err) = result.first_error {
            assert_eq!(err.line, 2);
            assert!(matches!(err.kind, ErrorKind::HashMismatch));
        }
    }
    
    #[test]
    fn test_verify_broken_chain() {
        let mut file = NamedTempFile::new().unwrap();
        
        // Write valid first record
        let rec1 = AuditRecord::new(1, "genesis".to_string(), AuditEvent::Startup);
        let mut rec1 = rec1;
        rec1.this_hash = rec1.compute_hash();
        writeln!(file, "{}", serde_json::to_string(&rec1).unwrap()).unwrap();
        
        // Write second record with wrong prev_hash
        let rec2 = AuditRecord::new(2, "wrong_hash".to_string(), AuditEvent::Shutdown);
        let mut rec2 = rec2;
        rec2.this_hash = rec2.compute_hash();
        writeln!(file, "{}", serde_json::to_string(&rec2).unwrap()).unwrap();
        
        file.flush().unwrap();
        
        // Verify
        let result = verify_chain(file.path()).unwrap();
        assert!(!result.valid);
        assert!(result.first_error.is_some());
        
        if let Some(err) = result.first_error {
            assert_eq!(err.line, 2);
            assert!(matches!(err.kind, ErrorKind::ChainBroken));
        }
    }
}
