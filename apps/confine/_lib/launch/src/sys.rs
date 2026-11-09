//! Thin wrappers over the Linux calls the launcher needs and std does not offer.

use std::ffi::{CString, OsStr, OsString};
use std::io;
use std::mem::MaybeUninit;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

pub fn uid() -> u32 {
    unsafe { libc::getuid() }
}

pub fn gid() -> u32 {
    unsafe { libc::getgid() }
}

pub fn pid() -> u32 {
    std::process::id()
}

/// The kernel gives the initial namespaces fixed inode numbers, PROC_PID_INIT_INO for pids.
pub fn in_initial_pid_namespace() -> bool {
    std::fs::metadata("/proc/self/ns/pid").map(|m| m.ino() == 0xEFFF_FFFC).unwrap_or(false)
}

fn cvt(r: libc::c_int) -> io::Result<libc::c_int> {
    if r < 0 { Err(io::Error::last_os_error()) } else { Ok(r) }
}

fn cstring(s: &OsStr) -> io::Result<CString> {
    CString::new(s.as_bytes()).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
}

pub fn random_u32() -> u32 {
    let mut buf = [0u8; 4];
    let mut filled = 0;
    while filled < buf.len() {
        let r = unsafe { libc::getrandom(buf[filled..].as_mut_ptr().cast(), buf.len() - filled, 0) };
        if r > 0 {
            filled += r as usize;
        }
    }
    u32::from_ne_bytes(buf)
}

/// The signals the launcher handles itself, through a signalfd in its wait loop.
pub fn handled_signals() -> libc::sigset_t {
    unsafe {
        let mut set = MaybeUninit::<libc::sigset_t>::zeroed().assume_init();
        libc::sigemptyset(&mut set);
        for sig in [libc::SIGINT, libc::SIGQUIT, libc::SIGTERM, libc::SIGHUP] {
            libc::sigaddset(&mut set, sig);
        }
        set
    }
}

/// Blocked before any thread starts, so every thread inherits the mask and the signals wait in the signalfd.
pub fn block(set: &libc::sigset_t) -> io::Result<()> {
    let r = unsafe { libc::pthread_sigmask(libc::SIG_BLOCK, set, std::ptr::null_mut()) };
    if r != 0 { Err(io::Error::from_raw_os_error(r)) } else { Ok(()) }
}

/// For pre_exec: children must start with the signals the launcher blocked deliverable again.
pub fn unblock_in_child(set: &libc::sigset_t) -> io::Result<()> {
    cvt(unsafe { libc::sigprocmask(libc::SIG_UNBLOCK, set, std::ptr::null_mut()) }).map(drop)
}

/// For pre_exec: helpers die with the launcher even when it is killed outright.
pub fn die_with_parent() -> io::Result<()> {
    cvt(unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL, 0, 0, 0) }).map(drop)
}

/// For pre_exec: places each source descriptor at its target number without close-on-exec, going through
/// fresh numbers first so a source that sits on another pair's target is not clobbered.
pub fn remap_fds(pairs: &[(RawFd, RawFd)]) -> io::Result<()> {
    let mut temps = [0 as RawFd; 8];
    for (i, (src, _)) in pairs.iter().enumerate() {
        temps[i] = cvt(unsafe { libc::fcntl(*src, libc::F_DUPFD_CLOEXEC, 100) })?;
    }
    for (i, (_, dst)) in pairs.iter().enumerate() {
        cvt(unsafe { libc::dup2(temps[i], *dst) })?;
        unsafe { libc::close(temps[i]) };
    }
    Ok(())
}

pub fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0 as RawFd; 2];
    cvt(unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) })?;
    Ok(unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) })
}

/// Opened without close-on-exec, for a descriptor handed to the program exec'd next.
pub fn open_inheritable(path: &OsStr, flags: libc::c_int) -> io::Result<RawFd> {
    let c = cstring(path)?;
    cvt(unsafe { libc::open(c.as_ptr(), flags) })
}

pub fn mkfifo(path: &Path) -> io::Result<()> {
    let c = cstring(path.as_os_str())?;
    cvt(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }).map(drop)
}

