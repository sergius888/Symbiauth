// CLI commands for TLS certificate rotation, audit, TOTP, and chamber access.
// Run with: agent-cli <command>

use agent_macos::{rotation_controller::RotationController, tls_config::TlsConfig, totp};
use anyhow::{anyhow, bail, Context, Result};
use clap::{Args, Parser, Subcommand};
use serde_json::{json, Value};
use std::env;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::{self, Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Parser)]
#[command(name = "agent-cli")]
#[command(about = "Armadillo macOS Agent - CLI access to trust and chamber features")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// TLS certificate rotation commands
    Tls {
        #[command(subcommand)]
        cmd: TlsCommands,
    },

    /// Audit log commands
    Audit {
        #[command(subcommand)]
        cmd: AuditCommands,
    },

    /// TOTP (Time-based One-Time Password) commands for remote approvals
    Totp {
        #[command(subcommand)]
        cmd: TotpCommands,
    },

    /// Chamber access from a normal terminal
    Chamber {
        #[command(subcommand)]
        cmd: ChamberCommands,
    },
}

#[derive(Subcommand)]
enum ChamberCommands {
    /// Show current trust state
    Status {
        /// Output as JSON
        #[arg(long)]
        json: bool,
    },

    /// List available secrets
    List {
        /// Output as JSON
        #[arg(long)]
        json: bool,
    },

    /// Get a secret value from the chamber
    Get {
        /// Secret name / env key
        name: String,

        /// Output as JSON
        #[arg(long)]
        json: bool,
    },

    /// Run a command with trust-gated chamber secrets injected as env vars
    Run(ChamberRunArgs),
}

#[derive(Args)]
struct ChamberRunArgs {
    /// Secret names to inject as env vars
    #[arg(long = "env", required = true)]
    env_names: Vec<String>,

    /// Working directory for the launched command
    #[arg(long)]
    cwd: Option<String>,

    /// Wait for trust to become active before fetching secrets
    #[arg(long)]
    wait: bool,

    /// Maximum seconds to wait when --wait is used
    #[arg(long, default_value_t = 30)]
    wait_timeout_secs: u64,

    /// Command to run after `--`
    #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
    command: Vec<String>,
}

#[derive(Subcommand)]
enum AuditCommands {
    /// Verify audit log hash chain integrity
    Verify {
        /// Path to audit log file (default: ~/.armadillo/audit/audit.current.ndjson)
        #[arg(long)]
        file: Option<String>,

        /// Output as JSON
        #[arg(long)]
        json: bool,
    },
}

#[derive(Subcommand)]
enum TotpCommands {
    /// Enroll a new TOTP secret and display QR code
    Enroll {
        /// Custom label for the TOTP (default: "Armadillo on <hostname>")
        #[arg(long)]
        label: Option<String>,
    },

    /// Show TOTP enrollment status
    Status,

    /// Revoke TOTP secret (disables remote approvals)
    Revoke {
        /// Force revocation without confirmation
        #[arg(long)]
        force: bool,
    },

    /// Show otpauth:// URI for enrolled TOTP
    ShowUri {
        /// Custom label for the TOTP (default: "Armadillo on <hostname>")
        #[arg(long)]
        label: Option<String>,
    },
}

#[derive(Subcommand)]
enum TlsCommands {
    /// Stage new certificate for rotation (dual-pin)
    Rotate {
        /// Path to new certificate PEM file
        #[arg(long)]
        cert: String,

        /// Emergency mode: promote immediately without dual-pin window
        #[arg(long)]
        no_overlap: bool,

        /// Force emergency rotation (required with --no-overlap)
        #[arg(long)]
        force: bool,
    },

    /// Promote staged certificate to current
    Promote,

    /// Cancel staged rotation
    Cancel,

    /// Show rotation status
    Status {
        /// Output as JSON
        #[arg(long)]
        json: bool,
    },
}

