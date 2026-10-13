#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

use std::fs;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tao::dpi::LogicalSize;
use tao::event::{Event, StartCause, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tao::window::WindowBuilder;
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use wry::WebViewBuilder;

const SITE: &str = "https://kaanalper.github.io/Asenaizer/";
const FALLBACK_PORT: u16 = 47615;

#[derive(Clone, Debug)]
enum UserEvent {
    Menu(MenuEvent),
    Tray(TrayIconEvent),
    /// Messages from tray.html: "hide" (close button, Escape) and "drag" (header).
    Ipc(String),
    ServiceStopped,
}

#[derive(serde::Deserialize)]
struct Instance {
    port: u16,
}

#[derive(serde::Deserialize)]
struct Location {
    data_dir: Option<PathBuf>,
}

fn default_data_dir() -> PathBuf {
    let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from).unwrap_or_default();
    if cfg!(target_os = "windows") {
        std::env::var_os("LOCALAPPDATA").map(PathBuf::from)
            .unwrap_or_else(|| home.join("AppData/Local")).join("Humanizer")
    } else if cfg!(target_os = "macos") {
        home.join("Library/Application Support/Humanizer")
    } else {
        std::env::var_os("XDG_DATA_HOME").map(PathBuf::from)
            .unwrap_or_else(|| home.join(".local/share")).join("Humanizer")
    }
}

fn data_dir() -> PathBuf {
    if let Some(path) = std::env::var_os("HUMANIZER_DATA_DIR") { return PathBuf::from(path); }
    let default = default_data_dir();
    let location = fs::read(default.join("location.json")).ok()
        .and_then(|b| serde_json::from_slice::<Location>(&b).ok());
    location.and_then(|l| l.data_dir).filter(|p| p.is_absolute() && p.is_dir())
        .unwrap_or(default)
}

fn port() -> u16 {
    fs::read(data_dir().join("instance.json")).ok()
        .and_then(|b| serde_json::from_slice::<Instance>(&b).ok())
        .map(|i| i.port).filter(|p| *p >= 1024).unwrap_or(FALLBACK_PORT)
}

fn helper_running() -> bool {
    let p = port();
    let Ok(mut stream) = TcpStream::connect_timeout(&([127, 0, 0, 1], p).into(), Duration::from_millis(350)) else { return false; };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let _ = stream.write_all(format!("GET /app/ping HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\nConnection: close\r\n\r\n").as_bytes());
    let mut body = String::new();
    stream.read_to_string(&mut body).is_ok() && body.contains("\"app\":\"humanizer\"")
}

fn helper_path() -> PathBuf {
    if let Some(p) = std::env::var_os("ASENAIZER_HELPER") { return PathBuf::from(p); }
    let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("asenaizer-tray"));
    let dir = exe.parent().unwrap_or(Path::new("."));
    dir.join(if cfg!(windows) { "Humanizer.exe" } else { "Humanizer" })
}

fn start_helper() -> std::io::Result<Child> {
    let mut cmd = Command::new(helper_path());
    cmd.args(["--no-browser", "--idle-exit", "0", "--lazy-engine", "--web-origin", "https://kaanalper.github.io"])
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    cmd.spawn()
}

fn open_url(url: &str) {
    #[cfg(target_os = "windows")]
    let _ = Command::new("cmd").args(["/C", "start", "", url]).spawn();
    #[cfg(target_os = "macos")]
    let _ = Command::new("open").arg(url).spawn();
    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    let _ = Command::new("xdg-open").arg(url).spawn();
}

/// Shows or hides the settings window and tells the page, which stops polling the GPU
/// while hidden so a laptop's graphics card can power down.
fn set_shown(window: &tao::window::Window, view: Option<&wry::WebView>, shown: bool) {
    window.set_visible(shown);
    if shown { window.set_focus(); }
    if let Some(view) = view {
        let _ = view.evaluate_script(&format!("window.asenaizerTrayVisible?.({shown})"));
    }
}

fn icon() -> Icon {
    let mut rgba = vec![0_u8; 32 * 32 * 4];
    for y in 0..32 { for x in 0..32 {
        let i = (y * 32 + x) * 4;
        let mark = (x > 6 && x < 25 && y > 6 && y < 25) &&
            ((x as i32 - 16).abs() + (y as i32 - 16).abs() < 14);
        rgba[i..i + 4].copy_from_slice(if mark { &[36, 30, 51, 255] } else { &[201, 182, 255, 255] });
    }}
    Icon::from_rgba(rgba, 32, 32).expect("valid icon")
}

