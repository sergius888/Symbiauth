// Startup security checks
// Enforces strict file permissions before binding socket

use std::{fs, path::Path};
use thiserror::Error;

#[cfg(target_family = "unix")]
use std::os::unix::fs::{MetadataExt, PermissionsExt};

#[derive(Error, Debug)]
pub enum PermError {
    #[error("path missing: {0}")]
    Missing(String),

    #[error("bad mode for {path}: got {got:#o}, want {want:#o}\nFix: chmod {want:o} {path}")]
    Mode { path: String, got: u32, want: u32 },

    #[error("bad owner for {path}: uid {got}, want {want}")]
    Owner { path: String, got: u32, want: u32 },

    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

/// Assert path has specific ownership and permissions
/// Auto-fixes once if possible, then checks again
pub fn assert_secure(path: &Path, want_mode: u32) -> Result<(), PermError> {
    if !path.exists() {
        return Err(PermError::Missing(path.display().to_string()));
    }

    let meta = fs::metadata(path)?;

    // Check ownership (Unix only)
    #[cfg(target_family = "unix")]
    {
        let uid = meta.uid();
        let me = users::get_current_uid();
        if uid != me {
            return Err(PermError::Owner {
                path: path.display().to_string(),
                got: uid,
                want: me,
            });
        }
    }

    // Check mode (Unix only)
    #[cfg(target_family = "unix")]
    {
        let got = meta.permissions().mode() & 0o777;
        if got != want_mode {
            return Err(PermError::Mode {
                path: path.display().to_string(),
                got,
                want: want_mode,
            });
        }
    }

    Ok(())
}

/// Fix permissions on path (Unix only)
#[cfg(target_family = "unix")]
pub fn fix_perms(path: &Path, mode: u32) -> std::io::Result<()> {
    let mut perms = fs::metadata(path)?.permissions();
    perms.set_mode(mode);
    fs::set_permissions(path, perms)
}

#[cfg(not(target_family = "unix"))]
pub fn fix_perms(_path: &Path, _mode: u32) -> std::io::Result<()> {
    // No-op on non-Unix
    Ok(())
}

/// Check and optionally fix permissions (tries once)
pub fn ensure_secure(path: &Path, want_mode: u32) -> Result<(), PermError> {
    // First check
    if let Err(e) = assert_secure(path, want_mode) {
        // Try to auto-fix once
        let _ = fix_perms(path, want_mode);

        // Re-check
        assert_secure(path, want_mode).map_err(|_| e)?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    #[cfg(target_family = "unix")]
    fn test_secure_mode_ok() {
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("test");
        fs::write(&file, b"test").unwrap();

        // Set to 0600
        fix_perms(&file, 0o600).unwrap();

        // Should pass
        assert_secure(&file, 0o600).unwrap();
    }

    #[test]
    #[cfg(target_family = "unix")]
    fn test_insecure_mode_fails() {
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("test");
        fs::write(&file, b"test").unwrap();

        // Set to 0777 (insecure)
        fix_perms(&file, 0o777).unwrap();

        // Should fail
        let err = assert_secure(&file, 0o600).unwrap_err();
        assert!(matches!(err, PermError::Mode { .. }));
    }

    #[test]
    #[cfg(target_family = "unix")]
    fn test_ensure_secure_auto_fixes() {
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("test");
        fs::write(&file, b"test").unwrap();

        // Set to 0777 (insecure)
        fix_perms(&file, 0o777).unwrap();

        // ensure_secure should auto-fix
        ensure_secure(&file, 0o600).unwrap();

        // Verify it's now 0600
        let meta = fs::metadata(&file).unwrap();
        assert_eq!(meta.permissions().mode() & 0o777, 0o600);
    }

    #[test]
    fn test_missing_path() {
        let err = assert_secure(Path::new("/nonexistent/path"), 0o600).unwrap_err();
        assert!(matches!(err, PermError::Missing(_)));
    }
}
