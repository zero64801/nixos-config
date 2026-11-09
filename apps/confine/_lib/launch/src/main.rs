//! confine's launcher. Each app's wrapper is a script whose interpreter is this binary, naming the app's config.

mod config;
mod dbus;
mod launch;
mod sys;
mod wayland;

use std::ffi::OsString;

fn main() {
    let args: Vec<OsString> = std::env::args_os().collect();
    let code = match args.get(1).and_then(|a| a.to_str()) {
        Some("--inner") => launch::inner(&args[2..]),
        Some("seccomp-exec") => sys::seccomp_exec(&args[2..]),
        Some(_) => launch::run(&args[1..]),
        None => {
            eprintln!("usage: confine-launch SCRIPT [COMMAND] [ARGS...]");
            2
        }
    };
    std::process::exit(code);
}
