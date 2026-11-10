//! confine's launcher. Each app's wrapper is a script whose interpreter is this binary, naming the app's config.

/// eprintln! panics once stderr is gone, as when the terminal that started an app closes, and a panic aborts before the cleanup.
macro_rules! warn {
    ($($t:tt)*) => {{
        use std::io::Write as _;
        let _ = writeln!(std::io::stderr(), $($t)*);
    }};
}

mod config;
mod dbus;
mod guard;
mod launch;
mod reap;
mod sys;
mod wayland;

use std::ffi::OsString;

fn main() {
    let args: Vec<OsString> = std::env::args_os().collect();
    let code = match args.get(1).and_then(|a| a.to_str()) {
        Some("--inner") => launch::inner(&args[2..]),
        Some("--reap") => reap::reap(&args[2..]),
        Some("seccomp-exec") => sys::seccomp_exec(&args[2..]),
        Some(_) => launch::run(&args[1..]),
        None => {
            warn!("usage: confine-launch SCRIPT [COMMAND] [ARGS...]");
            2
        }
    };
    std::process::exit(code);
}
