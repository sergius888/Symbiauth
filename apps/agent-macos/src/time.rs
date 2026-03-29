// M1.5: Monotonic/wall clock abstraction for auth/token TTL enforcement
use std::time::{Instant, SystemTime};
#[cfg(test)]
use std::time::Duration;

pub trait Clock: Send + Sync {
    fn now_mono(&self) -> Instant;
    #[allow(dead_code)] // Used by deferred skew-telemetry path.
    fn now_wall(&self) -> SystemTime;
}

#[derive(Clone, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_mono(&self) -> Instant {
        Instant::now()
    }
    fn now_wall(&self) -> SystemTime {
        SystemTime::now()
    }
}

#[cfg(test)]
#[derive(Clone)]
pub struct FakeClock {
    mono: Instant,
    wall: SystemTime,
}

#[cfg(test)]
impl FakeClock {
    pub fn new() -> Self {
        Self {
            mono: Instant::now(),
            wall: SystemTime::UNIX_EPOCH,
        }
    }

    pub fn with(mono: Instant, wall: SystemTime) -> Self {
        Self { mono, wall }
    }

    pub fn advance_mono(&mut self, d: Duration) {
        self.mono += d;
    }

    pub fn advance_wall(&mut self, d: Duration) {
        self.wall += d;
    }
}

#[cfg(test)]
impl Clock for FakeClock {
    fn now_mono(&self) -> Instant {
        self.mono
    }
    fn now_wall(&self) -> SystemTime {
        self.wall
    }
}
