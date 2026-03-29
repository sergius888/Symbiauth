use anyhow::{Context, Result};
use rand::{distributions::Alphanumeric, Rng};
use serde::Serialize;
use serde_json::{json, Value};
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

const PROTO: &str = "armadillo.webext";
const VERSION: u32 = 1;
const MIN_COMPATIBLE: u32 = 1;
const SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum Outbound<'a> {
    #[serde(rename = "nm.hello.ack")]
    HelloAck {
        proto: &'a str,
        version: u32,
        min_compatible: u32,
        channel_token: String,
        schema_version: u32,
    },
    #[serde(rename = "error")]
    Error { code: &'a str, message: &'a str },
}

fn read_nm_message(stdin: &mut impl Read) -> Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    stdin
        .read_exact(&mut len_buf)
        .context("failed to read NM length prefix")?;
    let len = u32::from_le_bytes(len_buf) as usize;
    let mut buf = vec![0u8; len];
    stdin
        .read_exact(&mut buf)
        .context("failed to read NM payload")?;
    Ok(buf)
}

fn write_nm_message(stdout: &mut impl Write, value: &Value) -> Result<()> {
    let bytes = serde_json::to_vec(value)?;
    let len = (bytes.len() as u32).to_le_bytes();
    stdout.write_all(&len)?;
    stdout.write_all(&bytes)?;
    stdout.flush()?;
    Ok(())
}

fn gen_channel_token() -> String {
    rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(24)
        .map(char::from)
        .collect()
}

fn handle_hello(stdout: &mut impl Write) -> Result<()> {
    let ack = Outbound::HelloAck {
        proto: PROTO,
        version: VERSION,
        min_compatible: MIN_COMPATIBLE,
        channel_token: gen_channel_token(),
        schema_version: SCHEMA_VERSION,
    };
    write_nm_message(stdout, &serde_json::to_value(&ack)?)?;
    Ok(())
}

struct AgentClient {
    sock_path: String,
    stream: Option<UnixStream>,
}

impl AgentClient {
    fn new(sock_path: String) -> Self {
        Self {
            sock_path,
            stream: None,
        }
    }

    fn ensure_connected(&mut self) -> Result<()> {
        if self.stream.is_some() {
            return Ok(());
        }
        let stream = UnixStream::connect(&self.sock_path)
            .with_context(|| format!("connect {}", self.sock_path))?;
        stream.set_read_timeout(Some(Duration::from_secs(5)))?;
        stream.set_write_timeout(Some(Duration::from_secs(5)))?;
        self.stream = Some(stream);
        eprintln!(
            r#"{{"event":"agent.connect","path":"{}","status":"ok"}}"#,
            self.sock_path
        );
        Ok(())
    }

    fn request(&mut self, payload: &Value) -> Result<Value> {
        let mut attempts = 0;
        loop {
            attempts += 1;
            self.ensure_connected()?;
            if let Some(stream) = self.stream.as_mut() {
                match Self::send_and_receive(stream, payload) {
                    Ok(v) => return Ok(v),
                    Err(e) => {
                        eprintln!(
                            r#"{{"event":"agent.rpc.fail","error":"{}","attempt":{}}}"#,
                            e, attempts
                        );
                        self.stream = None;
                        if attempts >= 2 {
                            return Err(e);
                        }
                    }
                }
            }
        }
    }

    fn send_and_receive(stream: &mut UnixStream, payload: &Value) -> Result<Value> {
        let bytes = serde_json::to_vec(payload)?;
        let len = (bytes.len() as u32).to_be_bytes();
        stream.write_all(&len)?;
        stream.write_all(&bytes)?;
        stream.flush()?;

        let mut len_buf = [0u8; 4];
        stream.read_exact(&mut len_buf)?;
        let resp_len = u32::from_be_bytes(len_buf) as usize;
        let mut buf = vec![0u8; resp_len];
        stream.read_exact(&mut buf)?;
        let value: Value = serde_json::from_slice(&buf)?;
        Ok(value)
    }
}

