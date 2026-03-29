use rusqlite::{params, Connection};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub struct Idempotency {
    conn: Mutex<Connection>,
}

impl Idempotency {
    pub fn new(conn: Connection) -> rusqlite::Result<Self> {
        let idem = Self {
            conn: Mutex::new(conn),
        };
        idem.migrate()?;
        Ok(idem)
    }

    fn migrate(&self) -> rusqlite::Result<()> {
        self.conn.lock().unwrap().execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS idempotency (
              key TEXT PRIMARY KEY,
              applied_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_idem_applied_at ON idempotency(applied_at);
        "#,
        )?;
        Ok(())
    }

    pub fn was_applied(&self, key: &str) -> rusqlite::Result<bool> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare("SELECT 1 FROM idempotency WHERE key = ?1 LIMIT 1")?;
        Ok(stmt.exists(params![key])?)
    }

    pub fn mark_applied(&self, key: &str) -> rusqlite::Result<()> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        self.conn.lock().unwrap().execute(
            "INSERT OR IGNORE INTO idempotency (key, applied_at) VALUES (?1, ?2)",
            params![key, now],
        )?;
        Ok(())
    }

    pub fn gc(&self, ttl_secs: u64) -> rusqlite::Result<usize> {
        let cutoff = (SystemTime::now().duration_since(UNIX_EPOCH).unwrap()
            - Duration::from_secs(ttl_secs))
        .as_secs() as i64;
        self.conn.lock().unwrap().execute(
            "DELETE FROM idempotency WHERE applied_at < ?1",
            params![cutoff],
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_idempotency_basic() {
        let conn = Connection::open_in_memory().unwrap();
        let idem = Idempotency::new(conn).unwrap();

        assert!(!idem.was_applied("key1").unwrap());
        idem.mark_applied("key1").unwrap();
        assert!(idem.was_applied("key1").unwrap());

        // Duplicate mark is no-op
        idem.mark_applied("key1").unwrap();
        assert!(idem.was_applied("key1").unwrap());
    }

    #[test]
    fn test_idempotency_gc() {
        use std::thread;
        use std::time::Duration as StdDuration;

        let conn = Connection::open_in_memory().unwrap();
        let idem = Idempotency::new(conn).unwrap();

        idem.mark_applied("old_key").unwrap();
        assert!(idem.was_applied("old_key").unwrap());

        // Sleep for 1 second to make old_key truly "old"
        thread::sleep(StdDuration::from_secs(1));

        idem.mark_applied("recent_key").unwrap();

        // GC with TTL=2s should keep both
        let deleted = idem.gc(2).unwrap();
        assert_eq!(deleted, 0, "Should keep both with TTL=2s");

        // GC with TTL=0s should delete old_key only (>1s old)
        let deleted = idem.gc(0).unwrap();
        assert_eq!(deleted, 1, "Should delete old_key that is >1s old");
        assert!(!idem.was_applied("old_key").unwrap());
        assert!(idem.was_applied("recent_key").unwrap());
    }

    #[test]
    fn test_idempotency_multiple_keys() {
        let conn = Connection::open_in_memory().unwrap();
        let idem = Idempotency::new(conn).unwrap();

        idem.mark_applied("key1").unwrap();
        idem.mark_applied("key2").unwrap();
        idem.mark_applied("key3").unwrap();

        assert!(idem.was_applied("key1").unwrap());
        assert!(idem.was_applied("key2").unwrap());
        assert!(idem.was_applied("key3").unwrap());
        assert!(!idem.was_applied("key4").unwrap());
    }
}
