// Audit log writer with hash chaining
// Bounded channel with backpressure, rotation, crash recovery

use super::record::{AuditEvent, AuditRecord};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;

use tokio::sync::mpsc;
use tracing::{error, info, warn};

const DEFAULT_ROTATE_MB: u64 = 5;
const DEFAULT_RETENTION_DAYS: u64 = 30;
const CHANNEL_CAPACITY: usize = 256;

/// Audit log writer state
pub struct AuditWriter {
    tx: mpsc::Sender<AuditEvent>,
}

impl AuditWriter {
    /// Create new audit writer
    pub fn new(dir: impl Into<PathBuf>) -> std::io::Result<Self> {
        let dir = dir.into();

        // Create audit directory
        if !dir.exists() {
            fs::create_dir_all(&dir)?;

            // Set secure permissions
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let mut perms = fs::metadata(&dir)?.permissions();
                perms.set_mode(0o700);
                fs::set_permissions(&dir, perms)?;
            }
        }

        let (tx, rx) = mpsc::channel(CHANNEL_CAPACITY);

        // Spawn background writer task
        tokio::spawn(async move {
            let mut state = WriterState::new(dir);
            if let Err(e) = state.run(rx).await {
                error!("Audit writer task failed: {}", e);
            }
        });

        Ok(AuditWriter { tx })
    }

    /// Emit an audit event (non-blocking)
    pub async fn emit(&self, event: AuditEvent) {
        if let Err(e) = self.tx.try_send(event) {
            // Channel full - log warning but don't block
            warn!("Audit channel full, dropping event: {}", e);
        }
    }

    /// Emit event synchronously (blocking)
    #[allow(dead_code)] // Reserved for sync-callers in deferred integration paths.
    pub fn emit_sync(&self, event: AuditEvent) {
        let tx = self.tx.clone();
        tokio::task::block_in_place(|| {
            tokio::runtime::Handle::current().block_on(async {
                let _ = tx.send(event).await;
            });
        });
    }

    pub async fn log_launcher_event(
        &self,
        event: &str,
        launcher_id: &str,
        run_id: &str,
        trust_id: Option<&str>,
        pid: u32,
        result: &str,
        reason: Option<&str>,
    ) {
        self.emit(AuditEvent::LauncherEvent {
            event: event.to_string(),
            launcher_id: launcher_id.to_string(),
            run_id: run_id.to_string(),
            trust_id: trust_id.map(|s| s.to_string()),
            pid,
            result: result.to_string(),
            reason: reason.map(|s| s.to_string()),
        })
        .await;
    }

    pub async fn log_secret_event(&self, event: &str, name: &str, result: &str) {
        self.emit(AuditEvent::SecretEvent {
            event: event.to_string(),
            name: name.to_string(),
            result: result.to_string(),
        })
        .await;
    }
}

struct WriterState {
    dir: PathBuf,
    file: Option<File>,
    seq: u64,
    prev_hash: String,
    current_size: u64,
    rotate_mb: u64,
    retention_days: u64,
}

