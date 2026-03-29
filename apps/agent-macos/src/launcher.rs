use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::time::{sleep, Duration};
use uuid::Uuid;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
#[cfg(unix)]
use std::os::unix::process::CommandExt;

use nix::errno::Errno;
use nix::sys::signal;
use nix::sys::signal::Signal;
use nix::sys::wait::{waitpid, WaitPidFlag, WaitStatus};
use nix::unistd::{setsid, Pid};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrustPolicy {
    Continuous,
    StartOnly,
}

impl Default for TrustPolicy {
    fn default() -> Self {
        TrustPolicy::Continuous
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Launcher {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub exec_path: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    pub secret_refs: Vec<String>,
    #[serde(default)]
    pub trust_policy: TrustPolicy,
    #[serde(default = "default_true")]
    pub single_instance: bool,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LauncherConfig {
    #[serde(default)]
    pub launchers: Vec<Launcher>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LauncherTemplate {
    pub template_id: String,
    pub name: String,
    pub launcher: Launcher,
}

#[derive(Debug, Clone)]
pub struct ActiveRun {
    pub run_id: String,
    pub launcher_id: String,
    pub pid: u32,
    pub pgid: i32,
    #[allow(dead_code)] // Retained for future diagnostics/runtime timeline views.
    pub started_at: u64,
    pub trust_policy: TrustPolicy,
}

pub struct LauncherManager {
    config_path: String,
    launchers: Vec<Launcher>,
    active_runs: Vec<ActiveRun>,
    last_errors: HashMap<String, String>,
}

pub trait SecretResolver {
    fn resolve_secrets(&self, secret_refs: &[String]) -> Result<HashMap<String, String>, String>;
}

pub struct KeychainSecretResolver;

impl SecretResolver for KeychainSecretResolver {
    fn resolve_secrets(&self, secret_refs: &[String]) -> Result<HashMap<String, String>, String> {
        crate::secrets::resolve_secrets(secret_refs)
    }
}

impl LauncherManager {
    pub fn new(config_path: &str) -> Self {
        let mut manager = Self {
            config_path: config_path.to_string(),
            launchers: Vec::new(),
            active_runs: Vec::new(),
            last_errors: HashMap::new(),
        };

        if let Err(e) = manager.reload_config() {
            tracing::warn!(event = "launcher.config.load_failed", error = %e, path = %config_path);
        }

        manager
    }

    pub fn launcher_count(&self) -> usize {
        self.launchers.len()
    }

    pub fn launchers(&self) -> &[Launcher] {
        &self.launchers
    }

    #[allow(dead_code)] // Reserved for diagnostics API expansion.
    pub fn active_run_count(&self) -> usize {
        self.active_runs.len()
    }

    pub fn last_errors(&self) -> &HashMap<String, String> {
        &self.last_errors
    }

    pub fn reload_config(&mut self) -> Result<(), String> {
        let home = home_dir();
        let loaded = load_valid_launchers_from_path(Path::new(&self.config_path), &home)?;
        self.launchers = loaded;
        Ok(())
    }

    #[allow(dead_code)] // Reserved for diagnostics API expansion.
    pub fn active_runs(&self) -> &[ActiveRun] {
        &self.active_runs
    }

    pub fn upsert_launcher(&mut self, mut launcher: Launcher) -> Result<bool, String> {
        launcher.id = launcher.id.trim().to_string();
        launcher.name = launcher.name.trim().to_string();
        if launcher.id.is_empty() {
            return Err("id_empty".to_string());
        }
        if launcher.name.is_empty() {
            return Err("name_empty".to_string());
        }

        validate_exec_path(&launcher.exec_path)?;
        let home = home_dir();
        if !launcher.cwd.is_empty() {
            launcher.cwd = expand_home(&launcher.cwd, &home);
            validate_cwd(&launcher.cwd)?;
        }

        let mut updated = self.launchers.clone();
        let created = if let Some(idx) = updated.iter().position(|l| l.id == launcher.id) {
            updated[idx] = launcher;
            false
        } else {
            updated.push(launcher);
            true
        };

        ensure_unique_ids(&updated)?;
        write_launchers_config(Path::new(&self.config_path), &updated)?;
        self.launchers = updated;
        Ok(created)
    }

    pub fn delete_launcher(&mut self, launcher_id: &str) -> Result<(), String> {
        let mut updated = self.launchers.clone();
        let Some(idx) = updated.iter().position(|l| l.id == launcher_id) else {
            return Err("launcher_not_found".to_string());
        };
        updated.remove(idx);
        write_launchers_config(Path::new(&self.config_path), &updated)?;
        self.launchers = updated;
        self.last_errors.remove(launcher_id);
        Ok(())
    }

    pub fn is_running(&mut self, launcher_id: &str) -> bool {
        self.prune_inactive_runs();
        self.active_runs
            .iter()
            .any(|run| run.launcher_id == launcher_id)
    }

    #[allow(dead_code)] // Reserved for explicit run lifecycle operations in future slices.
    pub fn remove_run(&mut self, run_id: &str) -> Option<ActiveRun> {
        let idx = self
            .active_runs
            .iter()
            .position(|run| run.run_id == run_id)?;
        Some(self.active_runs.remove(idx))
    }

    pub fn run_launcher(
        &mut self,
        launcher_id: &str,
        resolver: &dyn SecretResolver,
    ) -> Result<ActiveRun, String> {
        let launcher = match self
            .launchers
            .iter()
            .find(|candidate| candidate.id == launcher_id)
            .cloned()
        {
            Some(found) => found,
            None => {
                return self.record_error_and_fail(launcher_id, "launcher_not_found".to_string())
            }
        };

        if !launcher.enabled {
            return self.record_error_and_fail(launcher_id, "launcher_disabled".to_string());
        }

        if launcher.single_instance && self.is_running(&launcher.id) {
            return self.record_error_and_fail(launcher_id, "already_running".to_string());
        }

        let env_vars = match resolver.resolve_secrets(&launcher.secret_refs) {
            Ok(resolved) => resolved,
            Err(e) => return self.record_error_and_fail(launcher_id, e),
        };

        let run = match spawn_launcher(&launcher, env_vars) {
            Ok(spawned) => spawned,
            Err(e) => return self.record_error_and_fail(launcher_id, e),
        };

        self.last_errors.remove(launcher_id);
        self.active_runs.push(run.clone());
        Ok(run)
    }

    fn record_error_and_fail<T>(&mut self, launcher_id: &str, error: String) -> Result<T, String> {
        self.last_errors
            .insert(launcher_id.to_string(), error.clone());
        Err(error)
    }

    fn prune_inactive_runs(&mut self) {
        self.active_runs.retain(is_run_alive);
    }

    pub async fn cleanup_on_revoke(
        &mut self,
        manual: bool,
        audit: &Option<Arc<crate::audit::AuditWriter>>,
        trust_id: Option<&str>,
        revoke_reason: &str,
    ) {
        self.prune_inactive_runs();

        let grace = if manual {
            Duration::from_millis(500)
        } else {
            Duration::from_secs(3)
        };

        let mut continuous_pgids = Vec::new();
        for run in &self.active_runs {
            if run.trust_policy == TrustPolicy::StartOnly {
                tracing::info!(
                    event = "launcher.cleanup.skip",
                    launcher_id = %run.launcher_id,
                    run_id = %run.run_id,
                    pid = run.pid,
                    reason = "trust_policy=start_only"
                );
                if let Some(writer) = audit {
                    writer
                        .log_launcher_event(
                            "launcher.cleanup.skip",
                            &run.launcher_id,
                            &run.run_id,
                            trust_id,
                            run.pid,
                            "ok",
                            Some("start_only"),
                        )
                        .await;
                }
                continue;
            }

            if send_group_signal(run.pgid, Signal::SIGTERM) {
                tracing::info!(
                    event = "launcher.cleanup.sigterm",
                    launcher_id = %run.launcher_id,
                    run_id = %run.run_id,
                    pid = run.pid,
                    pgid = run.pgid,
                    manual = manual
                );
            } else {
                tracing::warn!(
                    event = "launcher.cleanup.sigterm_failed",
                    launcher_id = %run.launcher_id,
                    run_id = %run.run_id,
                    pid = run.pid,
                    pgid = run.pgid
                );
            }
            if let Some(writer) = audit {
                writer
                    .log_launcher_event(
                        "launcher.cleanup.kill",
                        &run.launcher_id,
                        &run.run_id,
                        trust_id,
                        run.pid,
                        "ok",
                        Some(revoke_reason),
                    )
                    .await;
            }

            continuous_pgids.push(run.pgid);
        }

        if !continuous_pgids.is_empty() {
            sleep(grace).await;
            for pgid in continuous_pgids {
                if is_process_group_alive(pgid) {
                    let _ = send_group_signal(pgid, Signal::SIGKILL);
                }
            }
        }

        self.active_runs
            .retain(|run| run.trust_policy == TrustPolicy::StartOnly);
        self.prune_inactive_runs();
    }
}

fn spawn_launcher(
    launcher: &Launcher,
    env_vars: HashMap<String, String>,
) -> Result<ActiveRun, String> {
    let mut cmd = Command::new(&launcher.exec_path);
    cmd.args(&launcher.args);

    if !launcher.cwd.is_empty() {
        cmd.current_dir(&launcher.cwd);
    }

    for (k, v) in &env_vars {
        cmd.env(k, v);
    }

    #[cfg(unix)]
    unsafe {
        cmd.pre_exec(|| {
            setsid().map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?;
            Ok(())
        });
    }

    let child = cmd.spawn().map_err(|e| format!("spawn_failed: {}", e))?;
    let pid = child.id();
    let pgid = pid as i32;

    Ok(ActiveRun {
        run_id: generate_run_id(),
        launcher_id: launcher.id.clone(),
        pid,
        pgid,
        started_at: now_epoch_ms(),
        trust_policy: launcher.trust_policy,
    })
}

fn is_run_alive(run: &ActiveRun) -> bool {
    let pid = Pid::from_raw(run.pid as i32);

    match waitpid(pid, Some(WaitPidFlag::WNOHANG)) {
        Ok(WaitStatus::StillAlive) => {}
        Ok(_) => return false,
        Err(Errno::ECHILD) => {}
        Err(_) => {}
    }

    match signal::kill(pid, None) {
        Ok(_) => true,
        Err(Errno::ESRCH) => false,
        Err(_) => true,
    }
}

fn is_process_group_alive(pgid: i32) -> bool {
    let target = Pid::from_raw(-pgid);
    match signal::kill(target, None) {
        Ok(_) => true,
        Err(Errno::ESRCH) => false,
        Err(_) => true,
    }
}

fn send_group_signal(pgid: i32, sig: Signal) -> bool {
    let target = Pid::from_raw(-pgid);
    match signal::kill(target, Some(sig)) {
        Ok(_) => true,
        Err(Errno::ESRCH) => true,
        Err(_) => false,
    }
}

fn generate_run_id() -> String {
    format!("r_{}", Uuid::new_v4().simple())
}

fn now_epoch_ms() -> u64 {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_millis() as u64,
        Err(_) => 0,
    }
}

fn home_dir() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/"))
}

fn load_valid_launchers_from_path(path: &Path, home: &Path) -> Result<Vec<Launcher>, String> {
    let contents = match fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            tracing::info!(event = "launcher.config.missing", path = %path.display());
            return Ok(Vec::new());
        }
        Err(e) => {
            return Err(format!("failed_to_read_config:{}", e));
        }
    };

