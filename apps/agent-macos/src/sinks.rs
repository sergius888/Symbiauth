#![allow(dead_code)]

use std::{env, io, sync::Arc, time::Duration};

use serde_json::Value;
use tokio::io::AsyncWriteExt;
use tokio::net::unix::OwnedWriteHalf;
use tokio::sync::Mutex;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum SinkRole {
    Tls,
    Nm,
}

#[derive(Default)]
pub struct SinkRegistry {
    tls: Option<Arc<Mutex<OwnedWriteHalf>>>,
    nm: Option<Arc<Mutex<OwnedWriteHalf>>>,
}

impl SinkRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(
        &mut self,
        role: SinkRole,
        writer: Arc<Mutex<OwnedWriteHalf>>,
    ) -> Option<Arc<Mutex<OwnedWriteHalf>>> {
        use std::mem::replace;
        match role {
            SinkRole::Tls => replace(&mut self.tls, Some(writer)),
            SinkRole::Nm => replace(&mut self.nm, Some(writer)),
        }
    }

    pub fn get(&self, role: SinkRole) -> Option<Arc<Mutex<OwnedWriteHalf>>> {
        match role {
            SinkRole::Tls => self.tls.as_ref().cloned(),
            SinkRole::Nm => self.nm.as_ref().cloned(),
        }
    }

    pub fn clear_role(&mut self, role: SinkRole) {
        match role {
            SinkRole::Tls => self.tls = None,
            SinkRole::Nm => self.nm = None,
        }
    }

    pub async fn send_to(&mut self, role: SinkRole, payload: &Value) -> bool {
        let writer = match role {
            SinkRole::Tls => self.tls.as_ref().cloned(),
            SinkRole::Nm => self.nm.as_ref().cloned(),
        };
        if let Some(writer) = writer {
            send_json(&writer, payload).await.is_ok()
        } else {
            false
        }
    }
}

pub fn push_enabled() -> bool {
    let val = env::var("ARM_PUSH_AUTH")
        .ok()
        .or_else(|| env::var("ARM_PUSH_ENABLED").ok());
    matches!(val.as_deref(), Some("1") | Some("true") | Some("TRUE"))
}

pub fn hello_timeout() -> Duration {
    let ms = env::var("ARM_HELLO_TIMEOUT_MS")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(3000);
    Duration::from_millis(ms)
}

pub async fn send_json(
    writer: &Arc<Mutex<OwnedWriteHalf>>,
    payload: &serde_json::Value,
) -> io::Result<()> {
    let mut guard = writer.lock().await;
    let bytes = serde_json::to_vec(payload).map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
    let len = (bytes.len() as u32).to_be_bytes();
    guard.write_all(&len).await?;
    guard.write_all(&bytes).await?;
    guard.flush().await
}
