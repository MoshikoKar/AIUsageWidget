//! Usage snapshot API: refresh worker + status math.

use serde::de::{self, Visitor};
use serde::{Deserialize, Deserializer, Serialize};
use std::fmt;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::config::{self, Config};
use crate::history;

fn de_opt_reset<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    struct ResetVisitor;
    impl<'de> Visitor<'de> for ResetVisitor {
        type Value = Option<String>;
        fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
            f.write_str("reset timestamp string or unix seconds/ms")
        }
        fn visit_unit<E: de::Error>(self) -> Result<Self::Value, E> {
            Ok(None)
        }
        fn visit_none<E: de::Error>(self) -> Result<Self::Value, E> {
            Ok(None)
        }
        fn visit_some<D2: Deserializer<'de>>(self, d: D2) -> Result<Self::Value, D2::Error> {
            d.deserialize_any(ResetVisitor)
        }
        fn visit_str<E: de::Error>(self, v: &str) -> Result<Self::Value, E> {
            let t = v.trim();
            Ok(if t.is_empty() { None } else { Some(t.to_string()) })
        }
        fn visit_string<E: de::Error>(self, v: String) -> Result<Self::Value, E> {
            self.visit_str(&v)
        }
        fn visit_i64<E: de::Error>(self, v: i64) -> Result<Self::Value, E> {
            Ok(Some(v.to_string()))
        }
        fn visit_u64<E: de::Error>(self, v: u64) -> Result<Self::Value, E> {
            Ok(Some(v.to_string()))
        }
        fn visit_f64<E: de::Error>(self, v: f64) -> Result<Self::Value, E> {
            Ok(Some((v as i64).to_string()))
        }
    }
    deserializer.deserialize_any(ResetVisitor)
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Window {
    pub pct: f64,
    #[serde(default, deserialize_with = "de_opt_reset")]
    pub reset: Option<String>,
    #[serde(default)]
    pub derived: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct UsageWindows {
    #[serde(default)]
    pub session: Option<Window>,
    #[serde(default)]
    pub daily: Option<Window>,
    #[serde(default)]
    pub weekly: Option<Window>,
    #[serde(default)]
    pub monthly: Option<Window>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct ServiceSnapshot {
    pub id: String,
    pub name: String,
    pub color: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub status: String,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub plan: Option<String>,
    #[serde(default)]
    pub windows: UsageWindows,
}

#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    pub services: Vec<ServiceSnapshot>,
    pub fetched_at: Option<Instant>,
    pub fetching: bool,
    pub last_error: Option<String>,
}

pub type Shared = Arc<Mutex<Snapshot>>;

/// Status: 0 waiting, 1 good, 2 degraded, 3 bad.
pub fn window_status(pct: f64, warn: f64, bad: f64) -> i32 {
    if pct >= bad {
        3
    } else if pct >= warn {
        2
    } else {
        1
    }
}

pub fn service_status(s: &ServiceSnapshot, warn: f64, bad: f64) -> i32 {
    if s.status == "error" {
        return 3;
    }
    if s.status != "ok" && s.status != "manual" {
        return 0;
    }
    let mut worst = 0;
    for w in [&s.windows.session, &s.windows.daily, &s.windows.weekly, &s.windows.monthly]
        .into_iter()
        .flatten()
    {
        worst = worst.max(window_status(w.pct, warn, bad));
    }
    if worst == 0 {
        1 // fetched with no windows still counts as ok/idle-good
    } else {
        worst
    }
}

fn scripts_dir() -> Option<PathBuf> {
    // Dev: <repo>/scripts ; installed: <exe dir>/scripts
    if let Some(d) = config::exe_dir() {
        let next = d.join("scripts");
        if next.join("fetch.ps1").exists() {
            return Some(next);
        }
    }
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("scripts");
    if manifest.join("fetch.ps1").exists() {
        Some(manifest)
    } else {
        None
    }
}

fn run_fetch(cfg: &Config) -> Result<Vec<ServiceSnapshot>, String> {
    let dir = scripts_dir().ok_or_else(|| "scripts/fetch.ps1 not found next to the app".to_string())?;
    let script = dir.join("fetch.ps1");
    let payload = config::fetch_payload(cfg);
    let tmp = std::env::temp_dir().join(format!("aiuw-fetch-{}.json", std::process::id()));
    std::fs::write(&tmp, &payload).map_err(|e| format!("could not write temp config: {e}"))?;
    use std::os::windows::process::CommandExt;
    use std::process::Command;
    let mut cmd = Command::new("powershell.exe");
    cmd.args([
        "-NoProfile",
        "-WindowStyle",
        "Hidden",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        &script.to_string_lossy(),
        "-ConfigPath",
        &tmp.to_string_lossy(),
    ])
    .current_dir(&dir)
    .creation_flags(crate::sys::NO_WINDOW);
    if cfg.demo {
        cmd.arg("-Demo");
    }
    let out = cmd.output().map_err(|e| format!("could not run fetch.ps1: {e}"))?;
    let _ = std::fs::remove_file(&tmp);
    let stdout = decode_ps_output(&out.stdout);
    let stderr = decode_ps_output(&out.stderr);
    if !out.status.success() {
        return Err(if stderr.is_empty() { stdout } else { stderr });
    }
    // Last non-empty line is the JSON array (PowerShell may write warnings).
    let json_line = stdout
        .lines()
        .rev()
        .find(|l| l.trim().starts_with('['))
        .unwrap_or(&stdout);
    // Strip illegal control chars (e.g. U+001A from a broken "->" glyph in messages).
    let cleaned = strip_json_controls(json_line);
    serde_json::from_str(&cleaned).map_err(|e| format!("bad fetch JSON: {e}\n{cleaned}"))
}

fn decode_ps_output(bytes: &[u8]) -> String {
    // PowerShell 5.x may emit UTF-16 LE when stdout is redirected.
    let text = if bytes.starts_with(&[0xFF, 0xFE]) {
        let words: Vec<u16> = bytes[2..]
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        String::from_utf16_lossy(&words)
    } else if bytes.len() > 4 && bytes.iter().step_by(2).filter(|&&b| b == 0).count() > bytes.len() / 4 {
        let words: Vec<u16> = bytes
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        String::from_utf16_lossy(&words)
    } else {
        String::from_utf8_lossy(bytes).into_owned()
    };
    text.trim().to_string()
}

fn strip_json_controls(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_control() && c != '\t' { ' ' } else { c })
        .collect()
}