    load_valid_launchers_from_yaml(&contents, home)
}

fn load_valid_launchers_from_yaml(yaml: &str, home: &Path) -> Result<Vec<Launcher>, String> {
    if yaml.trim().is_empty() {
        return Ok(Vec::new());
    }

    let root: serde_yaml::Value =
        serde_yaml::from_str(yaml).map_err(|e| format!("invalid_yaml:{}", e))?;

    let launchers_node = root
        .get("launchers")
        .cloned()
        .unwrap_or(serde_yaml::Value::Sequence(vec![]));

    let values: Vec<serde_yaml::Value> = serde_yaml::from_value(launchers_node)
        .map_err(|e| format!("invalid_launchers_array:{}", e))?;

    let mut valid = Vec::new();
    let mut seen_ids = HashSet::new();

    for value in values {
        match serde_yaml::from_value::<Launcher>(value) {
            Ok(mut launcher) => {
                if let Err(e) = validate_launcher(&mut launcher, &mut seen_ids, home) {
                    tracing::warn!(event = "launcher.config.invalid_entry", launcher_id = %launcher.id, error = %e);
                    continue;
                }
                valid.push(launcher);
            }
            Err(e) => {
                tracing::warn!(event = "launcher.config.invalid_entry", error = %e);
            }
        }
    }

    Ok(valid)
}