fn main_loop(mut stdin: impl Read, mut stdout: impl Write, mut agent: AgentClient) -> Result<()> {
    loop {
        let raw = match read_nm_message(&mut stdin) {
            Ok(bytes) => bytes,
            Err(err) => {
                eprintln!(
                    r#"{{"event":"nm.disconnect","error":"{}"}}"#,
                    err.to_string()
                );
                return Ok(());
            }
        };

        let msg: Value = match serde_json::from_slice(&raw) {
            Ok(msg) => msg,
            Err(err) => {
                let err_msg = Outbound::Error {
                    code: "BAD_JSON",
                    message: "invalid JSON",
                };
                write_nm_message(&mut stdout, &serde_json::to_value(&err_msg)?)?;
                eprintln!(
                    r#"{{"event":"nm.bad_json","error":"{}","len":{},"hex":"{}"}}"#,
                    err,
                    raw.len(),
                    hex_snippet(&raw, 64)
                );
                continue;
            }
        };

        let response = match msg.get("type").and_then(|v| v.as_str()) {
            Some("nm.hello") => {
                let proto = msg
                    .get("proto")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default();
                let version = msg.get("version").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
                let min_compatible = msg
                    .get("min_compatible")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0) as u32;
                let proto_ok = proto == PROTO;
                let version_ok = version >= MIN_COMPATIBLE && VERSION >= min_compatible;
                if proto_ok && version_ok {
                    eprintln!(
                        r#"{{"event":"nm.hello.recv","proto":"{}","version":{},"min":{}}}"#,
                        proto, version, min_compatible
                    );
                    handle_hello(&mut stdout)?;
                    eprintln!(
                        r#"{{"event":"nm.hello.ack","schema_version":{}}}"#,
                        SCHEMA_VERSION
                    );
                    continue;
                } else {
                    serde_json::to_value(Outbound::Error {
                        code: "PROTO_INCOMPATIBLE",
                        message: "update extension/app",
                    })?
                }
            }
            Some("cred.list")
            | Some("cred.get")
            | Some("prox.heartbeat")
            | Some("prox.status")
            | Some("vault.status") => match agent.request(&msg) {
                Ok(value) => value,
                Err(err) => {
                    let corr = msg
                        .get("corr_id")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string());
                    let mut body = json!({
                        "type":"error",
                        "code":"AGENT_UNAVAILABLE",
                        "message": format!("{}", err)
                    });
                    if let Some(cid) = corr {
                        body["corr_id"] = Value::String(cid);
                    }
                    body
                }
            },
            Some(other) => {
                let mut body = json!({
                    "type":"error",
                    "code":"UNKNOWN_MESSAGE_TYPE",
                    "message": format!("Unknown message type: {}", other)
                });
                if let Some(cid) = msg.get("corr_id").and_then(|v| v.as_str()) {
                    body["corr_id"] = Value::String(cid.to_string());
                }
                body
            }
            None => json!({
                "type":"error",
                "code":"MISSING_TYPE",
                "message":"Message must include a 'type' field"
            }),
        };

        write_nm_message(&mut stdout, &response)?;
    }
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|arg| arg == "--stdio-test") {
        let socket_path = default_socket_path();
        let agent = AgentClient::new(socket_path);
        return main_loop(io::stdin(), io::stdout(), agent);
    }
    let stdin = io::stdin();
    let stdout = io::stdout();
    let socket_path = default_socket_path();
    let agent = AgentClient::new(socket_path);
    main_loop(stdin.lock(), stdout.lock(), agent)
}

fn default_socket_path() -> String {
    std::env::var("ARMADILLO_SOCKET_PATH").unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        format!("{}/.armadillo/a.sock", home)
    })
}

fn hex_snippet(data: &[u8], max_len: usize) -> String {
    data.iter()
        .take(max_len)
        .map(|b| format!("{:02x}", b))
        .collect()
}
