use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

pub const KEYCHAIN_SERVICE: &str = "com.symbiauth.secrets";
const SECRET_REGISTRY_FILE: &str = ".armadillo/chamber_secret_registry.json";

#[derive(Clone, Debug)]
pub struct SecretRegistryEntry {
    pub name: String,
    pub created_at_ms: Option<u64>,
}

pub fn validate_secret_name(name: &str) -> Result<(), String> {
    if name.is_empty() || name.len() > 128 {
        return Err("invalid_secret_name".to_string());
    }
    if !name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.')
    {
        return Err("invalid_secret_name".to_string());
    }
    Ok(())
}

pub fn validate_secret_value(value: &str) -> Result<(), String> {
    if value.is_empty() || value.len() > 8192 {
        return Err("value_too_large".to_string());
    }
    Ok(())
}

pub fn collect_secret_refs(launchers: &[crate::launcher::Launcher]) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut refs = Vec::new();
    for launcher in launchers {
        for secret_ref in &launcher.secret_refs {
            if seen.insert(secret_ref.clone()) {
                refs.push(secret_ref.clone());
            }
        }
    }
    refs
}

pub fn list_registered_secret_entries() -> Result<Vec<SecretRegistryEntry>, String> {
    let path = secret_registry_path()?;
    if !path.exists() {
        return Ok(Vec::new());
    }

    let raw = fs::read_to_string(&path).map_err(|e| format!("secret_registry_read_failed:{}", e))?;
    let value: serde_json::Value =
        serde_json::from_str(&raw).map_err(|e| format!("secret_registry_decode_failed:{}", e))?;

    let mut normalized = Vec::<SecretRegistryEntry>::new();
    let mut seen = BTreeSet::new();

    match value {
        serde_json::Value::Array(names) => {
            for name_value in names {
                if let Some(name) = name_value.as_str() {
                    validate_secret_name(name)?;
                    if seen.insert(name.to_string()) {
                        normalized.push(SecretRegistryEntry {
                            name: name.to_string(),
                            created_at_ms: None,
                        });
                    }
                }
            }
        }
        serde_json::Value::Object(map) => {
            for (name, meta) in map {
                validate_secret_name(&name)?;
                if !seen.insert(name.clone()) {
                    continue;
                }
                let created_at_ms = meta
                    .get("created_at_ms")
                    .and_then(|value| value.as_u64());
                normalized.push(SecretRegistryEntry { name, created_at_ms });
            }
        }
        _ => {
            return Err("secret_registry_decode_failed:unsupported_format".to_string());
        }
    }

    normalized.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(normalized)
}

pub fn register_secret_name(name: &str) -> Result<(), String> {
    validate_secret_name(name)?;
    let mut entries = HashMap::<String, SecretRegistryEntry>::new();
    for existing in list_registered_secret_entries()? {
        entries.insert(existing.name.clone(), existing);
    }
    entries
        .entry(name.to_string())
        .or_insert_with(|| SecretRegistryEntry {
            name: name.to_string(),
            created_at_ms: Some(now_ms()),
        });
    write_secret_registry(entries)
}

pub fn unregister_secret_name(name: &str) -> Result<(), String> {
    validate_secret_name(name)?;
    let mut entries = HashMap::<String, SecretRegistryEntry>::new();
    for existing in list_registered_secret_entries()? {
        if existing.name != name {
            entries.insert(existing.name.clone(), existing);
        }
    }
    write_secret_registry(entries)
}

pub fn secret_usage_map(launchers: &[crate::launcher::Launcher]) -> HashMap<String, Vec<String>> {
    let mut usage = HashMap::<String, Vec<String>>::new();
    for launcher in launchers {
        for secret_ref in &launcher.secret_refs {
            let row = usage.entry(secret_ref.clone()).or_default();
            if !row.iter().any(|id| id == &launcher.id) {
                row.push(launcher.id.clone());
            }
        }
    }
    usage
}

pub fn test_secret(name: &str) -> Result<bool, String> {
    validate_secret_name(name)?;

    #[cfg(feature = "mac-keychain")]
    {
        use security_framework::passwords::get_generic_password;

        match get_generic_password(KEYCHAIN_SERVICE, name) {
            Ok(_) => Ok(true),
            Err(e) => {
                let msg = e.to_string();
                if is_keychain_not_found(&msg) {
                    Ok(false)
                } else if is_keychain_denied(&msg) {
                    Err("keychain_access_denied".to_string())
                } else {
                    Err(format!("keychain_write_failed:{}", msg))
                }
            }
        }
    }

    #[cfg(not(feature = "mac-keychain"))]
    {
        let _ = name;
        Err("keychain_backend_disabled".to_string())
    }
}

