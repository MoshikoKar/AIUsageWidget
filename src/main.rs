#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod config;
mod history;
mod sys;
mod update;
mod usage;

use std::cell::Cell;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use slint::{
    ComponentHandle, LogicalPosition, Model, ModelRc, PhysicalPosition, SharedString, Timer, TimerMode, VecModel,
};
use tray_icon::menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};

slint::include_modules!();

fn hide_from_taskbar() {
    use windows::Win32::UI::WindowsAndMessaging::*;
    use windows::core::w;
    unsafe {
        if let Ok(hwnd) = FindWindowW(None, w!("AIUsageWidget")) {
            let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
            let want = (ex | WS_EX_TOOLWINDOW.0 as isize) & !(WS_EX_APPWINDOW.0 as isize);
            if want != ex {
                let _ = ShowWindow(hwnd, SW_HIDE);
                SetWindowLongPtrW(hwnd, GWL_EXSTYLE, want);
                let _ = ShowWindow(hwnd, SW_SHOWNA);
            }
        }
    }
}

fn tray_icon_image() -> Icon {
    Icon::from_rgba(include_bytes!("../assets/tray32.rgba").to_vec(), 32, 32).expect("tray icon")
}

fn fmt_pct(w: &Option<usage::Window>) -> SharedString {
    match w {
        Some(w) => format!("{:.0}%", w.pct).into(),
        None => "-".into(),
    }
}

fn parse_color(hex: &str) -> slint::Color {
    let h = hex.trim().trim_start_matches('#');
    if h.len() == 6 {
        if let (Ok(r), Ok(g), Ok(b)) = (
            u8::from_str_radix(&h[0..2], 16),
            u8::from_str_radix(&h[2..4], 16),
            u8::from_str_radix(&h[4..6], 16),
        ) {
            return slint::Color::from_rgb_u8(r, g, b);
        }
    }
    slint::Color::from_rgb_u8(0x9c, 0xa3, 0xaf)
}

fn build_view(s: &usage::ServiceSnapshot, warn: f64, bad: f64) -> ServiceView {
    let status = usage::service_status(s, warn, bad);
    let plan = s.plan.clone().unwrap_or_default();
    let message = if s.status == "error" {
        s.message.clone().unwrap_or_else(|| "error".into())
    } else {
        String::new()
    };
    ServiceView {
        name: s.name.clone().into(),
        plan: plan.into(),
        message: message.into(),
        status,
        session: fmt_pct(&s.windows.session),
        daily: fmt_pct(&s.windows.daily),
        weekly: fmt_pct(&s.windows.weekly),
        monthly: fmt_pct(&s.windows.monthly),
        accent: parse_color(&s.color),
    }
}

