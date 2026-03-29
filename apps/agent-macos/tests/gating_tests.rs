// Integration tests for PR1: agent gating hardening
// Tests 401/403 semantics, rate limiting, auth concurrency, and idempotency

use agent_macos::error::ApiError;
use agent_macos::idempotency::Idempotency;
use agent_macos::ratelimit::RateLimiter;
use rusqlite::Connection;

#[test]
fn test_api_error_codes() {
    let err = ApiError::BadRequest("test".into());
    assert_eq!(err.http_code(), 400);
    assert_eq!(err.err_reason(), "bad_request");

    let err = ApiError::AuthRequired("step-up needed".into());
    assert_eq!(err.http_code(), 401);
    assert_eq!(err.err_reason(), "auth_required");

    let err = ApiError::Denied("policy denies".into());
    assert_eq!(err.http_code(), 403);
    assert_eq!(err.err_reason(), "policy_denied");

    let err = ApiError::TooMany("rate limit".into());
    assert_eq!(err.http_code(), 429);
    assert_eq!(err.err_reason(), "too_many_requests");
}

#[test]
fn test_rate_limit_per_origin() {
    let mut rl = RateLimiter::new(5.0, 5.0, 10, 5);

    // First 5 requests should pass
    for i in 0..5 {
        assert!(rl.allow_origin("example.com"), "Request {} should pass", i);
    }

    // 6th request should fail (rate limit)
    assert!(
        !rl.allow_origin("example.com"),
        "6th request should be rate limited"
    );

    // Different origin should have separate bucket
    assert!(
        rl.allow_origin("other.com"),
        "Different origin should be allowed"
    );
}

#[test]
fn test_auth_concurrency_global_limit() {
    let mut rl = RateLimiter::new(100.0, 10.0, 3, 5); // max 3 global

    assert!(rl.try_enter_auth("a.com"));
    assert!(rl.try_enter_auth("b.com"));
    assert!(rl.try_enter_auth("c.com"));
    assert!(
        !rl.try_enter_auth("d.com"),
        "4th auth should fail (global limit = 3)"
    );

    // Release one
    rl.leave_auth("a.com");
    assert!(
        rl.try_enter_auth("d.com"),
        "Should be allowed after releasing one"
    );
}

#[test]
fn test_auth_concurrency_per_origin_limit() {
    let mut rl = RateLimiter::new(100.0, 10.0, 10, 1); // max 1 per origin

    assert!(rl.try_enter_auth("example.com"));
    assert!(
        !rl.try_enter_auth("example.com"),
        "2nd auth for same origin should fail"
    );

    // Different origin should be allowed
    assert!(rl.try_enter_auth("other.com"));

    // Release original
    rl.leave_auth("example.com");
    assert!(
        rl.try_enter_auth("example.com"),
        "Should be allowed after release"
    );
}

#[test]
fn test_idempotency_persisted() {
    let conn = Connection::open_in_memory().unwrap();
    let idem = Idempotency::new(conn).unwrap();

    // First write
    assert!(!idem.was_applied("write-123").unwrap());
    idem.mark_applied("write-123").unwrap();
    assert!(idem.was_applied("write-123").unwrap());

    // Simulate restart (same connection in this test, but persisted in real usage)
    assert!(
        idem.was_applied("write-123").unwrap(),
        "Should persist across restarts"
    );

    // Duplicate mark is idempotent
    idem.mark_applied("write-123").unwrap();
    assert!(idem.was_applied("write-123").unwrap());
}

#[test]
fn test_idempotency_gc() {
    use std::{thread, time::Duration};

    let conn = Connection::open_in_memory().unwrap();
    let idem = Idempotency::new(conn).unwrap();

    idem.mark_applied("old-key").unwrap();
    idem.mark_applied("recent-key").unwrap();

    assert!(idem.was_applied("old-key").unwrap());
    assert!(idem.was_applied("recent-key").unwrap());

    // GC with large TTL (300s = 5min) should keep everything
    let deleted = idem.gc(300).unwrap();
    assert_eq!(deleted, 0, "Should keep all with 5min TTL");

    // To test actual deletion, we'd need to wait or mock time.
    // For now, just verify non-deletion with reasonable TTL works.
}

#[test]
fn test_401_vs_403_semantics() {
    // 401: Auth is required but CAN be provided
    let err_401 = ApiError::AuthRequired("step-up required for bank.com".into());
    assert_eq!(err_401.http_code(), 401);
    assert!(err_401.to_string().contains("auth required"));

    // 403: Policy explicitly denies, no amount of auth will help
    let err_403 = ApiError::Denied("policy blocks malicious.com".into());
    assert_eq!(err_403.http_code(), 403);
    assert!(err_403.to_string().contains("denied"));

    // Different error codes for different scenarios
    assert_ne!(err_401.http_code(), err_403.http_code());
}

#[test]
fn test_rate_limiter_mixed_scenario() {
    let mut rl = RateLimiter::new(5.0, 5.0, 3, 1);

    // Origin A: exhaust rate limit
    for i in 0..5 {
        assert!(rl.allow_origin("a.com"), "A request {} should pass", i);
    }
    assert!(!rl.allow_origin("a.com"), "A 6th should fail");

    // Origin B: start auth
    assert!(rl.try_enter_auth("b.com"));
    assert!(
        !rl.try_enter_auth("b.com"),
        "B 2nd auth should fail (1 per origin)"
    );

    // Origin C: different origin can auth
    assert!(rl.try_enter_auth("c.com"));
    assert!(rl.try_enter_auth("d.com"));
    assert!(
        !rl.try_enter_auth("e.com"),
        "5th auth should fail (global max 3)"
    );

    // Release one
    rl.leave_auth("b.com");
    assert!(rl.try_enter_auth("e.com"), "Now allowed");
}
