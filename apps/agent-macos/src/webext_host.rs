use serde_json::{json, Value};
use std::io::{self, Read, Write};
use tracing::{debug, error, info};

use crate::credentials::CredentialManager;

pub struct WebExtensionHost {
    credential_manager: CredentialManager,
}

impl WebExtensionHost {
    pub fn new() -> Self {
        Self {
            credential_manager: CredentialManager::new(),
        }
    }

    pub fn run(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        info!("Starting Chrome Native Messaging host");

        loop {
            match self.read_message() {
                Ok(message) => {
                    debug!("Received message from extension: {:?}", message);

                    let response = self.handle_message(message);

                    if let Err(e) = self.send_message(&response) {
                        error!("Failed to send response: {}", e);
                        break;
                    }
                }
                Err(e) => {
                    error!("Failed to read message: {}", e);
                    break;
                }
            }
        }

        Ok(())
    }

    fn read_message(&self) -> Result<Value, Box<dyn std::error::Error>> {
        let mut stdin = io::stdin();

        // Read message length (4 bytes, little-endian for Chrome)
        let mut length_bytes = [0u8; 4];
        stdin.read_exact(&mut length_bytes)?;
        let length = u32::from_le_bytes(length_bytes) as usize;

        // Validate message length
        if length > 1024 * 1024 {
            return Err("Message too large".into());
        }

        // Read message content
        let mut buffer = vec![0u8; length];
        stdin.read_exact(&mut buffer)?;

        // Parse JSON
        let message_str = String::from_utf8(buffer)?;
        let message: Value = serde_json::from_str(&message_str)?;

        Ok(message)
    }

    fn send_message(&self, message: &Value) -> Result<(), Box<dyn std::error::Error>> {
        let message_str = serde_json::to_string(message)?;
        let message_bytes = message_str.as_bytes();

        // Send length (4 bytes, little-endian for Chrome)
        let length = message_bytes.len() as u32;
        let length_bytes = length.to_le_bytes();

        io::stdout().write_all(&length_bytes)?;
        io::stdout().write_all(message_bytes)?;
        io::stdout().flush()?;

        debug!("Sent message to extension: {}", message_str);
        Ok(())
    }

    fn handle_message(&mut self, message: Value) -> Value {
        let msg_type = message.get("type").and_then(|t| t.as_str());

        match msg_type {
            Some("requestCredential") => self.handle_credential_request(message),
            Some("ping") => json!({
                "type": "pong",
                "timestamp": chrono::Utc::now().to_rfc3339()
            }),
            Some(unknown_type) => {
                error!("Unknown message type from extension: {}", unknown_type);
                json!({
                    "type": "error",
                    "code": "UNKNOWN_MESSAGE_TYPE",
                    "message": format!("Unknown message type: {}", unknown_type)
                })
            }
            None => {
                error!("Message missing type field");
                json!({
                    "type": "error",
                    "code": "MISSING_TYPE",
                    "message": "Message must include a 'type' field"
                })
            }
        }
    }

    fn handle_credential_request(&mut self, message: Value) -> Value {
        let domain = match message.get("domain").and_then(|d| d.as_str()) {
            Some(d) => d,
            None => {
                return json!({
                    "type": "error",
                    "code": "MISSING_DOMAIN",
                    "message": "Missing domain field in credential request"
                });
            }
        };

        info!("Credential request for domain: {}", domain);

        match self.credential_manager.get_credentials(domain) {
            Some(cred) => {
                info!("Found credentials for domain: {}", domain);
                json!({
                    "type": "credential",
                    "username": cred.username,
                    "password": cred.password
                })
            }
            None => {
                info!("No credentials found for domain: {}", domain);
                json!({
                    "type": "error",
                    "code": "NO_CREDENTIALS",
                    "message": format!("No credentials found for domain: {}", domain)
                })
            }
        }
    }
}
