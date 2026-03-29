use thiserror::Error;

#[derive(Debug, Error)]
#[allow(dead_code)] // Shared error surface includes reserved variants for deferred endpoints.
pub enum ApiError {
    #[error("bad request: {0}")]
    BadRequest(String), // 400
    #[error("auth required: {0}")]
    AuthRequired(String), // 401
    #[error("denied: {0}")]
    Denied(String), // 403
    #[error("not found: {0}")]
    NotFound(String), // 404
    #[error("timeout: {0}")]
    Timeout(String), // 408
    #[error("conflict: {0}")]
    Conflict(String), // 409
    #[error("too many requests: {0}")]
    TooMany(String), // 429
    #[error("internal: {0}")]
    Internal(String), // 500
    #[error("unavailable: {0}")]
    Unavailable(String), // 503

    // M1.5: Monotonic TTL errors
    #[error("auth token expired")]
    TokenExpired,
    #[error("clock skew too large")]
    ClockSkew,
}

impl ApiError {
    #[allow(dead_code)] // Used by HTTP adapter layer in deferred transport path.
    pub fn http_code(&self) -> u16 {
        use ApiError::*;
        match self {
            BadRequest(_) => 400,
            AuthRequired(_) => 401,
            Denied(_) => 403,
            NotFound(_) => 404,
            Timeout(_) => 408,
            Conflict(_) => 409,
            TooMany(_) => 429,
            Internal(_) => 500,
            Unavailable(_) => 503,
            TokenExpired => 401,
            ClockSkew => 401,
        }
    }

    #[allow(dead_code)] // Used by structured error response adapter in deferred transport path.
    pub fn err_reason(&self) -> &'static str {
        use ApiError::*;
        match self {
            BadRequest(_) => "bad_request",
            AuthRequired(_) => "auth_required",
            Denied(_) => "policy_denied",
            NotFound(_) => "not_found",
            Timeout(_) => "timeout",
            Conflict(_) => "conflict",
            TooMany(_) => "too_many_requests",
            Internal(_) => "internal",
            Unavailable(_) => "unavailable",
            TokenExpired => "token_expired",
            ClockSkew => "clock_skew",
        }
    }
}