fn main() {
    let cli = Cli::parse();

    let result = match cli.command {
        Commands::Tls { cmd } => match cmd {
            TlsCommands::Rotate {
                cert,
                no_overlap,
                force,
            } => rotate_cmd(&cert, no_overlap, force),
            TlsCommands::Promote => promote_cmd(),
            TlsCommands::Cancel => cancel_cmd(),
            TlsCommands::Status { json } => status_cmd(json),
        },
        Commands::Audit { cmd } => match cmd {
            AuditCommands::Verify { file, json } => verify_cmd(file.as_deref(), json),
        },
        Commands::Totp { cmd } => match cmd {
            TotpCommands::Enroll { label } => totp_enroll_cmd(label),
            TotpCommands::Status => totp_status_cmd(),
            TotpCommands::Revoke { force } => totp_revoke_cmd(force),
            TotpCommands::ShowUri { label } => totp_show_uri_cmd(label),
        },
        Commands::Chamber { cmd } => match cmd {
            ChamberCommands::Status { json } => chamber_status_cmd(json),
            ChamberCommands::List { json } => chamber_list_cmd(json),
            ChamberCommands::Get { name, json } => chamber_get_cmd(&name, json),
            ChamberCommands::Run(args) => chamber_run_cmd(args),
        },
    };

    if let Err(e) = result {
        eprintln!("Error: {}", e);
        process::exit(1);
    }
}

fn chamber_status_cmd(as_json: bool) -> Result<()> {
    let resp = send_uds_request(&json!({
        "type": "trust.status",
        "corr_id": corr_id(),
    }))?;
    ensure_ok_response(&resp)?;

    if as_json {
        println!("{}", serde_json::to_string_pretty(&resp)?);
        return Ok(());
    }

    let state = resp.get("state").and_then(Value::as_str).unwrap_or("unknown");
    let mode = resp.get("mode").and_then(Value::as_str).unwrap_or("unknown");
    let signal = resp.get("signal").and_then(Value::as_str).unwrap_or("unknown");
    let trust_id = resp
        .get("trust_id")
        .and_then(Value::as_str)
        .unwrap_or("-");

    println!("state: {}", state);
    println!("mode: {}", mode);
    println!("signal: {}", signal);
    println!("trust_id: {}", trust_id);

    if let Some(deadline_ms) = resp.get("deadline_ms").and_then(Value::as_u64) {
        let now_ms = now_ms();
        if deadline_ms > now_ms {
            println!("deadline_in: {}s", (deadline_ms - now_ms) / 1000);
        }
    }

    if let Some(until_ms) = resp.get("trust_until_ms").and_then(Value::as_u64) {
        let now_ms = now_ms();
        if until_ms > now_ms {
            println!("trust_for: {}s", (until_ms - now_ms) / 1000);
        }
    }

    Ok(())
}

fn chamber_list_cmd(as_json: bool) -> Result<()> {
    let resp = send_uds_request(&json!({
        "type": "secret.list",
        "corr_id": corr_id(),
    }))?;
    ensure_ok_response(&resp)?;

    if as_json {
        println!("{}", serde_json::to_string_pretty(&resp)?);
        return Ok(());
    }

    let secrets = resp
        .get("secrets")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("missing secrets array"))?;

    for secret in secrets {
        let name = secret.get("name").and_then(Value::as_str).unwrap_or("<unknown>");
        let available = if secret.get("available").and_then(Value::as_bool).unwrap_or(false) {
            "available"
        } else {
            "missing"
        };
        let used_by_count = secret
            .get("used_by")
            .and_then(Value::as_array)
            .map(|rows| rows.len())
            .unwrap_or(0);
        println!("{} [{}] used_by={}", name, available, used_by_count);
    }

    Ok(())
}

fn chamber_get_cmd(name: &str, as_json: bool) -> Result<()> {
    let resp = send_uds_request(&json!({
        "type": "secret.get",
        "corr_id": corr_id(),
        "name": name,
    }))?;

    if as_json {
        println!("{}", serde_json::to_string_pretty(&resp)?);
        return Ok(());
    }

    ensure_ok_response(&resp)?;
    let value = resp
        .get("value")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("secret response missing value"))?;
    print!("{}", value);
    Ok(())
}