fn ensure_unique_ids(launchers: &[Launcher]) -> Result<(), String> {
    let mut seen = HashSet::new();
    for launcher in launchers {
        if !seen.insert(launcher.id.clone()) {
            return Err("id_duplicate".to_string());
        }
    }
    Ok(())
}

fn validate_launcher(
    launcher: &mut Launcher,
    seen_ids: &mut HashSet<String>,
    home: &Path,
) -> Result<(), String> {
    launcher.id = launcher.id.trim().to_string();
    if launcher.id.is_empty() {
        return Err("id_empty".to_string());
    }
    if !seen_ids.insert(launcher.id.clone()) {
        return Err("id_duplicate".to_string());
    }

    validate_exec_path(&launcher.exec_path)?;

    if !launcher.cwd.is_empty() {
        launcher.cwd = expand_home(&launcher.cwd, home);
        validate_cwd(&launcher.cwd)?;
    }

    Ok(())
}

fn write_launchers_config(path: &Path, launchers: &[Launcher]) -> Result<(), String> {
    let cfg = LauncherConfig {
        launchers: launchers.to_vec(),
    };
    let yaml =
        serde_yaml::to_string(&cfg).map_err(|e| format!("config_serialize_failed:{}", e))?;
    atomic_write(path, yaml.as_bytes()).map_err(|e| format!("config_write_failed:{}", e))
}