fn main() {
    let helper = match if helper_running() { Ok(None) } else { start_helper().map(Some) } {
        Ok(child) => Arc::new(Mutex::new(child)),
        Err(err) => {
            eprintln!("Asenaizer helper could not start: {err}");
            return;
        }
    };
    let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();
    MenuEvent::set_event_handler(Some(move |event| { let _ = proxy.send_event(UserEvent::Menu(event)); }));
    let proxy = event_loop.create_proxy();
    TrayIconEvent::set_event_handler(Some(move |event| { let _ = proxy.send_event(UserEvent::Tray(event)); }));

    let show_settings = std::env::args().any(|arg| arg == "--settings");
    let builder = WindowBuilder::new()
        .with_title("Asenaizer")
        .with_inner_size(LogicalSize::new(430.0, 520.0))
        .with_min_inner_size(LogicalSize::new(430.0, 520.0))
        .with_max_inner_size(LogicalSize::new(430.0, 520.0))
        .with_resizable(false)
        .with_decorations(false)
        .with_always_on_top(true)
        .with_visible(show_settings);
    #[cfg(target_os = "linux")]
    let builder = { use tao::platform::unix::WindowBuilderExtUnix; builder.with_skip_taskbar(true) };
    #[cfg(target_os = "windows")]
    let builder = { use tao::platform::windows::WindowBuilderExtWindows; builder.with_skip_taskbar(true) };
    let settings_window = builder.build(&event_loop).ok();
    let ipc_proxy = event_loop.create_proxy();
    let settings_view = settings_window.as_ref().and_then(|window| {
        let builder = WebViewBuilder::new()
            .with_url(format!("http://127.0.0.1:{}/tray.html", port()))
            .with_initialization_script(format!("window.asenaizerTrayShown = {show_settings};"))
            .with_ipc_handler(move |req| { let _ = ipc_proxy.send_event(UserEvent::Ipc(req.body().clone())); })
            .with_new_window_req_handler(|url, _| {
                if url == SITE { open_url(SITE); }
                wry::NewWindowResponse::Deny
            });
        #[cfg(target_os = "linux")]
        {
            use tao::platform::unix::WindowExtUnix;
            use wry::WebViewBuilderExtUnix;
            builder.build_gtk(window.default_vbox()?).ok()
        }
        #[cfg(not(target_os = "linux"))]
        { builder.build(window).ok() }
    });

    let menu = Menu::new();
    let status = MenuItem::new("Preparing local model…", false, None);
    let site = MenuItem::new("Open Asenaizer website", true, None);
    let settings = MenuItem::new("Model and device settings", true, None);
    let quit = MenuItem::new("Quit", true, None);
    let _ = menu.append_items(&[&status, &site, &settings, &PredefinedMenuItem::separator(), &quit]);

    let watcher = helper.clone();
    let stopped_proxy = event_loop.create_proxy();
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(2));
        let stopped = watcher.lock().ok().and_then(|mut child| child.as_mut().and_then(|c| c.try_wait().ok().flatten())).is_some();
        if stopped { let _ = stopped_proxy.send_event(UserEvent::ServiceStopped); break; }
    });

    let mut tray = None;
    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;
        match event {
            Event::NewEvents(StartCause::Init) => {
                tray = TrayIconBuilder::new().with_menu(Box::new(menu.clone()))
                    .with_tooltip("Asenaizer · local model").with_icon(icon()).build().ok();
                status.set_text(format!("Local service · port {}", port()));
            }
            Event::UserEvent(UserEvent::ServiceStopped) => {
                status.set_text("Local service stopped");
                if let Some(t) = tray.as_ref() { let _ = t.set_tooltip(Some("Asenaizer · service stopped")); }
            }
            Event::UserEvent(UserEvent::Menu(event)) if event.id == site.id() => open_url(SITE),
            Event::UserEvent(UserEvent::Menu(event)) if event.id == settings.id() => {
                if settings_view.is_some() {
                    if let Some(window) = settings_window.as_ref() { set_shown(window, settings_view.as_ref(), true); }
                } else { open_url(&format!("http://127.0.0.1:{}/tray.html", port())); }
            }
            Event::UserEvent(UserEvent::Tray(TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. })) => {
                if settings_view.is_some() {
                    if let Some(window) = settings_window.as_ref() { set_shown(window, settings_view.as_ref(), true); }
                } else { open_url(&format!("http://127.0.0.1:{}/tray.html", port())); }
            }
            Event::UserEvent(UserEvent::Ipc(message)) => {
                if let Some(window) = settings_window.as_ref() {
                    match message.as_str() {
                        "hide" => set_shown(window, settings_view.as_ref(), false),
                        "drag" => { let _ = window.drag_window(); }
                        _ => {}
                    }
                }
            }
            Event::WindowEvent { event: WindowEvent::CloseRequested, .. } => {
                if let Some(window) = settings_window.as_ref() { set_shown(window, settings_view.as_ref(), false); }
            }
            Event::UserEvent(UserEvent::Menu(event)) if event.id == quit.id() => {
                if let Ok(mut child) = helper.lock() { if let Some(c) = child.as_mut() { let _ = c.kill(); let _ = c.wait(); } }
                drop(tray.take());
                *control_flow = ControlFlow::Exit;
            }
            _ => {}
        }
    });
}