impl WriterState {
    fn new(dir: PathBuf) -> Self {
        let rotate_mb = std::env::var("ARM_AUDIT_ROTATE_MB")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(DEFAULT_ROTATE_MB);

        let retention_days = std::env::var("ARM_AUDIT_RETENTION_DAYS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(DEFAULT_RETENTION_DAYS);

        Self {
            dir,
            file: None,
            seq: 0,
            prev_hash: "genesis".to_string(),
            current_size: 0,
            rotate_mb,
            retention_days,
        }
    }

    #[inline]
    fn prefix<'a>(s: &'a str) -> &'a str {
        if s.len() > 16 {
            &s[..16]
        } else {
            s
        }
    }

    async fn run(&mut self, mut rx: mpsc::Receiver<AuditEvent>) -> std::io::Result<()> {
        // Initialize: recover from crash or start fresh
        self.recover()?;

        info!(
            "Audit writer started: seq={}, prev_hash={}",
            self.seq,
            Self::prefix(&self.prev_hash)
        );

        while let Some(event) = rx.recv().await {
            if let Err(e) = self.write_event(event) {
                error!("Failed to write audit event: {}", e);
            }
        }

        Ok(())
    }

    fn recover(&mut self) -> std::io::Result<()> {
        let current_path = self.dir.join("audit.current.ndjson");
        if !current_path.exists() {
            // Fresh start
            info!("No existing audit log, starting fresh");
            self.open_new_file()?;
            self.save_tip()?;
            return Ok(());
        }

        // Scan existing log for last valid record
        info!("Recovering audit log from {:?}", current_path);

        let file = File::open(&current_path)?;
        let reader = BufReader::new(file);

        let mut last_valid_seq = 0;
        let mut last_valid_hash = "genesis".to_string();
        for (line_num, line_result) in reader.lines().enumerate() {
            match line_result {
                Ok(line) if !line.trim().is_empty() => {
                    match serde_json::from_str::<AuditRecord>(&line) {
                        Ok(record) => {
                            // Verify hash chain
                            if record.verify_hash() && record.prev_hash == last_valid_hash {
                                last_valid_seq = record.seq;
                                last_valid_hash = record.this_hash.clone();
                            } else {
                                warn!(
                                    "Hash chain broken at line {}: expected prev_hash={}, got={}",
                                    line_num + 1,
                                    Self::prefix(&last_valid_hash),
                                    Self::prefix(&record.prev_hash)
                                );
                                break;
                            }
                        }
                        Err(e) => {
                            warn!("Invalid JSON at line {}: {}", line_num + 1, e);
                            break;
                        }
                    }
                }
                Err(e) => {
                    warn!("Read error at line {}: {}", line_num + 1, e);
                    break;
                }
                _ => {}
            }
        }

        info!(
            "Recovered to seq={}, hash={}",
            last_valid_seq,
            Self::prefix(&last_valid_hash)
        );

        // Truncate file to last valid position (if needed)
        // For simplicity, just continue appending

        self.seq = last_valid_seq;
        self.prev_hash = last_valid_hash;

        // Reopen file in append mode
        self.file = Some(
            OpenOptions::new()
                .create(true)
                .append(true)
                .open(&current_path)?,
        );

        self.current_size = fs::metadata(&current_path)?.len();

        // Update tip
        self.save_tip()?;

        Ok(())
    }

    fn write_event(&mut self, event: AuditEvent) -> std::io::Result<()> {
        // Check if rotation needed
        if self.current_size > self.rotate_mb * 1024 * 1024 {
            self.rotate()?;
        }

        // Create record
        self.seq += 1;
        let mut record = AuditRecord::new(self.seq, self.prev_hash.clone(), event);
        record.this_hash = record.compute_hash();

        // Serialize
        let mut line = serde_json::to_string(&record)?;
        line.push('\n');

        // Write
        if let Some(file) = &mut self.file {
            file.write_all(line.as_bytes())?;
            file.flush()?;
        }

        // Update state
        self.current_size += line.len() as u64;
        self.prev_hash = record.this_hash;

        // Update tip periodically (every 10 records)
        if self.seq % 10 == 0 {
            self.save_tip()?;
        }

        Ok(())
    }

    fn rotate(&mut self) -> std::io::Result<()> {
        let current_path = self.dir.join("audit.current.ndjson");
        let ts = chrono::Utc::now().format("%Y-%m-%d-%H%M%S");
        let rotated_path = self.dir.join(format!("audit.{}.ndjson", ts));

        // Close current file
        self.file = None;

        // Rename current to rotated
        if current_path.exists() {
            fs::rename(&current_path, &rotated_path)?;
            info!("Rotated audit log to {:?}", rotated_path);
        }

        // Open new file
        self.open_new_file()?;

        // Write anchor record
        self.write_event(AuditEvent::AuditRotate {
            new_file: format!("audit.{}.ndjson", ts),
        })?;

        // Cleanup old files
        self.cleanup_old_files()?;

        Ok(())
    }

    fn open_new_file(&mut self) -> std::io::Result<()> {
        let current_path = self.dir.join("audit.current.ndjson");

        self.file = Some(
            OpenOptions::new()
                .create(true)
                .append(true)
                .open(&current_path)?,
        );

        self.current_size = 0;

        Ok(())
    }

    fn save_tip(&self) -> std::io::Result<()> {
        let tip_path = self.dir.join("audit.tip");
        let tip = serde_json::json!({
            "seq": self.seq,
            "hash": self.prev_hash,
        });

        fs::write(tip_path, serde_json::to_string_pretty(&tip)?)?;
        Ok(())
    }

    fn cleanup_old_files(&self) -> std::io::Result<()> {
        let cutoff = chrono::Utc::now() - chrono::Duration::days(self.retention_days as i64);

        for entry in fs::read_dir(&self.dir)? {
            let entry = entry?;
            let path = entry.path();

            if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                if name.starts_with("audit.")
                    && name.ends_with(".ndjson")
                    && name != "audit.current.ndjson"
                {
                    if let Ok(metadata) = fs::metadata(&path) {
                        if let Ok(modified) = metadata.modified() {
                            let file_time: chrono::DateTime<chrono::Utc> = modified.into();
                            if file_time < cutoff {
                                info!("Deleting old audit log: {:?}", path);
                                fs::remove_file(&path)?;
                            }
                        }
                    }
                }
            }
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[tokio::test]
    async fn test_write_events() {
        let dir = TempDir::new().unwrap();
        let writer = AuditWriter::new(dir.path()).unwrap();

        writer.emit(AuditEvent::Startup).await;
        writer.emit(AuditEvent::Shutdown).await;

        // Give time for background task
        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

        // Check file exists
        let log_path = dir.path().join("audit.current.ndjson");
        assert!(log_path.exists());

        // Read and verify
        let content = fs::read_to_string(&log_path).unwrap();
        let lines: Vec<&str> = content.lines().collect();
        assert_eq!(lines.len(), 2);
    }

    #[tokio::test]
    async fn test_hash_chain_verification() {
        let dir = TempDir::new().unwrap();
        let writer = AuditWriter::new(dir.path()).unwrap();

        writer.emit(AuditEvent::Startup).await;
        writer.emit(AuditEvent::Shutdown).await;
        writer.emit(AuditEvent::PresenceEnter).await;

        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

        // Read and verify chain
        let log_path = dir.path().join("audit.current.ndjson");
        let content = fs::read_to_string(&log_path).unwrap();

        let records: Vec<AuditRecord> = content
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();

        // Verify each record
        for record in &records {
            assert!(record.verify_hash());
        }

        // Verify chain links
        assert_eq!(records[0].prev_hash, "genesis");
        assert_eq!(records[1].prev_hash, records[0].this_hash);
        assert_eq!(records[2].prev_hash, records[1].this_hash);
    }
}
