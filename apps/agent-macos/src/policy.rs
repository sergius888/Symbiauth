use regex::Regex;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use thiserror::Error;
use url::Url;

// ---------- Step-Up Types ----------
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum StepUpMode {
    None,
    FaceId,
    Totp,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct StepUpRule {
    pub mode: StepUpMode,
    pub ttl_s: u64,
    #[serde(default)]
    pub allow_remote: bool,
}

impl StepUpRule {
    pub fn validate(&self) -> Result<(), PolicyError> {
        if self.ttl_s == 0 || self.ttl_s > 3600 {
            return Err(PolicyError::Invalid(
                "step_up.ttl_s must be 1..=3600".into(),
            ));
        }
        if matches!(self.mode, StepUpMode::Totp) && !self.allow_remote {
            return Err(PolicyError::Invalid(
                "mode=totp requires allow_remote=true".into(),
            ));
        }
        Ok(())
    }
}

// ---------- Policy Error ----------
#[derive(Debug, Error)]
pub enum PolicyError {
    #[error("invalid policy: {0}")]
    Invalid(String),
    #[error("io: {0}")]
    Io(String),
    #[error("yaml: {0}")]
    Yaml(String),
}

/// How auth reuse is handled for a match/default.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Reuse {
    PerSession,
    PerOp,
    Ttl(u64),
}

/// Decision returned by the policy matcher.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    Allow,
    Deny,
    RequireStepUp { ttl_s: u64, scopes: Vec<String> },
}

#[derive(Debug, Clone, Deserialize)]
struct Rule {
    when: Match,
    #[serde(default)]
    decision: RuleDecision,
    #[serde(default)]
    ttl_s: Option<u64>,
    #[serde(default)]
    scopes: Vec<String>,
    #[serde(default)]
    step_up: Option<StepUpRule>,
}

#[derive(Debug, Clone, Deserialize, Default)]
struct RuleDecision {
    #[serde(default = "RuleDecision::default_kind")]
    kind: String,
}

impl RuleDecision {
    fn default_kind() -> String {
        "allow".to_string()
    }
}

#[derive(Debug, Clone, Deserialize, Default)]
struct Match {
    origin: Option<String>,
    app: Option<String>,
    action: Option<String>,
    cmd_regex: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct Defaults {
    #[serde(default = "Defaults::default_reuse")]
    reuse: Reuse,
    #[serde(default = "Defaults::default_ttl")]
    ttl_s: u64,
    #[serde(default = "Defaults::default_proximity_mode")]
    proximity_mode: String,
}

impl Defaults {
    fn new() -> Self {
        Self {
            reuse: Self::default_reuse(),
            ttl_s: Self::default_ttl(),
            proximity_mode: Self::default_proximity_mode(),
        }
    }
    fn default_reuse() -> Reuse {
        Reuse::Ttl(Self::default_ttl())
    }
    fn default_ttl() -> u64 {
        300
    }
    fn default_proximity_mode() -> String {
        "prox_first_use".to_string()
    }
}

impl Default for Defaults {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, Deserialize)]
struct Doc {
    #[serde(default)]
    defaults: Defaults,
    #[serde(default)]
    rules: Vec<Rule>,
}

/// Context supplied for a decision.
#[derive(Debug, Clone)]
pub struct MatchCtx {
    pub origin: Option<String>,
    pub app: Option<String>,
    pub action: Option<String>,
    pub cmd: Option<String>,
    pub scope: String,
}

/// Parsed policy document with helpers to decide.
#[derive(Debug, Clone)]
pub struct Policy {
    defaults: Defaults,
    rules: Vec<CompiledRule>,
}

/// Normalize an origin for matching/scoping: lowercases host, defaults to https if no scheme,
/// strips path/query/fragment, drops default ports.
pub fn canonical_origin(input: &str) -> Option<String> {
    let with_scheme = if input.starts_with("http://") || input.starts_with("https://") {
        input.to_string()
    } else {
        format!("https://{input}")
    };
    let url = Url::parse(&with_scheme).ok()?;
    let scheme = url.scheme().to_ascii_lowercase();
    let host = url.host_str()?.to_ascii_lowercase();
    let port = url.port();
    let default_port = match scheme.as_str() {
        "http" => Some(80),
        "https" => Some(443),
        _ => None,
    };
    let origin = match (port, default_port) {
        (Some(p), Some(d)) if p != d => format!("{scheme}://{host}:{p}"),
        (Some(p), None) => format!("{scheme}://{host}:{p}"),
        _ => format!("{scheme}://{host}"),
    };
    Some(origin)
}

#[derive(Debug, Clone)]
struct CompiledRule {
    when: Match,
    cmd_regex: Option<Regex>,
    decision: Decision,
    step_up: Option<StepUpRule>,
}

