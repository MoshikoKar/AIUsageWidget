//! Daily usage baselines (derived when a service has no native daily window).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct DailyBase {
    pub date: String,
    pub key: String,
    pub base: f64,
}

fn path() -> PathBuf {
    crate::config::path().with_file_name("history.json")
}

pub fn load() -> HashMap<String, DailyBase> {
    std::fs::read_to_string(path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

pub fn save(map: &HashMap<String, DailyBase>) {
    if let Ok(s) = serde_json::to_string_pretty(map) {
        let _ = std::fs::write(path(), s);
    }
}

pub fn today_local() -> String {
    // Local calendar date via Windows-friendly approach: format from system local time.
    let now = std::time::SystemTime::now();
    let secs = now.duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) as i64;
    // Approximate local date using offset from `chrono`-free PowerShell-free path:
    // Prefer the OS local via `cmd` is heavy; use UTC date as fallback is wrong for "daily".
    // Read local via Windows GetLocalTime would need more features; use a small PowerShell-free API:
    local_ymd()
        .unwrap_or_else(|| {
            let days = secs / 86_400;
            let (y, m, d) = civil_from_days(days);
            format!("{y:04}-{m:02}-{d:02}")
        })
}

fn local_ymd() -> Option<String> {
    use std::os::windows::process::CommandExt;
    use std::process::Command;
    let out = Command::new("powershell.exe")
        .args(["-NoProfile", "-Command", "Get-Date -Format yyyy-MM-dd"])
        .creation_flags(crate::sys::NO_WINDOW)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.len() == 10 {
        Some(s)
    } else {
        None
    }
}

/// Howard Hinnant civil_from_days (UTC). Only used if local date lookup fails.
fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y as i32, m as u32, d as u32)
}

/// Attach a derived daily window from weekly/monthly when missing. Updates `hist` in place.
pub fn apply_daily(
    services: &mut [crate::usage::ServiceSnapshot],
    hist: &mut HashMap<String, DailyBase>,
    demo: bool,
) {
    let today = today_local();
    for s in services.iter_mut() {
        if s.status != "ok" && s.status != "manual" {
            continue;
        }
        if s.windows.daily.is_some() {
            continue;
        }
        let (key, cur) = if let Some(w) = &s.windows.weekly {
            ("weekly", w.pct)
        } else if let Some(w) = &s.windows.monthly {
            ("monthly", w.pct)
        } else {
            continue;
        };
        let entry = hist.get(&s.id);
        let mut base = match entry {
            Some(h) if h.date == today && h.key == key => h.base,
            _ => {
                if demo {
                    (cur * 0.85 * 10.0).round() / 10.0
                } else {
                    cur
                }
            }
        };
        if cur < base {
            base = 0.0; // limit reset during the day
        }
        hist.insert(
            s.id.clone(),
            DailyBase { date: today.clone(), key: key.into(), base },
        );
        s.windows.daily = Some(crate::usage::Window {
            pct: ((cur - base) * 10.0).round() / 10.0,
            reset: None,
            derived: Some(key.into()),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::usage::{ServiceSnapshot, UsageWindows, Window};

    #[test]
    fn derives_daily_from_weekly_and_resets_base_on_drop() {
        let mut hist = HashMap::new();
        hist.insert(
            "claude".into(),
            DailyBase { date: today_local(), key: "weekly".into(), base: 50.0 },
        );
        let mut services = vec![ServiceSnapshot {
            id: "claude".into(),
            name: "Claude".into(),
            color: "#fff".into(),
            kind: "claude".into(),
            status: "ok".into(),
            message: None,
            plan: Some("pro".into()),
            windows: UsageWindows {
                weekly: Some(Window { pct: 40.0, reset: None, derived: None }),
                ..Default::default()
            },
        }];
        apply_daily(&mut services, &mut hist, false);
        let d = services[0].windows.daily.as_ref().unwrap();
        assert_eq!(d.pct, 40.0); // base reset to 0 when cur < base
        assert_eq!(hist["claude"].base, 0.0);
    }
}