fn atomic_write(path: &Path, data: &[u8]) -> Result<(), std::io::Error> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let tmp_name = format!(
        ".{}.tmp.{}",
        path.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("launchers.yaml"),
        Uuid::new_v4().simple()
    );
    let tmp_path = path.with_file_name(tmp_name);

    {
        let mut f = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&tmp_path)?;
        f.write_all(data)?;
        f.sync_all()?;
    }

    fs::rename(&tmp_path, path)?;

    #[cfg(unix)]
    if let Some(parent) = path.parent() {
        let dir = fs::File::open(parent)?;
        dir.sync_all()?;
    }

    Ok(())
}

fn validate_exec_path(exec_path: &str) -> Result<(), String> {
    let path = Path::new(exec_path);
    if !path.is_absolute() {
        return Err("exec_path_not_absolute".to_string());
    }

    let meta = fs::metadata(path).map_err(|_| "exec_path_missing".to_string())?;
    if !meta.is_file() {
        return Err("exec_path_not_file".to_string());
    }

    #[cfg(unix)]
    {
        let mode = meta.permissions().mode();
        if (mode & 0o002) != 0 {
            return Err("exec_path_world_writable".to_string());
        }
    }

    Ok(())
}

fn validate_cwd(cwd: &str) -> Result<(), String> {
    let path = Path::new(cwd);
    if !path.is_absolute() {
        return Err("cwd_not_absolute".to_string());
    }

    let meta = fs::metadata(path).map_err(|_| "cwd_missing".to_string())?;
    if !meta.is_dir() {
        return Err("cwd_not_directory".to_string());
    }

    Ok(())
}

fn expand_home(raw: &str, home: &Path) -> String {
    if raw == "~" {
        let expanded = home.display().to_string();
        tracing::info!(event = "launcher.config.cwd_expanded", from = raw, to = %expanded);
        return expanded;
    }

    if let Some(suffix) = raw.strip_prefix("~/") {
        let expanded = home.join(suffix).display().to_string();
        tracing::info!(event = "launcher.config.cwd_expanded", from = raw, to = %expanded);
        return expanded;
    }

    raw.to_string()
}