fn chamber_run_cmd(args: ChamberRunArgs) -> Result<()> {
    if args.command.is_empty() {
        bail!("missing command after `--`");
    }

    wait_for_trust_if_needed(args.wait, args.wait_timeout_secs)?;

    let mut injected = Vec::with_capacity(args.env_names.len());
    for env_name in &args.env_names {
        let resp = send_uds_request(&json!({
            "type": "secret.get",
            "corr_id": corr_id(),
            "name": env_name,
        }))?;
        ensure_ok_response(&resp)?;
        let value = resp
            .get("value")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("secret `{}` response missing value", env_name))?;
        injected.push((env_name.clone(), value.to_string()));
    }

    eprintln!(
        ":: chamber run injecting {} env var(s): {}",
        injected.len(),
        injected
            .iter()
            .map(|(name, _)| name.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    );

    let program = &args.command[0];
    let mut command = Command::new(program);
    if args.command.len() > 1 {
        command.args(&args.command[1..]);
    }
    if let Some(cwd) = args.cwd.as_deref() {
        command.current_dir(cwd);
    }
    command.stdin(Stdio::inherit());
    command.stdout(Stdio::inherit());
    command.stderr(Stdio::inherit());
    for (name, value) in &injected {
        command.env(name, value);
    }

    let status = command
        .status()
        .with_context(|| format!("failed to launch `{}`", program))?;
    match status.code() {
        Some(code) => process::exit(code),
        None => bail!("command terminated by signal"),
    }
}

