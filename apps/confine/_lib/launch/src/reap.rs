//! The sandbox's pid 1.
//! bwrap and pasta end when it does, so the sandbox lasts until its last process ends, as Flatpak's does, rather than dying with an app's first process when that one only starts the real program and exits.

use crate::{guard, sys};
use std::ffi::OsString;
use std::fs::File;
use std::io::Write;
use std::os::fd::{FromRawFd, OwnedFd, RawFd};
use std::path::Path;
use std::process::Command;

/// Usage: confine-launch --reap STATUS_FD|- GUARD_FD|- COMMAND [ARGS...]
/// Exits as the app did once nothing is left.
/// When the app ends with other processes still running, its status goes out on STATUS_FD right away, so the launch can return then as `flatpak run` does.
/// With - in its place the sandbox ends with the app, since the kernel kills what is left when pid 1 exits.
/// GUARD_FD is the socket the namespace guard hands its listener out on, - for an app that cannot create namespaces.
pub fn reap(args: &[OsString]) -> i32 {
    let (Some(status), Some(guard), Some(program)) = (args.first().and_then(|a| a.to_str()), args.get(1).and_then(|a| a.to_str()), args.get(2)) else {
        warn!("usage: confine-launch --reap STATUS_FD|- GUARD_FD|- COMMAND [ARGS...]");
        return 2;
    };
    let linger = status != "-";
    // Kept from the app, which would otherwise hold the launcher's wait open.
    let status_out = status.parse::<RawFd>().ok().and_then(|fd| sys::set_cloexec(fd).ok().map(|()| unsafe { File::from_raw_fd(fd) }));
    // bwrap and pasta got a pipe of the launcher's in place of the caller's stdin, stdout and stderr, which arrive here for the app.
    sys::adopt_stdio(crate::launch::STDIO_FD);
    // bwrap and pasta ran with the terminal's interrupts blocked so that Ctrl+C is the app's to answer, and the app starts with none.
    sys::unblock_all();
    // pid 1 inherits orphans anyway, this also holds where the reaper is not pid 1.
    let _ = sys::set_child_subreaper();
    // Taken from the app whether or not the guard comes up, and an app without its guard does not start.
    if let Ok(fd) = guard.parse::<RawFd>() {
        if let Err(e) = guard::arm(unsafe { OwnedFd::from_raw_fd(fd) }) {
            warn!("confine: the namespace guard: {e}");
            return 1;
        }
    }
    let app = match Command::new(program).args(&args[3..]).spawn() {
        Ok(child) => child.id() as libc::pid_t,
        Err(e) => {
            warn!("confine: {}: {e}", Path::new(program).display());
            return 127;
        }
    };
    let status = loop {
        match sys::waitpid(-1, 0) {
            Ok((pid, status)) if pid == app => break status,
            Ok(_) => {}
            Err(e) => {
                warn!("confine: waiting for the app: {e}");
                return 1;
            }
        }
    };
    let code = sys::exit_code(status);
    if linger && others_running() {
        if let Some(mut out) = status_out {
            let _ = out.write_all(&[code as u8]);
        }
        // Whatever runs on in here could open the caller's terminal through /proc/1/fd as long as this process holds it.
        sys::release_stdio();
        while sys::waitpid(-1, 0).is_ok() {}
    }
    code
}

/// The app's children were handed to this process before the app became waitable, so none are missed.
fn others_running() -> bool {
    loop {
        match sys::waitpid(-1, libc::WNOHANG) {
            Ok((0, _)) => return true,
            Ok(_) => {}
            Err(_) => return false,
        }
    }
}
