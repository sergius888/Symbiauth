use std::collections::HashMap;
use std::time::Instant;

pub struct TokenBucket {
    tokens: f64,
    capacity: f64,
    refill_per_sec: f64,
    last: Instant,
}

impl TokenBucket {
    pub fn new(capacity: f64, per_minute: f64) -> Self {
        Self {
            tokens: capacity,
            capacity,
            refill_per_sec: per_minute / 60.0,
            last: Instant::now(),
        }
    }

    fn refill(&mut self) {
        let now = Instant::now();
        let dt = now.duration_since(self.last).as_secs_f64();
        self.tokens = (self.tokens + dt * self.refill_per_sec).min(self.capacity);
        self.last = now;
    }

    pub fn take(&mut self) -> bool {
        self.refill();
        if self.tokens >= 1.0 {
            self.tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

pub struct RateLimiter {
    per_origin: HashMap<String, TokenBucket>,
    capacity: f64,
    per_minute: f64,
    // auth prompt concurrency guards
    #[allow(dead_code)] // Reserved for deferred auth-concurrency gating flow.
    pub max_global_auth: usize,
    #[allow(dead_code)] // Reserved for deferred auth-concurrency gating flow.
    pub max_per_origin_auth: usize,
    #[allow(dead_code)] // Reserved for deferred auth-concurrency gating flow.
    pub current_global_auth: usize,
    #[allow(dead_code)] // Reserved for deferred auth-concurrency gating flow.
    pub current_auth_by_origin: HashMap<String, usize>,
}

impl RateLimiter {
    pub fn new(
        per_minute: f64,
        capacity: f64,
        max_global_auth: usize,
        max_per_origin_auth: usize,
    ) -> Self {
        Self {
            per_origin: HashMap::new(),
            capacity,
            per_minute,
            max_global_auth,
            max_per_origin_auth,
            current_global_auth: 0,
            current_auth_by_origin: HashMap::new(),
        }
    }

    pub fn allow_origin(&mut self, origin: &str) -> bool {
        let b = self
            .per_origin
            .entry(origin.to_string())
            .or_insert_with(|| TokenBucket::new(self.capacity, self.per_minute));
        b.take()
    }

    #[allow(dead_code)] // Reserved for deferred auth prompt concurrency gating.
    pub fn try_enter_auth(&mut self, origin: &str) -> bool {
        if self.current_global_auth >= self.max_global_auth {
            return false;
        }
        let n = self
            .current_auth_by_origin
            .entry(origin.to_string())
            .or_insert(0);
        if *n >= self.max_per_origin_auth {
            return false;
        }
        self.current_global_auth += 1;
        *n += 1;
        true
    }

    #[allow(dead_code)] // Reserved for deferred auth prompt concurrency gating.
    pub fn leave_auth(&mut self, origin: &str) {
        if self.current_global_auth > 0 {
            self.current_global_auth -= 1;
        }
        if let Some(n) = self.current_auth_by_origin.get_mut(origin) {
            if *n > 0 {
                *n -= 1;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    #[test]
    fn test_token_bucket_basic() {
        let mut bucket = TokenBucket::new(5.0, 300.0); // 5 tokens/min = fast refill
        assert!(bucket.take());
        assert!(bucket.take());
        assert!(bucket.take());
        assert!(bucket.take());
        assert!(bucket.take());
        assert!(!bucket.take()); // Exhausted
    }

    #[test]
    fn test_token_bucket_refill() {
        let mut bucket = TokenBucket::new(5.0, 300.0); // 5 req/sec for test speed
        assert!(bucket.take());
        assert!(bucket.take());
        assert!(bucket.take());
        assert!(bucket.take());
        assert!(bucket.take());
        assert!(!bucket.take());

        thread::sleep(Duration::from_millis(250)); // Should refill ~1.25 tokens
        assert!(bucket.take()); // Can take 1
        assert!(!bucket.take()); // Not enough for 2
    }

    #[test]
    fn test_rate_limiter_per_origin() {
        let mut rl = RateLimiter::new(5.0, 5.0, 10, 5);
        for _ in 0..5 {
            assert!(rl.allow_origin("example.com"));
        }
        assert!(!rl.allow_origin("example.com")); // 6th should fail

        // Different origin should have separate bucket
        assert!(rl.allow_origin("other.com"));
    }

    #[test]
    fn test_auth_concurrency_global() {
        let mut rl = RateLimiter::new(100.0, 10.0, 3, 5);
        assert!(rl.try_enter_auth("a.com"));
        assert!(rl.try_enter_auth("b.com"));
        assert!(rl.try_enter_auth("c.com"));
        assert!(!rl.try_enter_auth("d.com")); // 4th should fail (global max = 3)

        rl.leave_auth("a.com");
        assert!(rl.try_enter_auth("d.com")); // Now allowed
    }

    #[test]
    fn test_auth_concurrency_per_origin() {
        let mut rl = RateLimiter::new(100.0, 10.0, 10, 1); // max 1 per origin
        assert!(rl.try_enter_auth("example.com"));
        assert!(!rl.try_enter_auth("example.com")); // 2nd for same origin fails

        rl.leave_auth("example.com");
        assert!(rl.try_enter_auth("example.com")); // Now allowed
    }
}
