use serde::{Deserialize, Serialize};
use std::path::PathBuf;

const MAX_SERVICES: usize = 12;

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct ManualWindows {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub daily: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub weekly: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub monthly: Option<f64>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Service {
    pub id: String,
    pub name: String,
    /// Provider kind: claude | codex | grokbot | manual
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_color")]
    pub color: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub manual: Option<ManualWindows>,
}

fn default_true() -> bool {
    true
}
fn default_color() -> String {
    "#9ca3af".into()
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(default)]
pub struct Config {
    pub services: Vec<Service>,
    /// Minutes between usage refreshes.
    pub refresh_minutes: u64,
    /// Usage % at/above which a window shows as degraded. Default 70.
    pub warn_pct: f64,
    /// Usage % at/above which a window shows as bad. Default 90.
    pub bad_pct: f64,
    /// Use demo numbers (no network / no local logins).
    pub demo: bool,
    pub always_on_top: bool,
    pub locked: bool,
    pub check_updates: bool,
    pub update_channel: String,
    /// Toast when a service crosses into PROBLEM or recovers.
    pub notifications: bool,
    pub x: Option<i32>,
    pub y: Option<i32>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            services: vec![
                Service {
                    id: "claude".into(),
                    name: "Claude".into(),
                    kind: "claude".into(),
                    enabled: true,
                    color: "#D97757".into(),
                    manual: None,
                },
                Service {
                    id: "codex".into(),
                    name: "Codex".into(),
                    kind: "codex".into(),
                    enabled: true,
                    color: "#10A37F".into(),
                    manual: None,
                },
                Service {
                    id: "grokbot".into(),
                    name: "Grok Bot".into(),
                    kind: "grokbot".into(),
                    enabled: true,
                    color: "#C9C9C9".into(),
                    manual: None,
                },
            ],
            refresh_minutes: 5,
            warn_pct: 70.0,
            bad_pct: 90.0,
            demo: false,
            always_on_top: true,
            locked: false,
            check_updates: true,
            update_channel: "stable".into(),
            notifications: true,
            x: None,
            y: None,
        }
    }
}

/// Folder the running exe lives in.
pub fn exe_dir() -> Option<PathBuf> {
    std::env::current_exe().ok()?.parent().map(PathBuf::from)
}

/// Portable mode: a `portable.txt` next to the exe keeps config + history beside it.
pub fn is_portable() -> bool {
    exe_dir().is_some_and(|d| d.join("portable.txt").exists())
}

pub fn path() -> PathBuf {
    if is_portable() {
        if let Some(d) = exe_dir() {
            return d.join("data").join("config.json");
        }
    }
    let base = std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    base.join("AIUsageWidget").join("config.json")
}

/// Drop blank ids; trim fields; de-duplicate by id; cap count; clamp thresholds.
pub(crate) fn normalize(c: &mut Config) {
    c.services.retain(|s| !s.id.trim().is_empty());
    for s in &mut c.services {
        s.id = s.id.trim().to_string();
        if s.name.trim().is_empty() {
            s.name = s.id.clone();
        }
        s.kind = s.kind.trim().to_ascii_lowercase();
        if s.kind.is_empty() {
            s.kind = "manual".into();
        }
        if s.color.trim().is_empty() {
            s.color = default_color();
        }
    }
    let mut seen = std::collections::HashSet::new();
    c.services.retain(|s| seen.insert(s.id.to_ascii_lowercase()));
    // Strip retired kinds from older configs.
    c.services.retain(|s| s.kind != "cursor");
    c.services.truncate(MAX_SERVICES);
    if c.refresh_minutes == 0 {
        c.refresh_minutes = 5;
    }
    if c.warn_pct <= 0.0 || c.warn_pct > 100.0 {
        c.warn_pct = 70.0;
    }
    if c.bad_pct <= c.warn_pct || c.bad_pct > 100.0 {
        c.bad_pct = c.warn_pct.max(90.0).min(100.0);
    }
    if !matches!(c.update_channel.to_ascii_lowercase().as_str(), "stable" | "beta") {
        c.update_channel = "stable".into();
    }
}

pub fn load() -> Config {
    let p = path();
    match std::fs::read_to_string(&p).ok().and_then(|s| serde_json::from_str::<Config>(&s).ok()) {
        Some(mut c) => {
            let before = c.services.len();
            normalize(&mut c);
            if c.services.len() != before {
                save(&c);
            }
            c
        }
        None => {
            let c = Config::default();
            save(&c);
            c
        }
    }
}

pub fn save(c: &Config) {
    let p = path();
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(s) = serde_json::to_string_pretty(c) {
        let _ = std::fs::write(p, s);
    }
}

/// Load, modify, save - used for position / toggle changes.
pub fn update(f: impl FnOnce(&mut Config)) {
    let mut c = load();
    f(&mut c);
    save(&c);
}

/// JSON passed to scripts/fetch.ps1 (services only).
pub fn fetch_payload(c: &Config) -> String {
    serde_json::json!({ "services": c.services }).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn svc(id: &str, kind: &str) -> Service {
        Service {
            id: id.into(),
            name: id.into(),
            kind: kind.into(),
            enabled: true,
            color: "#fff".into(),
            manual: None,
        }
    }

    #[test]
    fn blanks_and_duplicates_dropped_and_capped() {
        let mut services = vec![svc("  ", "claude"), svc("claude", "claude"), svc("Claude", "claude")];
        for i in 0..20 {
            services.push(svc(&format!("s{i}"), "manual"));
        }
        let mut c = Config { services, ..Config::default() };
        normalize(&mut c);
        assert!(c.services.len() <= MAX_SERVICES);
        assert_eq!(c.services.iter().filter(|s| s.id.eq_ignore_ascii_case("claude")).count(), 1);
        assert!(c.services.iter().all(|s| !s.id.trim().is_empty()));
    }

    #[test]
    fn thresholds_clamped() {
        let mut c = Config { warn_pct: 0.0, bad_pct: 10.0, refresh_minutes: 0, ..Config::default() };
        normalize(&mut c);
        assert_eq!(c.warn_pct, 70.0);
        assert!(c.bad_pct >= c.warn_pct);
        assert_eq!(c.refresh_minutes, 5);
    }

    #[test]
    fn old_config_without_new_keys_still_parses() {
        let c: Config = serde_json::from_str(
            r#"{"refresh_minutes":30,"services":[{"id":"claude","name":"Claude","type":"claude"}]}"#,
        )
        .unwrap();
        assert_eq!(c.refresh_minutes, 30);
        assert!(c.always_on_top && c.notifications && c.check_updates);
        assert_eq!(c.update_channel, "stable");
        assert_eq!(c.warn_pct, 70.0);
    }

    #[test]
    fn normalize_strips_retired_kinds() {
        let mut c = Config {
            services: vec![
                svc("claude", "claude"),
                svc("cursor", "cursor"),
                svc("grokbot", "grokbot"),
            ],
            ..Config::default()
        };
        normalize(&mut c);
        assert!(!c.services.iter().any(|s| s.kind == "cursor"));
        assert_eq!(c.services.len(), 2);
    }
}