pub fn get_secret(name: &str) -> Result<String, String> {
    validate_secret_name(name)?;

    #[cfg(feature = "mac-keychain")]
    {
        use security_framework::passwords::get_generic_password;

        let bytes = get_generic_password(KEYCHAIN_SERVICE, name).map_err(|e| {
            let msg = e.to_string();
            if is_keychain_not_found(&msg) {
                "secret_not_found".to_string()
            } else if is_keychain_denied(&msg) {
                "keychain_access_denied".to_string()
            } else {
                format!("keychain_read_failed:{}", msg)
            }
        })?;

        String::from_utf8(bytes).map_err(|e| format!("secret_invalid_utf8:{}", e))
    }

    #[cfg(not(feature = "mac-keychain"))]
    {
        let _ = name;
        Err("keychain_backend_disabled".to_string())
    }
}

pub fn set_secret(name: &str, value: &str) -> Result<bool, String> {
    validate_secret_name(name)?;
    validate_secret_value(value)?;

    #[cfg(feature = "mac-keychain")]
    {
        use security_framework::passwords::{get_generic_password, set_generic_password};

        let existed = get_generic_password(KEYCHAIN_SERVICE, name).is_ok();
        set_generic_password(KEYCHAIN_SERVICE, name, value.as_bytes()).map_err(|e| {
            let msg = e.to_string();
            if is_keychain_denied(&msg) {
                "keychain_access_denied".to_string()
            } else {
                format!("keychain_write_failed:{}", msg)
            }
        })?;

        Ok(!existed)
    }

    #[cfg(not(feature = "mac-keychain"))]
    {
        let _ = (name, value);
        Err("keychain_backend_disabled".to_string())
    }
}

pub fn delete_secret(name: &str) -> Result<(), String> {
    validate_secret_name(name)?;

    #[cfg(feature = "mac-keychain")]
    {
        use security_framework::passwords::delete_generic_password;

        delete_generic_password(KEYCHAIN_SERVICE, name).map_err(|e| {
            let msg = e.to_string();
            if is_keychain_not_found(&msg) {
                "secret_not_found".to_string()
            } else if is_keychain_denied(&msg) {
                "keychain_access_denied".to_string()
            } else {
                format!("keychain_write_failed:{}", msg)
            }
        })
    }

    #[cfg(not(feature = "mac-keychain"))]
    {
        let _ = name;
        Err("keychain_backend_disabled".to_string())
    }
}

pub fn resolve_secrets(secret_refs: &[String]) -> Result<HashMap<String, String>, String> {
    if secret_refs.is_empty() {
        return Ok(HashMap::new());
    }

    #[cfg(feature = "mac-keychain")]
    {
        use security_framework::passwords::get_generic_password;

        let mut resolved = HashMap::new();
        for name in secret_refs {
            validate_secret_name(name)?;
            let bytes = get_generic_password(KEYCHAIN_SERVICE, name)
                .map_err(|e| format!("secret_not_found:{}:{}", name, e))?;
            let value = String::from_utf8(bytes)
                .map_err(|e| format!("secret_not_found:{}:invalid_utf8:{}", name, e))?;
            resolved.insert(name.clone(), value);
        }
        Ok(resolved)
    }

    #[cfg(not(feature = "mac-keychain"))]
    {
        let _ = secret_refs;
        Err("keychain_backend_disabled".to_string())
    }
}

fn is_keychain_not_found(msg: &str) -> bool {
    let lower = msg.to_ascii_lowercase();
    lower.contains("not found") || lower.contains("-25300") || lower.contains("itemnotfound")
}

fn secret_registry_path() -> Result<PathBuf, String> {
    let home = std::env::var("HOME").map_err(|e| format!("secret_registry_home_missing:{}", e))?;
    Ok(PathBuf::from(home).join(SECRET_REGISTRY_FILE))
}