pub fn pidfd_open(pid: u32) -> io::Result<OwnedFd> {
    let r = unsafe { libc::syscall(libc::SYS_pidfd_open, pid as libc::pid_t, 0) };
    if r < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(unsafe { OwnedFd::from_raw_fd(r as RawFd) })
    }
}

pub fn signalfd(set: &libc::sigset_t) -> io::Result<OwnedFd> {
    let fd = cvt(unsafe { libc::signalfd(-1, set, libc::SFD_CLOEXEC) })?;
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

pub fn read_signal(fd: &OwnedFd) -> Option<i32> {
    let mut info = MaybeUninit::<libc::signalfd_siginfo>::zeroed();
    let size = std::mem::size_of::<libc::signalfd_siginfo>();
    let r = unsafe { libc::read(fd.as_raw_fd(), info.as_mut_ptr().cast(), size) };
    if r as usize == size { Some(unsafe { info.assume_init() }.ssi_signo as i32) } else { None }
}

/// Waits until one of the descriptors is readable and reports which.
pub fn poll_readable(fds: &[RawFd], timeout_ms: i32) -> io::Result<Vec<bool>> {
    let mut pfds: Vec<libc::pollfd> = fds.iter().map(|&fd| libc::pollfd { fd, events: libc::POLLIN, revents: 0 }).collect();
    loop {
        let r = unsafe { libc::poll(pfds.as_mut_ptr(), pfds.len() as libc::nfds_t, timeout_ms) };
        if r >= 0 {
            return Ok(pfds.iter().map(|p| p.revents != 0).collect());
        }
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    }
}

pub fn kill(pid: u32, sig: i32) {
    unsafe { libc::kill(pid as libc::pid_t, sig) };
}

/// Replaces this process. Rust ignores SIGPIPE for itself, and an exec'd program must not inherit that.
pub fn exec(program: &OsStr, args: &[OsString]) -> io::Error {
    let prog = match cstring(program) {
        Ok(p) => p,
        Err(e) => return e,
    };
    let mut cargs = Vec::with_capacity(args.len() + 1);
    cargs.push(prog.clone());
    for a in args {
        match cstring(a) {
            Ok(c) => cargs.push(c),
            Err(e) => return e,
        }
    }
    let mut ptrs: Vec<*const libc::c_char> = cargs.iter().map(|c| c.as_ptr()).collect();
    ptrs.push(std::ptr::null());
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
        libc::execvp(prog.as_ptr(), ptrs.as_ptr());
    }
    io::Error::last_os_error()
}

/// Usage: confine-launch seccomp-exec FILTER COMMAND [ARGS...]
/// Joins a running sandbox's filter, which confine enter applies to whatever it runs inside.
pub fn seccomp_exec(args: &[OsString]) -> i32 {
    if args.len() < 2 {
        eprintln!("usage: confine-launch seccomp-exec FILTER COMMAND [ARGS...]");
        return 2;
    }
    let bytes = match std::fs::read(&args[0]) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("confine: {}: {e}", Path::new(&args[0]).display());
            return 1;
        }
    };
    let insn = std::mem::size_of::<libc::sock_filter>();
    if bytes.is_empty() || bytes.len() % insn != 0 || bytes.len() / insn > libc::BPF_MAXINSNS as usize {
        eprintln!("confine: {} is not a BPF program", Path::new(&args[0]).display());
        return 1;
    }
    let mut filter: Vec<libc::sock_filter> = Vec::with_capacity(bytes.len() / insn);
    for chunk in bytes.chunks_exact(insn) {
        filter.push(libc::sock_filter {
            code: u16::from_ne_bytes([chunk[0], chunk[1]]),
            jt: chunk[2],
            jf: chunk[3],
            k: u32::from_ne_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]),
        });
    }
    let prog = libc::sock_fprog { len: filter.len() as u16, filter: filter.as_mut_ptr() };
    unsafe {
        if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0
            || libc::prctl(libc::PR_SET_SECCOMP, libc::SECCOMP_MODE_FILTER, &prog as *const _) < 0
        {
            eprintln!("confine: loading the filter: {}", io::Error::last_os_error());
            return 1;
        }
    }
    let e = exec(&args[1], &args[2..]);
    eprintln!("confine: {}: {e}", Path::new(&args[1]).display());
    127
}