fn main() -> Result<(), slint::PlatformError> {
    let _instance = match sys::single_instance(std::env::args().any(|a| a == "--wait")) {
        Some(g) => g,
        None => return Ok(()),
    };
    let cfg = config::load();
    let stop = Arc::new(AtomicBool::new(false));
    let shared = usage::spawn(cfg.clone(), stop.clone());

    let ui = MainWindow::new()?;
    ui.set_on_top(cfg.always_on_top);
    ui.set_locked(cfg.locked);
    let saved_pos = match (cfg.x, cfg.y) {
        (Some(x), Some(y)) if sys::position_visible(x, y) => Some((x, y)),
        _ => None,
    };
    if let Some((x, y)) = saved_pos {
        ui.window().set_position(PhysicalPosition::new(x, y));
    }
    ui.set_startup(sys::startup_enabled());

    {
        let w = ui.as_weak();
        ui.on_drag(move |dx, dy| {
            if let Some(ui) = w.upgrade() {
                if ui.get_locked() {
                    return;
                }
                let win = ui.window();
                let sf = win.scale_factor();
                let p = win.position();
                win.set_position(PhysicalPosition::new(p.x + (dx * sf) as i32, p.y + (dy * sf) as i32));
            }
        });
    }

    let show_item = MenuItem::new("Show / Hide (minimize to tray)", true, None);
    let top_item = CheckMenuItem::new("Always on top", true, cfg.always_on_top, None);
    let lock_item = CheckMenuItem::new("Lock position", true, cfg.locked, None);
    let startup_item = CheckMenuItem::new("Start with Windows", true, sys::startup_enabled(), None);
    let edit_item = MenuItem::new("Edit config...", true, None);
    let reload_item = MenuItem::new("Reload config", true, None);
    let update_item = MenuItem::new(format!("Check for updates (v{})", update::VERSION), true, None);
    let quit_item = MenuItem::new("Quit", true, None);
    let menu = Menu::new();
    menu.append_items(&[
        &show_item,
        &PredefinedMenuItem::separator(),
        &top_item,
        &lock_item,
        &startup_item,
        &PredefinedMenuItem::separator(),
        &edit_item,
        &reload_item,
        &update_item,
        &PredefinedMenuItem::separator(),
        &quit_item,
    ])
    .ok();
    let _tray = TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_menu_on_left_click(false)
        .with_tooltip("AI Usage Widget")
        .with_icon(tray_icon_image())
        .build()
        .expect("tray icon");

    let visible = Rc::new(Cell::new(true));
    let quit = {
        let w = ui.as_weak();
        let stop = stop.clone();
        Rc::new(move || {
            if let Some(ui) = w.upgrade() {
                let p = ui.window().position();
                let mut c = config::load();
                c.x = Some(p.x);
                c.y = Some(p.y);
                config::save(&c);
            }
            stop.store(true, Ordering::Relaxed);
            let _ = slint::quit_event_loop();
        })
    };
    let toggle = {
        let w = ui.as_weak();
        let visible = visible.clone();
        Rc::new(move || {
            if let Some(ui) = w.upgrade() {
                if visible.get() {
                    let _ = ui.hide();
                } else {
                    let _ = ui.show();
                    hide_from_taskbar();
                }
                visible.set(!visible.get());
            }
        })
    };
    let set_top: Rc<dyn Fn(bool)> = {
        let w = ui.as_weak();
        let item = top_item.clone();
        Rc::new(move |on| {
            if let Some(ui) = w.upgrade() {
                ui.set_on_top(on);
            }
            item.set_checked(on);
            config::update(|c| c.always_on_top = on);
        })
    };
    let set_lock: Rc<dyn Fn(bool)> = {
        let w = ui.as_weak();
        let item = lock_item.clone();
        Rc::new(move |on| {
            if let Some(ui) = w.upgrade() {
                ui.set_locked(on);
            }
            item.set_checked(on);
            config::update(|c| c.locked = on);
        })
    };
    let set_startup: Rc<dyn Fn(bool)> = {
        let w = ui.as_weak();
        let item = startup_item.clone();
        Rc::new(move |on| {
            sys::set_startup(on);
            let actual = sys::startup_enabled();
            item.set_checked(actual);
            if let Some(ui) = w.upgrade() {
                ui.set_startup(actual);
            }
        })
    };
    let edit_config: Rc<dyn Fn()> = Rc::new(|| {
        config::load();
        let _ = std::process::Command::new("notepad").arg(config::path()).spawn();
    });
    let reload: Rc<dyn Fn()> = {
        let q = quit.clone();
        Rc::new(move || {
            q();
            if let Ok(exe) = std::env::current_exe() {
                let _ = std::process::Command::new(exe).arg("--wait").spawn();
            }
        })
    };
    {
        let t = toggle.clone();
        ui.on_hide_clicked(move || t());
        let q = quit.clone();
        ui.on_quit_clicked(move || q());
        let (w, f) = (ui.as_weak(), set_top.clone());
        ui.on_toggle_top(move || {
            if let Some(ui) = w.upgrade() {
                f(!ui.get_on_top());
            }
        });
        let (w, f) = (ui.as_weak(), set_lock.clone());
        ui.on_toggle_lock(move || {
            if let Some(ui) = w.upgrade() {
                f(!ui.get_locked());
            }
        });
        let (w, f) = (ui.as_weak(), set_startup.clone());
        ui.on_toggle_startup(move || {
            if let Some(ui) = w.upgrade() {
                f(!ui.get_startup());
            }
        });
        let f = edit_config.clone();
        ui.on_edit_config(move || f());
        let f = reload.clone();
        ui.on_reload_config(move || f());
        ui.on_check_update(|| update::check_async(true));
        ui.set_version(update::VERSION.into());
    }
    if cfg.check_updates {
        Timer::single_shot(Duration::from_secs(10), || update::check_async(false));
    }

    let model = Rc::new(VecModel::<ServiceView>::default());
    ui.set_services(ModelRc::from(model.clone()));
    let timer = Timer::default();
    {
        let w = ui.as_weak();
        let (toggle, quit) = (toggle.clone(), quit.clone());
        let (show_id, quit_id) = (show_item.id().clone(), quit_item.id().clone());
        let (top_id, lock_id) = (top_item.id().clone(), lock_item.id().clone());
        let (edit_id, reload_id) = (edit_item.id().clone(), reload_item.id().clone());
        let update_id = update_item.id().clone();
        let startup_id = startup_item.id().clone();
        let notify = cfg.notifications;
        let shared = shared.clone();
        let (mut bad_since, mut ok_since, mut notified): (Option<Instant>, Option<Instant>, bool) = (None, None, false);
        timer.start(TimerMode::Repeated, Duration::from_millis(400), move || {
            if update::QUIT_REQUESTED.load(Ordering::Relaxed) {
                quit();
                return;
            }
            while let Ok(ev) = MenuEvent::receiver().try_recv() {
                if ev.id == update_id {
                    update::check_async(true);
                } else if ev.id == startup_id {
                    set_startup(startup_item.is_checked());
                }
                if ev.id == show_id {
                    toggle();
                } else if ev.id == quit_id {
                    quit();
                } else if ev.id == top_id {
                    set_top(top_item.is_checked());
                } else if ev.id == lock_id {
                    set_lock(lock_item.is_checked());
                } else if ev.id == edit_id {
                    edit_config();
                } else if ev.id == reload_id {
                    reload();
                }
            }
            while let Ok(ev) = TrayIconEvent::receiver().try_recv() {
                if let TrayIconEvent::Click {
                    button: MouseButton::Left,
                    button_state: MouseButtonState::Up,
                    ..
                } = ev
                {
                    toggle();
                }
            }

            let snap = shared.lock().unwrap().clone();
            let live = config::load();
            let warn = live.warn_pct;
            let bad = live.bad_pct;
            let mut views = Vec::with_capacity(snap.services.len());
            let mut worst = 0;
            let mut bad_names: Vec<String> = Vec::new();
            for s in &snap.services {
                let v = build_view(s, warn, bad);
                worst = worst.max(v.status);
                if v.status == 3 {
                    bad_names.push(s.name.clone());
                }
                views.push(v);
            }
            if snap.services.is_empty() && snap.fetching {
                worst = 0;
            }

            if notify {
                let hold = Duration::from_secs(5);
                if worst == 3 {
                    ok_since = None;
                    let since = *bad_since.get_or_insert_with(Instant::now);
                    if !notified && since.elapsed() >= hold {
                        notified = true;
                        sys::toast(
                            "AI Usage: high usage",
                            &format!("Problem: {}", bad_names.join(", ")),
                        );
                    }
                } else if worst > 0 {
                    bad_since = None;
                    if notified {
                        let since = *ok_since.get_or_insert_with(Instant::now);
                        if since.elapsed() >= hold {
                            notified = false;
                            ok_since = None;
                            sys::toast("AI Usage: back to normal", "Usage is under the warn threshold again.");
                        }
                    }
                }
            }

            let subtitle = if let Some(err) = &snap.last_error {
                err.clone()
            } else if snap.fetching && snap.fetched_at.is_none() {
                "fetching usage...".into()
            } else if snap.fetching {
                "refreshing...".into()
            } else if let Some(t) = snap.fetched_at {
                format!("updated {}s ago", t.elapsed().as_secs())
            } else {
                "waiting...".into()
            };

            if let Some(ui) = w.upgrade() {
                ui.set_subtitle(subtitle.into());
                ui.set_overall(worst);
                ui.set_status_text(SharedString::from(match worst {
                    0 => "STARTING",
                    1 => "ALL GOOD",
                    2 => "DEGRADED",
                    _ => "PROBLEM",
                }));
                if model.row_count() != views.len() {
                    model.set_vec(views);
                } else {
                    for (i, v) in views.into_iter().enumerate() {
                        model.set_row_data(i, v);
                    }
                }
            }
        });
    }

    ui.show()?;
    hide_from_taskbar();
    Timer::single_shot(Duration::from_millis(300), hide_from_taskbar);
    if saved_pos.is_none() {
        ui.window().set_position(LogicalPosition::new(40.0, 40.0));
    }
    slint::run_event_loop_until_quit()
}