fn wait_for_trust_if_needed(wait: bool, timeout_secs: u64) -> Result<()> {
    let start = std::time::Instant::now();
    loop {
        let resp = send_uds_request(&json!({
            "type": "trust.status",
            "corr_id": corr_id(),
        }))?;
        ensure_ok_response(&resp)?;
        let state = resp.get("state").and_then(Value::as_str).unwrap_or("");
        if state.eq_ignore_ascii_case("trusted") {
            return Ok(());
        }
        if !wait {
            bail!("trust is not active");
        }
        if start.elapsed() >= Duration::from_secs(timeout_secs) {
            bail!("timed out waiting for trust to become active");
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

fn send_uds_request(message: &Value) -> Result<Value> {
    let mut stream = UnixStream::connect(default_socket_path())
        .with_context(|| format!("failed to connect to {}", default_socket_path()))?;
    write_frame(&mut stream, message)?;
    read_frame(&mut stream)
}

fn write_frame(stream: &mut UnixStream, message: &Value) -> Result<()> {
    let body = serde_json::to_vec(message)?;
    let len = (body.len() as u32).to_be_bytes();
    stream.write_all(&len)?;
    stream.write_all(&body)?;
    stream.flush()?;
    Ok(())
}

fn read_frame(stream: &mut UnixStream) -> Result<Value> {
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf)?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len == 0 || len > 65536 {
        bail!("invalid response frame size {}", len);
    }
    let mut body = vec![0u8; len];
    stream.read_exact(&mut body)?;
    Ok(serde_json::from_slice(&body)?)
}

fn ensure_ok_response(resp: &Value) -> Result<()> {
    if resp
        .get("ok")
        .and_then(Value::as_bool)
        .unwrap_or(resp.get("type").and_then(Value::as_str) != Some("error"))
    {
        return Ok(());
    }
    let message = resp
        .get("error")
        .and_then(Value::as_str)
        .or_else(|| resp.get("message").and_then(Value::as_str))
        .unwrap_or("request failed");
    bail!("{}", message);
}

fn default_socket_path() -> String {
    env::var("ARMADILLO_SOCKET_PATH").unwrap_or_else(|_| {
        let home = env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        format!("{}/.armadillo/a.sock", home)
    })
}

fn corr_id() -> String {
    format!("cli-{:x}", now_ms())
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn rotate_cmd(cert_path: &str, no_overlap: bool, force: bool) -> Result<()> {
    if no_overlap && !force {
        anyhow::bail!(
            "Emergency rotation (--no-overlap) requires --force flag.\n\
            WARNING: This will break existing paired devices until they re-pair!"
        );
    }

    if no_overlap {
        eprintln!("WARNING: Emergency rotation mode");
        eprintln!("WARNING: This will immediately activate the new certificate.");
        eprintln!("WARNING: All paired devices must re-scan QR code to reconnect.");
        eprintln!();
    }

    let cert_path_buf = std::path::Path::new(cert_path);
    if !cert_path_buf.exists() {
        anyhow::bail!("Certificate file not found: {}", cert_path);
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let metadata =
            std::fs::metadata(cert_path_buf).context("Failed to read certificate file metadata")?;
        let mode = metadata.permissions().mode();
        let perms = mode & 0o777;

        if perms != 0o600 && perms != 0o400 {
            eprintln!(
                "WARNING: Certificate file has loose permissions: {:o}",
                perms
            );
            eprintln!("Recommended: chmod 600 {}", cert_path);
        }
    }

    let cert_data = std::fs::read(cert_path_buf).context("Failed to read certificate file")?;

    validate_certificate(&cert_data)?;

    let config_path = TlsConfig::default_path();
    let controller = RotationController::new(&config_path);

    controller
        .stage(cert_path)
        .map_err(|e| anyhow::anyhow!("Failed to stage rotation: {}", e))?;

    println!("Certificate staged successfully");

    if no_overlap {
        println!("Promoting immediately (emergency mode)...");
        controller
            .promote()
            .map_err(|e| anyhow::anyhow!("Failed to promote: {}", e))?;

        println!("Emergency rotation complete");
        println!("Restart TLS server to apply new certificate");
        println!("All devices must re-pair with new QR code");
    } else if let Ok(status) = controller.status() {
        println!();
        println!("Rotation Status:");
        println!("  Current FP: {}", status.fp_current);
        if let Some(next) = status.fp_next {
            println!("  Next FP:    {}", next);
        }
        if let Some(days) = status.days_remaining {
            println!("  Days remaining: {}", days);
            println!();
            println!("Run 'agent-cli tls promote' to complete rotation");
        }
    }

    Ok(())
}

fn promote_cmd() -> Result<()> {
    let config_path = TlsConfig::default_path();
    let controller = RotationController::new(&config_path);

    let status = controller
        .status()
        .map_err(|e| anyhow::anyhow!("Failed to get status: {}", e))?;

    if !status.is_rotating {
        anyhow::bail!("No rotation in progress. Use 'tls rotate --cert <path>' first.");
    }

    controller
        .promote()
        .map_err(|e| anyhow::anyhow!("Failed to promote: {}", e))?;

    println!("Certificate promoted successfully");
    println!("Restart TLS server to apply new certificate");

    if let Ok(status) = controller.status() {
        println!();
        println!("Current FP: {}", status.fp_current);
    }

    Ok(())
}

fn cancel_cmd() -> Result<()> {
    let config_path = TlsConfig::default_path();
    let controller = RotationController::new(&config_path);

    let status = controller
        .status()
        .map_err(|e| anyhow::anyhow!("Failed to get status: {}", e))?;

    if !status.is_rotating {
        anyhow::bail!("No rotation in progress.");
    }

    controller
        .cancel()
        .map_err(|e| anyhow::anyhow!("Failed to cancel: {}", e))?;

    println!("Rotation cancelled");
    Ok(())
}

fn status_cmd(json_output: bool) -> Result<()> {
    let config_path = TlsConfig::default_path();
    let controller = RotationController::new(&config_path);
    let status = controller
        .status()
        .map_err(|e| anyhow::anyhow!("Failed to get status: {}", e))?;

    if json_output {
        println!("{}", serde_json::to_string_pretty(&serde_json::json!({
            "is_rotating": status.is_rotating,
            "fp_current": status.fp_current,
            "fp_next": status.fp_next,
            "days_remaining": status.days_remaining,
        }))?);
        return Ok(());
    }

    println!("TLS Rotation Status");
    println!("  Rotating:   {}", if status.is_rotating { "yes" } else { "no" });
    println!("  Current FP: {}", status.fp_current);
    if let Some(next) = status.fp_next {
        println!("  Next FP:    {}", next);
    }
    if let Some(days) = status.days_remaining {
        println!("  Days left:  {}", days);
    }

    Ok(())
}

fn validate_certificate(cert_data: &[u8]) -> Result<()> {
    let cert_str = std::str::from_utf8(cert_data).context("Certificate is not valid UTF-8 PEM")?;

    if !cert_str.contains("-----BEGIN CERTIFICATE-----") {
        anyhow::bail!("File does not appear to be a PEM certificate");
    }

    if !cert_str.contains("-----END CERTIFICATE-----") {
        anyhow::bail!("Incomplete PEM certificate");
    }

    Ok(())
}

fn verify_cmd(file: Option<&str>, json_output: bool) -> Result<()> {
    let audit_file = if let Some(file) = file {
        std::path::PathBuf::from(file)
    } else {
        let home = env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        std::path::PathBuf::from(home)
            .join(".armadillo")
            .join("audit")
            .join("audit.current.ndjson")
    };

    let result = agent_macos::audit::verifier::verify_chain(&audit_file)?;

    if json_output {
        println!("{}", serde_json::to_string_pretty(&serde_json::json!({
            "valid": result.valid,
            "entries": result.total_records,
            "last_valid_seq": result.last_valid_seq,
            "last_valid_hash": result.last_valid_hash,
            "first_invalid_line": result.first_error.as_ref().map(|err| err.line),
            "error": result.first_error.as_ref().map(|err| err.message.clone()),
        }))?);
    } else if result.valid {
        println!("Audit log valid");
        println!("Entries verified: {}", result.total_records);
    } else {
        println!("Audit log INVALID");
        if let Some(line) = result.first_error.as_ref().map(|err| err.line) {
            println!("First invalid line: {}", line);
        }
        if let Some(err) = result.first_error.as_ref().map(|err| err.message.clone()) {
            println!("Error: {}", err);
        }
        process::exit(2);
    }

    Ok(())
}

fn totp_enroll_cmd(label: Option<String>) -> Result<()> {
    let label = label.unwrap_or_else(|| {
        let hostname = hostname::get()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        format!("Armadillo on {}", hostname)
    });

    let secret = totp::generate_secret();
    totp::store_totp_secret(&secret)?;

    let uri = totp::otpauth_url(&label, &secret);
    let ascii = totp::ascii_qr(&uri);

    println!("TOTP enrolled successfully");
    println!("Label: {}", label);
    println!("URI: {}", uri);
    println!();
    println!("{}", ascii);
    Ok(())
}

fn totp_status_cmd() -> Result<()> {
    let enabled = totp::load_totp_secret().is_ok();
    println!("TOTP: {}", if enabled { "enabled" } else { "disabled" });
    Ok(())
}

fn totp_revoke_cmd(force: bool) -> Result<()> {
    if !force {
        eprintln!("Use --force to revoke the enrolled TOTP secret.");
        process::exit(2);
    }
    totp::revoke_totp_secret()?;
    println!("TOTP secret revoked");
    Ok(())
}

fn totp_show_uri_cmd(label: Option<String>) -> Result<()> {
    let secret = totp::load_totp_secret().map_err(|_| anyhow!("No TOTP secret enrolled"))?;
    let label = label.unwrap_or_else(|| {
        let hostname = hostname::get()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        format!("Armadillo on {}", hostname)
    });
    println!("{}", totp::otpauth_url(&label, &secret));
    Ok(())
}