pub fn built_in_templates() -> Vec<LauncherTemplate> {
    vec![
        LauncherTemplate {
            template_id: "local-port-forward".to_string(),
            name: "Local Port Forward".to_string(),
            launcher: Launcher {
                id: "local-port-forward".to_string(),
                name: "Local Port Forward".to_string(),
                description: "Open a non-interactive SSH local tunnel that terminates when trust ends.".to_string(),
                exec_path: "/bin/zsh".to_string(),
                args: vec![
                    "-lc".to_string(),
                    "exec /usr/bin/ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -N -L 15432:db.internal:5432 bastion-user@bastion-host".to_string(),
                ],
                cwd: home_dir().display().to_string(),
                secret_refs: vec![],
                trust_policy: TrustPolicy::Continuous,
                single_instance: true,
                enabled: true,
            },
        },
        LauncherTemplate {
            template_id: "kubectl-port-forward".to_string(),
            name: "Kubernetes Port Forward".to_string(),
            launcher: Launcher {
                id: "kubectl-port-forward".to_string(),
                name: "Kubernetes Port Forward".to_string(),
                description: "Forward a Kubernetes service locally while trust remains active.".to_string(),
                exec_path: "/bin/zsh".to_string(),
                args: vec![
                    "-lc".to_string(),
                    "KUBECONFIG=\"$KUBECONFIG_PATH\" exec /usr/bin/kubectl port-forward svc/myapp 8080:80 -n prod".to_string(),
                ],
                cwd: home_dir().display().to_string(),
                secret_refs: vec!["KUBECONFIG_PATH".to_string()],
                trust_policy: TrustPolicy::Continuous,
                single_instance: true,
                enabled: true,
            },
        },
        LauncherTemplate {
            template_id: "generic-long-running-script".to_string(),
            name: "Generic Long-Running Script".to_string(),
            launcher: Launcher {
                id: "generic-long-running-script".to_string(),
                name: "Generic Long-Running Script".to_string(),
                description: "Run a harmless long-running command to validate trust-gated process control.".to_string(),
                exec_path: "/bin/zsh".to_string(),
                args: vec![
                    "-lc".to_string(),
                    "sleep 120".to_string(),
                ],
                cwd: home_dir().display().to_string(),
                secret_refs: vec![],
                trust_policy: TrustPolicy::Continuous,
                single_instance: true,
                enabled: true,
            },
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use nix::sys::signal::Signal;
    use std::io::Write;
    use tempfile::tempdir;

    struct StaticSecretResolver {
        secrets: HashMap<String, String>,
    }

    impl SecretResolver for StaticSecretResolver {
        fn resolve_secrets(
            &self,
            secret_refs: &[String],
        ) -> Result<HashMap<String, String>, String> {
            let mut resolved = HashMap::new();
            for key in secret_refs {
                match self.secrets.get(key) {
                    Some(value) => {
                        resolved.insert(key.clone(), value.clone());
                    }
                    None => return Err(format!("secret_not_found:{}", key)),
                }
            }
            Ok(resolved)
        }
    }

    fn write_exec(path: &Path) {
        let mut f = std::fs::File::create(path).unwrap();
        writeln!(f, "#!/bin/sh").unwrap();
        writeln!(f, "echo ok").unwrap();
        #[cfg(unix)]
        {
            let mut perms = std::fs::metadata(path).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(path, perms).unwrap();
        }
    }

    fn write_config(path: &Path, content: &str) {
        std::fs::write(path, content).unwrap();
    }

    #[test]
    fn test_load_valid_config() {
        let td = tempdir().unwrap();
        let exec = td.path().join("run.sh");
        let cwd = td.path().join("cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        write_exec(&exec);

        let yaml = format!(
            r#"
launchers:
  - id: "bot-freqtrade"
    name: "Run Freqtrade"
    description: "Starts the live trading bot"
    exec_path: "{}"
    args: ["-lc", "./run.sh"]
    cwd: "{}"
    secret_refs: ["BINANCE_API_KEY", "BINANCE_API_SECRET"]
    trust_policy: "start_only"
    single_instance: true
    enabled: true
"#,
            exec.display(),
            cwd.display()
        );

        let launchers = load_valid_launchers_from_yaml(&yaml, td.path()).unwrap();
        assert_eq!(launchers.len(), 1);
        let l = &launchers[0];
        assert_eq!(l.id, "bot-freqtrade");
        assert_eq!(l.name, "Run Freqtrade");
        assert_eq!(l.description, "Starts the live trading bot");
        assert_eq!(l.trust_policy, TrustPolicy::StartOnly);
        assert!(l.single_instance);
        assert!(l.enabled);
        assert_eq!(l.secret_refs.len(), 2);
    }

    #[test]
    fn test_load_empty_config() {
        let launchers = load_valid_launchers_from_yaml("", Path::new("/tmp")).unwrap();
        assert!(launchers.is_empty());
    }

    #[test]
    fn test_load_invalid_config() {
        let err = load_valid_launchers_from_yaml("launchers: [", Path::new("/tmp")).unwrap_err();
        assert!(err.starts_with("invalid_yaml:"));
    }

    #[test]
    fn test_tilde_expansion() {
        let td = tempdir().unwrap();
        let exec = td.path().join("run.sh");
        let home = td.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        write_exec(&exec);

        let yaml = format!(
            r#"
launchers:
  - id: "test"
    name: "Test"
    exec_path: "{}"
    cwd: "~"
"#,
            exec.display()
        );

        let launchers = load_valid_launchers_from_yaml(&yaml, &home).unwrap();
        assert_eq!(launchers.len(), 1);
        assert_eq!(launchers[0].cwd, home.display().to_string());
    }

    #[test]
    fn test_config_validation() {
        let td = tempdir().unwrap();
        let good_exec = td.path().join("good.sh");
        let cwd = td.path().join("cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        write_exec(&good_exec);

        let yaml = format!(
            r#"
launchers:
  - id: "bad-relative"
    name: "Bad Relative"
    exec_path: "run.sh"
    cwd: "{}"
  - id: "bad-missing"
    name: "Bad Missing"
    exec_path: "/definitely/missing"
    cwd: "{}"
  - id: "good"
    name: "Good"
    exec_path: "{}"
    cwd: "{}"
"#,
            cwd.display(),
            cwd.display(),
            good_exec.display(),
            cwd.display()
        );

        let launchers = load_valid_launchers_from_yaml(&yaml, td.path()).unwrap();
        assert_eq!(launchers.len(), 1);
        assert_eq!(launchers[0].id, "good");
    }

    #[test]
    fn test_single_instance_prevents_double_run() {
        let td = tempdir().unwrap();
        let cwd = td.path().join("cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        let config_path = td.path().join("launchers.yaml");
        let yaml = format!(
            r#"
launchers:
  - id: "single-runner"
    name: "Single Runner"
    exec_path: "/bin/zsh"
    args: ["-lc", "sleep 30"]
    cwd: "{}"
    secret_refs: ["TEST_SECRET"]
    single_instance: true
    enabled: true
"#,
            cwd.display()
        );
        write_config(&config_path, &yaml);

        let mut manager = LauncherManager::new(config_path.to_str().unwrap());
        assert_eq!(manager.launcher_count(), 1);

        let mut secrets = HashMap::new();
        secrets.insert("TEST_SECRET".to_string(), "s3cr3t".to_string());
        let resolver = StaticSecretResolver { secrets };

        let first = manager.run_launcher("single-runner", &resolver).unwrap();
        assert!(first.pid > 0);
        assert!(manager.is_running("single-runner"));

        let second = manager
            .run_launcher("single-runner", &resolver)
            .unwrap_err();
        assert_eq!(second, "already_running");

        let pgid = Pid::from_raw(-first.pgid);
        let _ = signal::kill(pgid, Some(Signal::SIGKILL));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn test_cleanup_kills_continuous() {
        let td = tempdir().unwrap();
        let cwd = td.path().join("cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        let config_path = td.path().join("launchers.yaml");
        let yaml = format!(
            r#"
launchers:
  - id: "continuous-runner"
    name: "Continuous Runner"
    exec_path: "/bin/zsh"
    args: ["-lc", "sleep 60"]
    cwd: "{}"
    trust_policy: "continuous"
    single_instance: true
    enabled: true
"#,
            cwd.display()
        );
        write_config(&config_path, &yaml);

        let mut manager = LauncherManager::new(config_path.to_str().unwrap());
        let resolver = StaticSecretResolver {
            secrets: HashMap::new(),
        };
        let run = manager
            .run_launcher("continuous-runner", &resolver)
            .unwrap();
        assert!(is_run_alive(&run));

        manager
            .cleanup_on_revoke(false, &None, None, "revoke")
            .await;
        assert!(!is_run_alive(&run));
        assert_eq!(manager.active_run_count(), 0);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn test_cleanup_skips_start_only() {
        let td = tempdir().unwrap();
        let cwd = td.path().join("cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        let config_path = td.path().join("launchers.yaml");
        let yaml = format!(
            r#"
launchers:
  - id: "start-only-runner"
    name: "Start Only Runner"
    exec_path: "/bin/zsh"
    args: ["-lc", "sleep 60"]
    cwd: "{}"
    trust_policy: "start_only"
    single_instance: true
    enabled: true
"#,
            cwd.display()
        );
        write_config(&config_path, &yaml);

        let mut manager = LauncherManager::new(config_path.to_str().unwrap());
        let resolver = StaticSecretResolver {
            secrets: HashMap::new(),
        };
        let run = manager
            .run_launcher("start-only-runner", &resolver)
            .unwrap();
        assert!(is_run_alive(&run));

        manager
            .cleanup_on_revoke(false, &None, None, "revoke")
            .await;
        assert!(is_run_alive(&run));
        assert_eq!(manager.active_run_count(), 1);

        let pgid = Pid::from_raw(-run.pgid);
        let _ = signal::kill(pgid, Some(Signal::SIGKILL));
    }

    #[test]
    fn test_trust_policy_defaults_to_continuous() {
        let td = tempdir().unwrap();
        let exec = td.path().join("run.sh");
        let cwd = td.path().join("cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        write_exec(&exec);

        let yaml = format!(
            r#"
launchers:
  - id: "default-policy"
    name: "Default Policy"
    exec_path: "{}"
    cwd: "{}"
"#,
            exec.display(),
            cwd.display()
        );

        let launchers = load_valid_launchers_from_yaml(&yaml, td.path()).unwrap();
        assert_eq!(launchers.len(), 1);
        assert_eq!(launchers[0].trust_policy, TrustPolicy::Continuous);
        assert!(launchers[0].single_instance);
        assert!(launchers[0].enabled);
    }

    #[test]
    fn test_upsert_creates_and_persists() {
        let td = tempdir().unwrap();
        let exec = td.path().join("run.sh");
        let cwd = td.path().join("cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        write_exec(&exec);

        let config_path = td.path().join("launchers.yaml");
        let mut manager = LauncherManager::new(config_path.to_str().unwrap());

        let launcher = Launcher {
            id: "new-launcher".to_string(),
            name: "New Launcher".to_string(),
            description: "test".to_string(),
            exec_path: exec.display().to_string(),
            args: vec!["-lc".to_string(), "echo hi".to_string()],
            cwd: cwd.display().to_string(),
            secret_refs: vec!["API_KEY".to_string()],
            trust_policy: TrustPolicy::Continuous,
            single_instance: true,
            enabled: true,
        };

        let created = manager.upsert_launcher(launcher).unwrap();
        assert!(created);
        assert_eq!(manager.launcher_count(), 1);

        let persisted = load_valid_launchers_from_path(&config_path, td.path()).unwrap();
        assert_eq!(persisted.len(), 1);
        assert_eq!(persisted[0].id, "new-launcher");
    }

    #[test]
    fn test_delete_launcher_errors_for_missing_id() {
        let td = tempdir().unwrap();
        let config_path = td.path().join("launchers.yaml");
        let mut manager = LauncherManager::new(config_path.to_str().unwrap());
        let err = manager.delete_launcher("missing").unwrap_err();
        assert_eq!(err, "launcher_not_found");
    }

    #[test]
    fn test_builtin_templates_exist() {
        let templates = built_in_templates();
        assert!(templates.len() >= 3);
        assert!(templates.iter().any(|t| t.template_id == "local-port-forward"));
    }
}