/// Background refresher. First fetch is immediate; then every `refresh_minutes`.
pub fn spawn(cfg: Config, stop: Arc<std::sync::atomic::AtomicBool>) -> Shared {
    let shared = Arc::new(Mutex::new(Snapshot { fetching: true, ..Default::default() }));
    let shared2 = shared.clone();
    std::thread::spawn(move || {
        let mut hist = history::load();
        let mut next = Instant::now();
        loop {
            if stop.load(std::sync::atomic::Ordering::Relaxed) {
                break;
            }
            if Instant::now() >= next {
                {
                    let mut g = shared2.lock().unwrap();
                    g.fetching = true;
                }
                // Re-read config each cycle so Edit config + wait works without full restart
                // for refresh interval / demo / thresholds (services list still needs Reload).
                let live = config::load();
                let use_cfg = Config {
                    services: cfg.services.clone(), // services change requires Reload
                    ..live
                };
                match run_fetch(&use_cfg) {
                    Ok(mut services) => {
                        history::apply_daily(&mut services, &mut hist, use_cfg.demo);
                        if !use_cfg.demo {
                            history::save(&hist);
                        }
                        let mut g = shared2.lock().unwrap();
                        g.services = services;
                        g.fetched_at = Some(Instant::now());
                        g.fetching = false;
                        g.last_error = None;
                    }
                    Err(e) => {
                        let mut g = shared2.lock().unwrap();
                        g.fetching = false;
                        g.last_error = Some(e);
                        if g.fetched_at.is_none() {
                            g.services.clear();
                        }
                    }
                }
                let mins = config::load().refresh_minutes.max(1);
                next = Instant::now() + Duration::from_secs(mins * 60);
            }
            std::thread::sleep(Duration::from_millis(200));
        }
    });
    shared
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn window_thresholds() {
        assert_eq!(window_status(10.0, 70.0, 90.0), 1);
        assert_eq!(window_status(70.0, 70.0, 90.0), 2);
        assert_eq!(window_status(90.0, 70.0, 90.0), 3);
    }

    #[test]
    fn service_error_is_bad() {
        let s = ServiceSnapshot {
            id: "x".into(),
            name: "X".into(),
            color: "#fff".into(),
            kind: "claude".into(),
            status: "error".into(),
            message: Some("no".into()),
            plan: None,
            windows: UsageWindows::default(),
        };
        assert_eq!(service_status(&s, 70.0, 90.0), 3);
    }
}