fn write_secret_registry(entries: HashMap<String, SecretRegistryEntry>) -> Result<(), String> {
    let path = secret_registry_path()?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("secret_registry_dir_failed:{}", e))?;
    }
    let mut ordered = serde_json::Map::new();
    let mut keys: Vec<String> = entries.keys().cloned().collect();
    keys.sort();
    for key in keys {
        if let Some(entry) = entries.get(&key) {
            let mut meta = serde_json::Map::new();
            if let Some(created_at_ms) = entry.created_at_ms {
                meta.insert("created_at_ms".to_string(), serde_json::Value::from(created_at_ms));
            }
            ordered.insert(key.clone(), serde_json::Value::Object(meta));
        }
    }
    let raw = serde_json::to_vec_pretty(&serde_json::Value::Object(ordered))
        .map_err(|e| format!("secret_registry_encode_failed:{}", e))?;
    fs::write(&path, raw).map_err(|e| format!("secret_registry_write_failed:{}", e))
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn is_keychain_denied(msg: &str) -> bool {
    let lower = msg.to_ascii_lowercase();
    lower.contains("denied")
        || lower.contains("auth")
        || lower.contains("interaction not allowed")
        || lower.contains("-25293")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::launcher::{Launcher, TrustPolicy};

    fn launcher(id: &str, refs: &[&str]) -> Launcher {
        Launcher {
            id: id.to_string(),
            name: id.to_string(),
            description: String::new(),
            exec_path: "/bin/echo".to_string(),
            args: vec![],
            cwd: String::new(),
            secret_refs: refs.iter().map(|r| (*r).to_string()).collect(),
            trust_policy: TrustPolicy::Continuous,
            single_instance: true,
            enabled: true,
        }
    }

    #[test]
    fn test_collect_secret_refs() {
        let launchers = vec![
            launcher("a", &["S1", "S2", "S1"]),
            launcher("b", &["S2", "S3"]),
        ];

        let refs = collect_secret_refs(&launchers);
        assert_eq!(refs, vec!["S1", "S2", "S3"]);
    }

    #[test]
    fn test_secret_usage_map() {
        let launchers = vec![launcher("a", &["S1", "S2"]), launcher("b", &["S2"])];
        let usage = secret_usage_map(&launchers);

        assert_eq!(usage.get("S1").cloned().unwrap_or_default(), vec!["a"]);
        assert_eq!(usage.get("S2").cloned().unwrap_or_default(), vec!["a", "b"]);
    }

    #[test]
    fn test_validate_secret_name() {
        assert!(validate_secret_name("BINANCE_API_KEY").is_ok());
        assert!(validate_secret_name("ssh.passphrase-1").is_ok());
        assert_eq!(
            validate_secret_name("bad name").unwrap_err(),
            "invalid_secret_name"
        );
        assert_eq!(validate_secret_name("").unwrap_err(), "invalid_secret_name");
    }

    #[test]
    fn test_validate_secret_value() {
        assert!(validate_secret_value("x").is_ok());
        assert_eq!(validate_secret_value("").unwrap_err(), "value_too_large");
        let too_big = "a".repeat(8193);
        assert_eq!(
            validate_secret_value(&too_big).unwrap_err(),
            "value_too_large"
        );
    }

    #[test]
    fn test_non_keychain_returns_backend_disabled() {
        if cfg!(not(feature = "mac-keychain")) {
            assert_eq!(
                test_secret("BINANCE_API_KEY").unwrap_err(),
                "keychain_backend_disabled"
            );
            assert_eq!(
                get_secret("BINANCE_API_KEY").unwrap_err(),
                "keychain_backend_disabled"
            );
            assert_eq!(
                set_secret("BINANCE_API_KEY", "x").unwrap_err(),
                "keychain_backend_disabled"
            );
            assert_eq!(
                delete_secret("BINANCE_API_KEY").unwrap_err(),
                "keychain_backend_disabled"
            );
        }
    }

    #[test]
    #[ignore = "requires mac-keychain + user keychain access"]
    fn test_set_and_test_secret() {
        if cfg!(feature = "mac-keychain") {
            let name = "SYMBIAUTH_TEST_SECRET_SET";
            let _ = delete_secret(name);
            let created = set_secret(name, "value1").expect("set secret");
            assert!(created);
            let present = test_secret(name).expect("test secret");
            assert!(present);
            delete_secret(name).expect("cleanup");
        }
    }

    #[test]
    #[ignore = "requires mac-keychain + user keychain access"]
    fn test_delete_secret() {
        if cfg!(feature = "mac-keychain") {
            let name = "SYMBIAUTH_TEST_SECRET_DELETE";
            let _ = delete_secret(name);
            set_secret(name, "value1").expect("set secret");
            delete_secret(name).expect("delete");
            assert!(!test_secret(name).expect("test after delete"));
        }
    }

    #[test]
    #[ignore = "requires mac-keychain + user keychain access"]
    fn test_delete_nonexistent() {
        if cfg!(feature = "mac-keychain") {
            let name = "SYMBIAUTH_TEST_SECRET_MISSING";
            let _ = delete_secret(name);
            assert_eq!(delete_secret(name).unwrap_err(), "secret_not_found");
        }
    }
}
