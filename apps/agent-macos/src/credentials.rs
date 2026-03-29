use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use tracing::{info, warn};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CredentialManager {
    // For Step 1, we'll use in-memory storage
    // Later this will be replaced with secure storage
    credentials: HashMap<String, DomainCredentials>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DomainCredentials {
    pub domain: String,
    pub username: String,
    pub password: String,
    pub created_at: std::time::SystemTime,
    pub last_used: std::time::SystemTime,
}

impl CredentialManager {
    pub fn new() -> Self {
        let mut manager = Self {
            credentials: HashMap::new(),
        };

        // Add some dummy credentials for testing
        manager.add_test_credentials();
        manager
    }

    fn add_test_credentials(&mut self) {
        let now = std::time::SystemTime::now();

        // Add test credentials for common sites
        let test_creds = vec![
            ("gmail.com", "test@gmail.com", "test-password-123"),
            ("github.com", "testuser", "github-password-456"),
            ("twitter.com", "testuser", "twitter-password-789"),
        ];

        for (domain, username, password) in test_creds {
            let cred = DomainCredentials {
                domain: domain.to_string(),
                username: username.to_string(),
                password: password.to_string(),
                created_at: now,
                last_used: now,
            };

            self.credentials.insert(domain.to_string(), cred);
            info!("Added test credentials for domain: {}", domain);
        }
    }

    pub fn get_credentials(&mut self, domain: &str) -> Option<DomainCredentials> {
        if let Some(cred) = self.credentials.get_mut(domain) {
            cred.last_used = std::time::SystemTime::now();
            Some(cred.clone())
        } else {
            warn!("No credentials found for domain: {}", domain);
            None
        }
    }

    pub fn store_credentials(&mut self, domain: String, username: String, password: String) {
        let now = std::time::SystemTime::now();

        let cred = DomainCredentials {
            domain: domain.clone(),
            username,
            password,
            created_at: now,
            last_used: now,
        };

        self.credentials.insert(domain.clone(), cred);
        info!("Stored credentials for domain: {}", domain);
    }

    pub fn delete_credentials(&mut self, domain: &str) -> bool {
        if self.credentials.remove(domain).is_some() {
            info!("Deleted credentials for domain: {}", domain);
            true
        } else {
            warn!("No credentials found to delete for domain: {}", domain);
            false
        }
    }

    pub fn list_domains(&self) -> Vec<String> {
        self.credentials.keys().cloned().collect()
    }

    pub fn has_credentials(&self, domain: &str) -> bool {
        self.credentials.contains_key(domain)
    }
}