impl Policy {
    /// Load policy from ARM_POLICY_PATH or default path; falls back to defaults on error.
    pub fn load() -> Self {
        let path = std::env::var("ARM_POLICY_PATH").unwrap_or_else(|_| {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
            format!("{home}/.armadillo/policy.yaml")
        });
        let pb = PathBuf::from(path);
        if let Ok(data) = fs::read_to_string(&pb) {
            if let Ok(doc) = serde_yaml::from_str::<Doc>(&data) {
                return Policy::from_doc(doc);
            }
        }
        Policy::default()
    }

    /// Number of compiled rules (for logging/debug).
    pub fn rule_count(&self) -> usize {
        self.rules.len()
    }

    pub fn default() -> Self {
        Policy::from_doc(Doc {
            defaults: Defaults::new(),
            rules: Vec::new(),
        })
    }

    fn from_doc(doc: Doc) -> Self {
        let mut compiled = Vec::new();
        for r in doc.rules {
            let cmd_regex = r.when.cmd_regex.as_ref().and_then(|p| Regex::new(p).ok());
            let when_origin = r.when.origin.as_deref().and_then(canonical_origin);
            let decision = match r.decision.kind.as_str() {
                "deny" => Decision::Deny,
                "require_step_up" => {
                    let ttl = r.ttl_s.unwrap_or(doc.defaults.ttl_s);
                    Decision::RequireStepUp {
                        ttl_s: ttl,
                        scopes: r.scopes.clone(),
                    }
                }
                _ => Decision::Allow,
            };
            compiled.push(CompiledRule {
                when: Match {
                    origin: when_origin.or(r.when.origin),
                    ..r.when
                },
                cmd_regex,
                decision,
                step_up: r.step_up.clone(),
            });
        }
        Policy {
            defaults: doc.defaults,
            rules: compiled,
        }
    }

    pub fn decide(&self, ctx: &MatchCtx) -> Decision {
        for rule in &self.rules {
            if !rule.matches(ctx) {
                continue;
            }
            return rule.decision.clone();
        }
        // fall back to defaults -> derive decision from reuse mode
        match self.defaults.reuse {
            Reuse::PerOp => Decision::RequireStepUp {
                ttl_s: 0,
                scopes: vec![ctx.scope.clone()],
            },
            // PerSession: require a proof once per session; use 0 here so we don't create
            // an unbounded Duration (which can overflow Instant arithmetic). Session reuse
            // is still enforced via auth_state.session_matches.
            Reuse::PerSession => Decision::RequireStepUp {
                ttl_s: 0,
                scopes: vec![ctx.scope.clone()],
            },
            Reuse::Ttl(ttl) => Decision::RequireStepUp {
                ttl_s: ttl,
                scopes: vec![ctx.scope.clone()],
            },
        }
    }

    pub fn reuse_default(&self) -> Reuse {
        self.defaults.reuse
    }

    pub fn proximity_mode_default(&self) -> String {
        self.defaults.proximity_mode.clone()
    }

    /// Parse policy from YAML string with validation
    pub fn from_yaml(yaml: &str) -> Result<Self, PolicyError> {
        let doc: Doc = serde_yaml::from_str(yaml).map_err(|e| PolicyError::Yaml(e.to_string()))?;

        // Validate every rule (including step_up)
        for r in &doc.rules {
            if let Some(ref s) = r.step_up {
                s.validate()?;
            }
        }

        Ok(Policy::from_doc(doc))
    }

    /// Helper: does this origin/action require step-up?
    pub fn requires_step_up(&self, origin: &str, action: &str) -> Option<&StepUpRule> {
        // Use existing matching logic for origin/action
        // Returns first best match
        for r in &self.rules {
            let origin_ok = r.when.origin.as_deref().map_or(true, |o| o == origin);
            let action_ok = r.when.action.as_deref().map_or(true, |a| a == action);
            if origin_ok && action_ok {
                if let Some(ref s) = r.step_up {
                    if !matches!(s.mode, StepUpMode::None) {
                        return Some(s);
                    }
                }
            }
        }
        None
    }
}

impl CompiledRule {
    fn matches(&self, ctx: &MatchCtx) -> bool {
        if let Some(ref origin) = self.when.origin {
            if ctx.origin.as_deref() != Some(origin.as_str()) {
                return false;
            }
        }
        if let Some(ref app) = self.when.app {
            if ctx.app.as_deref() != Some(app.as_str()) {
                return false;
            }
        }
        if let Some(ref action) = self.when.action {
            if ctx.action.as_deref() != Some(action.as_str()) {
                return false;
            }
        }
        if let Some(ref re) = self.cmd_regex {
            if let Some(cmd) = &ctx.cmd {
                if !re.is_match(cmd) {
                    return false;
                }
            } else {
                return false;
            }
        }
        true
    }
}

// --- Tests ---
#[cfg(test)]
mod tests {
    use super::*;

    fn mk_ctx(
        origin: Option<&str>,
        app: Option<&str>,
        action: Option<&str>,
        scope: &str,
    ) -> MatchCtx {
        MatchCtx {
            origin: origin.map(|s| s.to_string()),
            app: app.map(|s| s.to_string()),
            action: action.map(|s| s.to_string()),
            cmd: None,
            scope: scope.to_string(),
        }
    }

