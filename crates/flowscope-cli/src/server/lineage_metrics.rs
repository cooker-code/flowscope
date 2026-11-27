//! Bounded, process-local completion samples. Queue totals remain durable in SQLite.
use flowscope_storage::Action;
use serde::Serialize;
use std::{
    collections::VecDeque,
    sync::Mutex,
    time::{Duration, Instant},
};

const WINDOW: Duration = Duration::from_secs(60);
struct Completion {
    principal: String,
    action: Action,
    at: Instant,
}
pub(super) struct IngestionMeter {
    started: Instant,
    started_at: String,
    completions: Mutex<VecDeque<Completion>>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct RateSnapshot {
    pub monitoring_since: String,
    pub window_seconds: u64,
    pub observed_seconds: u64,
    pub warming_up: bool,
    pub confirmed_events: usize,
    pub events_per_minute: Option<f64>,
}
impl IngestionMeter {
    pub fn new() -> Self {
        Self {
            started: Instant::now(),
            started_at: chrono::Utc::now().to_rfc3339(),
            completions: Mutex::new(VecDeque::new()),
        }
    }
    pub fn record(&self, principal: &str, action: Action) {
        if !matches!(action, Action::Publish | Action::RecordUsage) {
            return;
        }
        let now = Instant::now();
        let mut rows = self.completions.lock().unwrap_or_else(|e| e.into_inner());
        Self::prune(&mut rows, now);
        rows.push_back(Completion {
            principal: principal.into(),
            action,
            at: now,
        });
    }
    fn prune(rows: &mut VecDeque<Completion>, now: Instant) {
        while rows
            .front()
            .is_some_and(|r| now.saturating_duration_since(r.at) >= WINDOW)
        {
            rows.pop_front();
        }
    }
    pub fn snapshot(&self, principal: Option<&str>, action: Action) -> RateSnapshot {
        self.snapshot_at(principal, action, Instant::now())
    }
    fn snapshot_at(&self, principal: Option<&str>, action: Action, now: Instant) -> RateSnapshot {
        let mut rows = self.completions.lock().unwrap_or_else(|e| e.into_inner());
        Self::prune(&mut rows, now);
        let n = rows
            .iter()
            .filter(|r| r.action == action && principal.is_none_or(|id| r.principal == id))
            .count();
        let observed = now
            .saturating_duration_since(self.started)
            .min(WINDOW)
            .as_secs();
        RateSnapshot {
            monitoring_since: self.started_at.clone(),
            window_seconds: 60,
            observed_seconds: observed,
            warming_up: observed < 60,
            confirmed_events: n,
            events_per_minute: (observed >= 60).then_some(n as f64),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rates_are_scoped_warm_up_and_expire() {
        let mut meter = IngestionMeter::new();
        meter.started = Instant::now() - Duration::from_secs(90);
        meter.record("a", Action::Publish);
        meter.record("b", Action::Publish);
        meter.record("a", Action::RecordUsage);
        meter.record("a", Action::Observe);
        assert_eq!(
            meter.snapshot(None, Action::Publish).events_per_minute,
            Some(2.)
        );
        assert_eq!(
            meter.snapshot(Some("a"), Action::Publish).confirmed_events,
            1
        );
        assert_eq!(
            meter
                .snapshot(Some("a"), Action::RecordUsage)
                .confirmed_events,
            1
        );
        assert_eq!(
            meter
                .snapshot_at(None, Action::Publish, Instant::now() + WINDOW)
                .events_per_minute,
            Some(0.)
        );
        assert!(meter.completions.lock().unwrap().is_empty());
        let fresh = IngestionMeter::new();
        fresh.record("a", Action::Publish);
        let snapshot = fresh.snapshot(None, Action::Publish);
        assert!(snapshot.warming_up);
        assert_eq!(snapshot.events_per_minute, None);
        assert_eq!(snapshot.confirmed_events, 1);
    }
}
