// Origin canonicalization for security policy enforcement
// Prevents bypass via scheme/host/port variations

use idna::Config as IdnaConfig;
use std::hash::{Hash, Hasher};
use url::Url;

/// Canonical origin in format: scheme://host[:port]
/// Used for credential scoping, policy matching, and audit
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CanonicalOrigin(pub String);

impl Hash for CanonicalOrigin {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.0.hash(state);
    }
}

impl AsRef<str> for CanonicalOrigin {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for CanonicalOrigin {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Canonicalize origin string to prevent bypass attacks
///
/// Rules:
/// - Default scheme: https
/// - Lowercase scheme and host
/// - IDNA/Punycode normalize host
/// - Strip default ports (80 for http, 443 for https)
/// - Keep non-default ports
/// - Path/query/fragment ignored
///
/// Examples:
/// - "bank.com" → "https://bank.com"
/// - "HTTPS://EXAMPLE.COM:443" → "https://example.com"
/// - "http://ex.com:8080" → "http://ex.com:8080"
pub fn canonicalize_origin(input: &str) -> Result<CanonicalOrigin, String> {
    let s = input.trim();
    if s.is_empty() {
        return Err("empty origin".to_string());
    }

    // If input has a scheme (contains ://), parse directly
    // Otherwise prepend https://
    let with_scheme = if s.contains("://") {
        s.to_string()
    } else {
        format!("https://{}", s)
    };

    // Parse URL
    let url = Url::parse(&with_scheme).map_err(|e| format!("Invalid URL: {}", e))?;

    // Allow-list schemes
    let scheme = url.scheme().to_ascii_lowercase();
    if scheme != "http" && scheme != "https" {
        return Err(format!(
            "Unsupported scheme: {}. Only http/https allowed",
            scheme
        ));
    }

    // Host normalization
    let host = match url.host().ok_or("Missing host".to_string())? {
        url::Host::Domain(d) => {
            // 1) strip trailing dot, 2) IDNA ASCII, 3) lowercase
            let no_dot = d.trim_end_matches('.');
            let ascii = IdnaConfig::default()
                .use_std3_ascii_rules(true)
                .to_ascii(no_dot)
                .map_err(|_| "IDNA normalization failed".to_string())?;
            ascii.to_ascii_lowercase()
        }
        url::Host::Ipv4(v4) => v4.to_string(),
        url::Host::Ipv6(v6) => format!("[{}]", v6), // keep brackets in canonical form
    };

    // Port handling: strip defaults
    let port_opt = url.port();
    let needs_port = match (scheme.as_str(), port_opt) {
        ("http", Some(80)) => false,
        ("https", Some(443)) => false,
        (_, Some(_)) => true,
        _ => false,
    };

    let origin = if needs_port {
        format!("{}://{}:{}", scheme, host, port_opt.unwrap())
    } else {
        format!("{}://{}", scheme, host)
    };

    Ok(CanonicalOrigin(origin))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_canonicalization() {
        // Default scheme
        assert_eq!(
            canonicalize_origin("bank.com").unwrap().0,
            "https://bank.com"
        );

        // Already canonical
        assert_eq!(
            canonicalize_origin("https://example.com").unwrap().0,
            "https://example.com"
        );
    }

    #[test]
    fn test_uppercase_normalization() {
        assert_eq!(
            canonicalize_origin("HTTPS://EXAMPLE.COM").unwrap().0,
            "https://example.com"
        );

        assert_eq!(
            canonicalize_origin("HTTP://TEST.ORG").unwrap().0,
            "http://test.org"
        );
    }

    #[test]
    fn test_default_port_stripping() {
        // Strip 443 for https
        assert_eq!(
            canonicalize_origin("https://example.com:443").unwrap().0,
            "https://example.com"
        );

        // Strip 80 for http
        assert_eq!(
            canonicalize_origin("http://example.com:80").unwrap().0,
            "http://example.com"
        );
    }

    #[test]
    fn test_non_default_ports() {
        // Keep non-default ports
        assert_eq!(
            canonicalize_origin("https://example.com:8443").unwrap().0,
            "https://example.com:8443"
        );

        assert_eq!(
            canonicalize_origin("http://example.com:8080").unwrap().0,
            "http://example.com:8080"
        );
    }

    #[test]
    fn test_path_query_ignored() {
        assert_eq!(
            canonicalize_origin("https://example.com/path?query=1")
                .unwrap()
                .0,
            "https://example.com"
        );

        assert_eq!(
            canonicalize_origin("https://example.com:8443/path#fragment")
                .unwrap()
                .0,
            "https://example.com:8443"
        );
    }

    #[test]
    fn test_idna_normalization() {
        // Test with internationalized domain (if it has special chars)
        // Punycode domains should work
        assert_eq!(
            canonicalize_origin("https://xn--d1acpjx3f.xn--p1ai")
                .unwrap()
                .0,
            "https://xn--d1acpjx3f.xn--p1ai"
        );
    }

    #[test]
    fn test_invalid_schemes() {
        // Reject non-http/https schemes
        assert!(canonicalize_origin("chrome-extension://abc123").is_err());
        assert!(canonicalize_origin("file:///path/to/file").is_err());
        assert!(canonicalize_origin("ftp://example.com").is_err());
    }

    #[test]
    fn test_missing_host() {
        assert!(canonicalize_origin("https://").is_err());
        assert!(canonicalize_origin("http://").is_err());
    }

    #[test]
    fn test_malformed_urls() {
        assert!(canonicalize_origin("not a url").is_err());
        assert!(canonicalize_origin("://example.com").is_err());
    }

    #[test]
    fn test_comprehensive_table() {
        let cases = vec![
            ("bank.com", "https://bank.com"),
            ("HTTPS://GitHub.COM:443/login", "https://github.com"),
            ("http://Example.org:80/", "http://example.org"),
            ("HTTPS://foo.com", "https://foo.com"),
            ("https://test.com:9000/path", "https://test.com:9000"),
            ("localhost:3000", "https://localhost:3000"),
        ];

        for (input, expected) in cases {
            assert_eq!(
                canonicalize_origin(input).unwrap().0,
                expected,
                "Failed for input: {}",
                input
            );
        }
    }

    #[test]
    fn test_origin_equality() {
        let o1 = canonicalize_origin("https://example.com:443").unwrap();
        let o2 = canonicalize_origin("HTTPS://EXAMPLE.COM").unwrap();
        assert_eq!(o1, o2);
    }

    #[test]
    fn test_origin_inequality() {
        let o1 = canonicalize_origin("https://example.com").unwrap();
        let o2 = canonicalize_origin("https://example.com:8443").unwrap();
        assert_ne!(o1, o2);

        let o3 = canonicalize_origin("http://example.com").unwrap();
        let o4 = canonicalize_origin("https://example.com").unwrap();
        assert_ne!(o3, o4);
    }
}