    #[test]
    fn canonicalizes_origin() {
        assert_eq!(
            canonical_origin("EXAMPLE.com").as_deref(),
            Some("https://example.com")
        );
        assert_eq!(
            canonical_origin("http://Example.com:80").as_deref(),
            Some("http://example.com")
        );
        assert_eq!(
            canonical_origin("https://Example.com:443/abc").as_deref(),
            Some("https://example.com")
        );
        assert_eq!(
            canonical_origin("https://example.com:8443/path").as_deref(),
            Some("https://example.com:8443")
        );
    }

    #[test]
    fn default_per_session_requires_step_up() {
        let p = Policy::default();
        let d = p.decide(&mk_ctx(None, None, Some("vault.read"), "vault.read:foo"));
        match d {
            Decision::RequireStepUp { ttl_s, scopes } => {
                assert_eq!(scopes, vec!["vault.read:foo".to_string()]);
                assert_eq!(ttl_s, 300); // default ttl reuse
            }
            _ => panic!("expected require_step_up"),
        }
    }

    #[test]
    fn rule_matches_origin_and_overrides_default() {
        let doc = Doc {
            defaults: Defaults {
                reuse: Reuse::PerSession,
                ttl_s: 300,
                proximity_mode: "prox_first_use".into(),
            },
            rules: vec![Rule {
                when: Match {
                    origin: Some("https://bank.example.com".into()),
                    app: None,
                    action: None,
                    cmd_regex: None,
                },
                decision: RuleDecision {
                    kind: "require_step_up".into(),
                },
                ttl_s: Some(0),
                scopes: vec!["cred.get:https://bank.example.com:*".into()],
                step_up: None,
            }],
        };
        let p = Policy::from_doc(doc);
        let d = p.decide(&mk_ctx(
            Some("https://bank.example.com"),
            None,
            Some("cred.get"),
            "cred.get:https://bank.example.com:alice",
        ));
        match d {
            Decision::RequireStepUp { ttl_s, scopes } => {
                assert_eq!(ttl_s, 0);
                assert_eq!(scopes, vec!["cred.get:https://bank.example.com:*"]);
            }
            _ => panic!("expected require_step_up for bank"),
        }
    }

    #[test]
    fn cmd_regex_mismatch_falls_back() {
        let doc = Doc {
            defaults: Defaults {
                reuse: Reuse::PerSession,
                ttl_s: 300,
                proximity_mode: "prox_first_use".into(),
            },
            rules: vec![Rule {
                when: Match {
                    origin: None,
                    app: Some("Terminal".into()),
                    action: Some("cmd.run".into()),
                    cmd_regex: Some("rm\\s+-rf".into()),
                },
                decision: RuleDecision {
                    kind: "deny".into(),
                },
                ttl_s: None,
                scopes: vec![],
                step_up: None,
            }],
        };
        let p = Policy::from_doc(doc);
        let ctx = MatchCtx {
            origin: None,
            app: Some("Terminal".into()),
            action: Some("cmd.run".into()),
            cmd: Some("ls -la".into()),
            scope: "cmd.run:ls".into(),
        };
        let d = p.decide(&ctx);
        // cmd doesn't match regex; should fall back to default require_step_up
        match d {
            Decision::RequireStepUp { .. } => {}
            _ => panic!("expected fallback require_step_up"),
        }
    }

    // -------- Step-Up Tests --------
    #[test]
    fn parse_totp_ok() {
        let y = r#"
rules:
  - when:
      origin: "bank.com"
      action: "cred.get"
    step_up:
      mode: "totp"
      ttl_s: 120
      allow_remote: true
"#;
        let p = Policy::from_yaml(y).unwrap();
        let s = p.requires_step_up("https://bank.com", "cred.get").unwrap();
        assert_eq!(s.mode, StepUpMode::Totp);
        assert_eq!(s.ttl_s, 120);
        assert!(s.allow_remote);
    }

    #[test]
    fn invalid_totp_without_remote() {
        let y = r#"
rules:
  - when:
      origin: "bank.com"
      action: "cred.get"
    step_up:
      mode: "totp"
      ttl_s: 120
      allow_remote: false
"#;
        assert!(Policy::from_yaml(y).is_err());
    }

    #[test]
    fn ttl_bounds() {
        let y = r#"
rules:
  - when:
      origin: "test.com"
    step_up:
      mode: "faceid"
      ttl_s: 0
"#;
        assert!(Policy::from_yaml(y).is_err());
    }

    #[test]
    fn none_means_no_stepup() {
        let y = r#"
rules:
  - when:
      origin: "github.com"
      action: "vault.write"
    step_up:
      mode: "none"
      ttl_s: 60
"#;
        let p = Policy::from_yaml(y).unwrap();
        assert!(p
            .requires_step_up("https://github.com", "vault.write")
            .is_none());
    }
}
