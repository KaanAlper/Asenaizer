//! Asenaizer Setup for Linux: the windowed face of the install, the twin of the Windows setup window
//! (installer/gui/Setup.cs). It collects the choices, runs the embedded scripts/install-linux.sh with
//! ASZ_DRIVER=<work dir> and shows its phases (status.json) and steps (progress.json). The install itself lives
//! in one place, the script, which is the same path as the one-line install (installer/PROTOCOL.md).
//!
//! Exit codes, read by the script's bootstrap mode: 0 installed, 1 the install failed, 2 cancelled or closed
//! before installing, 3 the window could not start (the bootstrap then continues in the terminal).

#[cfg(target_os = "linux")]
fn main() {
    std::process::exit(linux::run());
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("asenaizer-setup is the Linux setup window; on Windows run Asenaizer-Setup-x64.exe.");
    std::process::exit(3);
}

/// The exit code for the last phase the script reported.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn exit_code(final_phase: Option<&str>, died: bool) -> i32 {
    match final_phase {
        Some("done") => 0,
        Some("error") => 1,
        Some("cancelled") => 2,
        _ if died => 1,
        _ => 2,
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use serde_json::Value;
    use std::fs;
    use std::io::ErrorKind;
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
    use tao::dpi::{LogicalSize, PhysicalPosition};
    use tao::event::{Event, WindowEvent};
    use tao::event_loop::{ControlFlow, EventLoopBuilder};
    use tao::platform::run_return::EventLoopExtRunReturn;
    use tao::platform::unix::WindowExtUnix;
    use tao::window::{Icon, Window, WindowBuilder};
    use wry::{WebView, WebViewBuilder, WebViewBuilderExtUnix};

    const SCRIPT: &str = include_str!("../../../../scripts/install-linux.sh");
    // helper files the script looks for next to itself before it asks GitHub
    const FETCHER: &str = include_str!("../../../../scripts/fetch_linux_release.py");
    const UNINSTALLER: &str = include_str!("../../../../scripts/uninstall-linux.sh");
    const ICON_PNG: &[u8] = include_bytes!("../../../packaging/icon/asenaizer-256.png");
    const PAGE: &str = include_str!("../../setup-ui/setup.html");
    const ICON_SVG: &str = include_str!("../../../web/icon.svg");
    const ICON_RGBA: &[u8] = include_bytes!("../../assets/icon-64.rgba");
    const WIDTH: f64 = 760.0;
    const HEIGHT: f64 = 540.0;
    const BG: (u8, u8, u8, u8) = (15, 13, 11, 255);
    const TICK: Duration = Duration::from_millis(100);
    /// The window shows when the page says it is ready, or after this many ticks anyway.
    const SHOW_AFTER_TICKS: u32 = 20;
    /// How long a script that ended without a final phase gets before the page is told.
    const EXIT_GRACE: Duration = Duration::from_millis(150);

    #[derive(Debug)]
    enum UserEvent {
        /// Messages from setup.html: "ready", "drag", "cancel", "close" and the start JSON.
        Ipc(String),
        Tick,
    }

    struct Install {
        work: PathBuf,
        child: Child,
        final_phase: Option<String>,
        exited_at: Option<Instant>,
        died: bool,
    }

    impl Install {
        fn running(&mut self) -> bool {
            matches!(self.child.try_wait(), Ok(None))
        }

        fn cancel(&self) {
            let _ = fs::write(self.work.join("cancel"), b"");
        }
    }

    pub fn run() -> i32 {
        if std::env::var_os("DISPLAY").is_none() && std::env::var_os("WAYLAND_DISPLAY").is_none() {
            eprintln!("Asenaizer Setup needs a desktop session (DISPLAY or WAYLAND_DISPLAY).");
            return 3;
        }
        // GTK that cannot open the display panics inside tao: the bootstrap then uses the terminal
        let Ok(mut event_loop) = std::panic::catch_unwind(|| EventLoopBuilder::<UserEvent>::with_user_event().build()) else {
            return 3;
        };
        let window = match build_window(&event_loop) {
            Ok(window) => window,
            Err(err) => {
                eprintln!("Asenaizer Setup could not open its window: {err}");
                return 3;
            }
        };
        let view = match build_view(&window, event_loop.create_proxy()) {
            Ok(view) => view,
            Err(err) => {
                eprintln!("Asenaizer Setup could not start its web view: {err}");
                return 3;
            }
        };

        let ticker = event_loop.create_proxy();
        std::thread::spawn(move || loop {
            std::thread::sleep(TICK);
            if ticker.send_event(UserEvent::Tick).is_err() {
                break;
            }
        });

        let mut install: Option<Install> = None;
        let mut shown = false;
        let mut ticks = 0u32;
        let mut code = 2;
        event_loop.run_return(|event, _, control_flow| {
            *control_flow = ControlFlow::Wait;
            let mut quit = false;
            match event {
                Event::UserEvent(UserEvent::Tick) => {
                    ticks = ticks.saturating_add(1);
                    if !shown && ticks >= SHOW_AFTER_TICKS {
                        show(&window, &mut shown);
                    }
                    if let Some(inst) = install.as_mut() {
                        poll(inst, &view);
                    }
                }
                Event::UserEvent(UserEvent::Ipc(message)) => match message.as_str() {
                    "ready" => show(&window, &mut shown),
                    "drag" => {
                        let _ = window.drag_window();
                    }
                    "cancel" => {
                        if let Some(inst) = install.as_ref() {
                            inst.cancel();
                        }
                    }
                    "close" => quit = close_requested(install.as_mut(), &view),
                    other => {
                        if install.is_none() {
                            if let Some(choices) = parse_start(other) {
                                match start(choices) {
                                    Ok(inst) => install = Some(inst),
                                    Err(err) => {
                                        let msg = Value::String(err.to_string()).to_string();
                                        let _ = view.evaluate_script(&format!("window.aszFail({msg})"));
                                    }
                                }
                            }
                        }
                    }
                },
                Event::WindowEvent { event: WindowEvent::CloseRequested, .. } => {
                    quit = close_requested(install.as_mut(), &view);
                }
                _ => {}
            }
            if quit {
                code = install.as_ref().map_or(2, |i| crate::exit_code(i.final_phase.as_deref(), i.died));
                *control_flow = ControlFlow::Exit;
            }
        });
        drop(view);
        drop(window);
        if let Some(inst) = install {
            let _ = fs::remove_dir_all(&inst.work);
        }
        code
    }

    fn build_window(event_loop: &tao::event_loop::EventLoop<UserEvent>) -> Result<Window, String> {
        let size = LogicalSize::new(WIDTH, HEIGHT);
        let icon = Icon::from_rgba(ICON_RGBA.to_vec(), 64, 64).ok();
        let window = WindowBuilder::new()
            .with_title("Asenaizer Setup")
            .with_inner_size(size)
            .with_min_inner_size(size)
            .with_max_inner_size(size)
            .with_resizable(false)
            .with_decorations(false)
            .with_window_icon(icon)
            .with_visible(false)
            .build(event_loop)
            .map_err(|e| e.to_string())?;
        // the centre of the screen (Wayland compositors place windows themselves and ignore this)
        if let Some(monitor) = window.current_monitor() {
            let (m, at, w) = (monitor.size(), monitor.position(), window.outer_size());
            let x = at.x + (m.width as i32 - w.width as i32) / 2;
            let y = at.y + (m.height as i32 - w.height as i32) / 2;
            window.set_outer_position(PhysicalPosition::new(x.max(at.x), y.max(at.y)));
        }
        Ok(window)
    }

    fn build_view(window: &Window, proxy: tao::event_loop::EventLoopProxy<UserEvent>) -> Result<WebView, String> {
        let page = PAGE.replace("{{ICON_SVG}}", ICON_SVG);
        let vbox = window.default_vbox().ok_or("no GTK container")?;
        WebViewBuilder::new()
            .with_html(page)
            .with_background_color(BG)
            .with_devtools(false)
            .with_ipc_handler(move |req| {
                let _ = proxy.send_event(UserEvent::Ipc(req.body().clone()));
            })
            // the page has no links; nothing may open or navigate elsewhere
            .with_new_window_req_handler(|_, _| wry::NewWindowResponse::Deny)
            .build_gtk(vbox)
            .map_err(|e| e.to_string())
    }

    fn show(window: &Window, shown: &mut bool) {
        if !*shown {
            *shown = true;
            window.set_visible(true);
            window.set_focus();
        }
    }

    /// Close button, Escape on a finished page, or the window manager. While the install runs it is cancelled
    /// (and rolled back) instead, like the Windows window; the window stays until the script reports.
    fn close_requested(install: Option<&mut Install>, view: &WebView) -> bool {
        let Some(inst) = install else { return true };
        if !inst.running() {
            return true;
        }
        inst.cancel();
        let _ = view.evaluate_script("window.aszCancelRequested()");
        false
    }

    #[derive(Debug, PartialEq, Eq)]
    pub(crate) struct Choices {
        pub startup: bool,
        pub desktop: bool,
        pub launch: bool,
    }

    pub(crate) fn parse_start(message: &str) -> Option<Choices> {
        let v: Value = serde_json::from_str(message).ok()?;
        if v.get("cmd")?.as_str()? != "start" {
            return None;
        }
        let flag = |key: &str, default: bool| v.get(key).and_then(Value::as_bool).unwrap_or(default);
        Some(Choices { startup: flag("startup", true), desktop: flag("desktop", false), launch: flag("launch", true) })
    }

    /// A fresh %TEMP%-style work dir, asz-setup-<8 hex>, readable by this user only.
    fn new_work_dir() -> std::io::Result<PathBuf> {
        use std::hash::{BuildHasher, Hasher};
        use std::os::unix::fs::DirBuilderExt;
        let base = std::env::temp_dir();
        for attempt in 0u32..32 {
            let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
            hasher.write_u128(SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_nanos()));
            hasher.write_u32(std::process::id());
            hasher.write_u32(attempt);
            let path = base.join(format!("asz-setup-{:08x}", hasher.finish() as u32));
            match fs::DirBuilder::new().mode(0o700).create(&path) {
                Ok(()) => return Ok(path),
                Err(e) if e.kind() == ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e),
            }
        }
        Err(std::io::Error::new(ErrorKind::AlreadyExists, "no free work dir name"))
    }

    fn start(choices: Choices) -> std::io::Result<Install> {
        let work = new_work_dir()?;
        let spawned = (|| {
            let script = work.join("install-linux.sh");
            fs::write(&script, SCRIPT)?;
            fs::write(work.join("fetch_linux_release.py"), FETCHER)?;
            fs::write(work.join("uninstall-linux.sh"), UNINSTALLER)?;
            fs::write(work.join("asenaizer-256.png"), ICON_PNG)?;
            let mut cmd = Command::new("bash");
            // the environment is inherited (ASZ_PREVIEW / ASZ_SOURCE pass through); the choices are always set here
            cmd.arg(&script)
                .current_dir(&work)
                .env("ASZ_DRIVER", &work)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            flag(&mut cmd, "ASZ_NO_STARTUP", !choices.startup);
            flag(&mut cmd, "ASZ_DESKTOP", choices.desktop);
            flag(&mut cmd, "ASZ_NO_LAUNCH", !choices.launch);
            cmd.spawn()
        })();
        match spawned {
            Ok(child) => Ok(Install { work, child, final_phase: None, exited_at: None, died: false }),
            Err(err) => {
                let _ = fs::remove_dir_all(&work);
                Err(err)
            }
        }
    }

    fn flag(cmd: &mut Command, name: &str, on: bool) {
        if on {
            cmd.env(name, "1");
        } else {
            cmd.env_remove(name);
        }
    }

    /// A JSON object from a file the script wrote whole (it renames a finished temp file into place).
    fn read_object(path: &Path) -> Option<Value> {
        let text = fs::read_to_string(path).ok()?;
        serde_json::from_str::<Value>(&text).ok().filter(Value::is_object)
    }

    /// Reads status.json and the progress.json it points to (only inside the work dir) and hands both to the page.
    fn poll(inst: &mut Install, view: &WebView) {
        if inst.final_phase.is_some() || inst.died {
            return;
        }
        let status = read_object(&inst.work.join("status.json"));
        let progress = status
            .as_ref()
            .and_then(|st| st.get("progress"))
            .and_then(Value::as_str)
            .map(PathBuf::from)
            .filter(|p| p.starts_with(&inst.work))
            .and_then(|p| read_object(&p));
        if let Some(phase) = status.as_ref().and_then(|st| st.get("phase")).and_then(Value::as_str) {
            if matches!(phase, "done" | "error" | "cancelled") {
                inst.final_phase = Some(phase.to_string());
            }
        }
        let js = |v: &Option<Value>| v.as_ref().map_or_else(|| "null".to_string(), Value::to_string);
        let _ = view.evaluate_script(&format!("window.aszUpdate({},{})", js(&status), js(&progress)));
        if inst.final_phase.is_some() {
            return;
        }
        // the script ended without a result (it was killed, or bash itself failed): give its last write a moment
        if let Ok(Some(exit)) = inst.child.try_wait() {
            let since = *inst.exited_at.get_or_insert_with(Instant::now);
            if since.elapsed() >= EXIT_GRACE {
                inst.died = true;
                let code = exit.code().map_or_else(|| "signal".to_string(), |c| c.to_string());
                let _ = view.evaluate_script(&format!("window.aszExited({})", Value::String(code)));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::exit_code;

    #[test]
    fn exit_codes_match_the_bootstrap_contract() {
        assert_eq!(exit_code(Some("done"), false), 0);
        assert_eq!(exit_code(Some("error"), false), 1);
        assert_eq!(exit_code(Some("cancelled"), false), 2);
        assert_eq!(exit_code(None, true), 1);
        assert_eq!(exit_code(None, false), 2);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn start_message_is_parsed_strictly() {
        use super::linux::{parse_start, Choices};
        assert_eq!(
            parse_start(r#"{"cmd":"start","startup":false,"desktop":true,"launch":false}"#),
            Some(Choices { startup: false, desktop: true, launch: false })
        );
        assert_eq!(parse_start(r#"{"cmd":"start"}"#), Some(Choices { startup: true, desktop: false, launch: true }));
        assert_eq!(parse_start(r#"{"cmd":"other"}"#), None);
        assert_eq!(parse_start("drag"), None);
    }
}
