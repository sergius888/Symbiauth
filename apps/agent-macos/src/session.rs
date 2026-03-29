use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::time::SystemTime;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionManager {
    active_sessions: HashMap<String, Session>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub session_id: String,
    pub device_fingerprint: String,
    pub created_at: SystemTime,
    pub last_activity: SystemTime,
    pub is_active: bool,
}

impl SessionManager {
    pub fn new() -> Self {
        Self {
            active_sessions: HashMap::new(),
        }
    }

    pub fn create_session(&mut self, device_fingerprint: String) -> String {
        let session_id = uuid::Uuid::new_v4().to_string();
        let now = SystemTime::now();

        let session = Session {
            session_id: session_id.clone(),
            device_fingerprint,
            created_at: now,
            last_activity: now,
            is_active: true,
        };

        self.active_sessions.insert(session_id.clone(), session);
        session_id
    }

    pub fn get_session(&self, session_id: &str) -> Option<&Session> {
        self.active_sessions.get(session_id)
    }

    pub fn update_activity(&mut self, session_id: &str) -> bool {
        if let Some(session) = self.active_sessions.get_mut(session_id) {
            session.last_activity = SystemTime::now();
            true
        } else {
            false
        }
    }

    pub fn end_session(&mut self, session_id: &str) -> bool {
        if let Some(session) = self.active_sessions.get_mut(session_id) {
            session.is_active = false;
            true
        } else {
            false
        }
    }

    pub fn cleanup_inactive_sessions(&mut self, timeout_seconds: u64) {
        let now = SystemTime::now();
        let timeout_duration = std::time::Duration::from_secs(timeout_seconds);

        self.active_sessions.retain(|_, session| {
            if let Ok(elapsed) = now.duration_since(session.last_activity) {
                elapsed < timeout_duration && session.is_active
            } else {
                false
            }
        });
    }

    pub fn list_active_sessions(&self) -> Vec<&Session> {
        self.active_sessions
            .values()
            .filter(|session| session.is_active)
            .collect()
    }
}
