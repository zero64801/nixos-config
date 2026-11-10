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

/// The signal this process gets when its parent ends, 0 for none.
pub fn signal_on_parent_death(sig: i32) -> io::Result<()> {
    cvt(unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, sig, 0, 0, 0) }).map(drop)
}

/// For pre_exec: helpers die with the launcher even when it is killed outright.
pub fn die_with_parent() -> io::Result<()> {
    signal_on_parent_death(libc::SIGKILL)
}

pub fn parent_pid() -> u32 {
    unsafe { libc::getppid() as u32 }
}

/// Only stdin, stdout and stderr belong in a sandbox, whatever else the caller left open would be handed over with them.
pub fn close_inherited() -> io::Result<()> {
    let r = unsafe { libc::syscall(libc::SYS_close_range, 3 as libc::c_uint, libc::c_uint::MAX, 0 as libc::c_uint) };
    if r < 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
}

pub fn process_group() -> libc::pid_t {
    unsafe { libc::getpgrp() }
}

pub fn own_process_group() -> io::Result<()> {
    cvt(unsafe { libc::setpgid(0, 0) }).map(drop)
}

/// Whether this process is the foreground job of its controlling terminal, which reads from and signals that group alone.
pub fn in_terminal_foreground() -> bool {
    let fd = unsafe { libc::open(c"/dev/tty".as_ptr(), libc::O_RDONLY | libc::O_NOCTTY | libc::O_CLOEXEC) };
    if fd < 0 {
        return false;
    }
    let foreground = unsafe { libc::tcgetpgrp(fd) };
    unsafe { libc::close(fd) };
    foreground == process_group()
}

fn terminal_stop() -> libc::sigset_t {
    unsafe {
        let mut set = MaybeUninit::<libc::sigset_t>::zeroed().assume_init();
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGTTOU);
        set
    }
}

/// A terminal set to tostop stops background writers, and a blocked SIGTTOU lets the write through instead.
pub fn block_terminal_stop() -> io::Result<()> {
    block(&terminal_stop())
}

/// bwrap and pasta stand between the launcher and the app in the terminal's foreground job, and Ctrl+C reaches them
/// all. Dying of it, they would take along an app that handles the interrupt itself, so they run with the terminal's
/// interrupts blocked and nothing else, and the reaper clears the mask for the app.
pub fn block_only_terminal_interrupts() -> io::Result<()> {
    unsafe {
        let mut set = MaybeUninit::<libc::sigset_t>::zeroed().assume_init();
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGINT);
        libc::sigaddset(&mut set, libc::SIGQUIT);
        cvt(libc::sigprocmask(libc::SIG_SETMASK, &set, std::ptr::null_mut())).map(drop)
    }
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

/// Places a descriptor at a number a later program was told in advance, still inheritable.
pub fn move_fd(fd: RawFd, target: RawFd) -> io::Result<()> {
    if fd != target {
        cvt(unsafe { libc::dup2(fd, target) })?;
        unsafe { libc::close(fd) };
    }
    Ok(())
}

pub fn set_cloexec(fd: RawFd) -> io::Result<()> {
    cvt(unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) }).map(drop)
}

/// For the app, which starts with every signal deliverable whatever the programs before it had blocked.
pub fn unblock_all() {
    unsafe {
        let mut set = MaybeUninit::<libc::sigset_t>::zeroed().assume_init();
        libc::sigemptyset(&mut set);
        libc::sigprocmask(libc::SIG_SETMASK, &set, std::ptr::null_mut());
    }
}

pub fn dup_cloexec(fd: RawFd) -> io::Result<OwnedFd> {
    let r = cvt(unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 3) })?;
    Ok(unsafe { OwnedFd::from_raw_fd(r) })
}

pub fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    let flags = cvt(unsafe { libc::fcntl(fd, libc::F_GETFL) })?;
    cvt(unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) }).map(drop)
}

/// Reads what is there without waiting, None once every writer is gone.
pub fn read_available(fd: RawFd, buf: &mut [u8]) -> Option<usize> {
    let r = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
    match r {
        0 => None,
        n if n > 0 => Some(n as usize),
        _ => Some(0),
    }
}

const FD_BYTES: usize = std::mem::size_of::<RawFd>();

/// Hands descriptors to the process on the other end of a unix socket, the one way past a program that closes what it inherits.
pub fn send_fds(socket: RawFd, fds: &[RawFd]) -> io::Result<()> {
    let mut control = [0u64; 8];
    let mut byte = 0u8;
    let mut iov = libc::iovec { iov_base: (&mut byte as *mut u8).cast(), iov_len: 1 };
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.as_mut_ptr().cast();
    msg.msg_controllen = unsafe { libc::CMSG_SPACE((fds.len() * FD_BYTES) as u32) } as _;
    unsafe {
        let header = libc::CMSG_FIRSTHDR(&msg);
        (*header).cmsg_level = libc::SOL_SOCKET;
        (*header).cmsg_type = libc::SCM_RIGHTS;
        (*header).cmsg_len = libc::CMSG_LEN((fds.len() * FD_BYTES) as u32) as _;
        std::ptr::copy_nonoverlapping(fds.as_ptr().cast::<u8>(), libc::CMSG_DATA(header), fds.len() * FD_BYTES);
    }
    let r = unsafe { libc::sendmsg(socket, &msg, libc::MSG_NOSIGNAL) };
    if r < 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
}

/// The other side of send_fds, for a message of exactly N descriptors. They arrive close-on-exec, to be placed where the next program expects them.
pub fn recv_fds<const N: usize>(socket: RawFd) -> io::Result<[OwnedFd; N]> {
    let mut control = [0u64; 8];
    let mut byte = 0u8;
    let mut iov = libc::iovec { iov_base: (&mut byte as *mut u8).cast(), iov_len: 1 };
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.as_mut_ptr().cast();
    msg.msg_controllen = std::mem::size_of_val(&control) as _;
    let r = loop {
        let r = unsafe { libc::recvmsg(socket, &mut msg, libc::MSG_CMSG_CLOEXEC) };
        if r >= 0 || io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            break r;
        }
    };
    if r < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut raw = [-1 as RawFd; N];
    let header = unsafe { libc::CMSG_FIRSTHDR(&msg) };
    let complete = !header.is_null()
        && unsafe { (*header).cmsg_level == libc::SOL_SOCKET && (*header).cmsg_type == libc::SCM_RIGHTS }
        && unsafe { (*header).cmsg_len } as usize == unsafe { libc::CMSG_LEN((raw.len() * FD_BYTES) as u32) } as usize;
    if !complete {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "no descriptors arrived"));
    }
    unsafe { std::ptr::copy_nonoverlapping(libc::CMSG_DATA(header), raw.as_mut_ptr().cast::<u8>(), raw.len() * FD_BYTES) };
    Ok(raw.map(|fd| unsafe { OwnedFd::from_raw_fd(fd) }))
}

/// Takes the three descriptors at FIRST and up as stdin, stdout and stderr, when the launcher passed them there.
pub fn adopt_stdio(first: RawFd) {
    for i in 0..3 {
        if unsafe { libc::dup2(first + i, i) } >= 0 {
            unsafe { libc::close(first + i) };
        }
    }
}

/// Points stdin, stdout and stderr at /dev/null, for a process that outlives its use for them.
pub fn release_stdio() {
    if let Ok(null) = std::fs::OpenOptions::new().read(true).write(true).open("/dev/null") {
        for fd in 0..3 {
            unsafe { libc::dup2(null.as_raw_fd(), fd) };
        }
    }
}

pub fn set_child_subreaper() -> io::Result<()> {
    cvt(unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) }).map(drop)
}

/// Only sound while a single thread runs, which lets the child carry on as an ordinary program.
pub fn fork() -> io::Result<libc::pid_t> {
    cvt(unsafe { libc::fork() })
}

/// Returns the pid and raw status, or pid 0 under WNOHANG while children still run.
pub fn waitpid(pid: libc::pid_t, flags: libc::c_int) -> io::Result<(libc::pid_t, libc::c_int)> {
    let mut status = 0;
    loop {
        let r = unsafe { libc::waitpid(pid, &mut status, flags) };
        if r >= 0 {
            return Ok((r, status));
        }
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    }
}

/// As shells and bwrap report it, 128 plus the signal for a process a signal ended.
pub fn exit_code(status: libc::c_int) -> i32 {
    if libc::WIFSIGNALED(status) { 128 + libc::WTERMSIG(status) } else { libc::WEXITSTATUS(status) }
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

/// Removes NAME from the folder DIR below ROOT. The kernel refuses every link on the way, so nothing outside ROOT can be reached.
pub fn unlink_beneath(root: &Path, dir: &Path, name: &OsStr) -> io::Result<()> {
    let root = std::fs::File::open(root)?;
    let mut how: libc::open_how = unsafe { std::mem::zeroed() };
    how.flags = (libc::O_PATH | libc::O_DIRECTORY | libc::O_CLOEXEC) as u64;
    how.resolve = libc::RESOLVE_BENEATH | libc::RESOLVE_NO_SYMLINKS;
    let dir = cstring(dir.as_os_str())?;
    let r = unsafe { libc::syscall(libc::SYS_openat2, root.as_raw_fd(), dir.as_ptr(), &how as *const libc::open_how, std::mem::size_of::<libc::open_how>()) };
    if r < 0 {
        return Err(io::Error::last_os_error());
    }
    let dir = unsafe { OwnedFd::from_raw_fd(r as RawFd) };
    let name = cstring(name)?;
    cvt(unsafe { libc::unlinkat(dir.as_raw_fd(), name.as_ptr(), 0) }).map(drop)
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

/// Waits until something happens on one descriptor and reports what, a hang-up included.
pub fn poll_events(fd: RawFd) -> io::Result<libc::c_short> {
    let mut pfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    loop {
        if unsafe { libc::poll(&mut pfd, 1, -1) } >= 0 {
            return Ok(pfd.revents);
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
        warn!("usage: confine-launch seccomp-exec FILTER COMMAND [ARGS...]");
        return 2;
    }
    let bytes = match std::fs::read(&args[0]) {
        Ok(b) => b,
        Err(e) => {
            warn!("confine: {}: {e}", Path::new(&args[0]).display());
            return 1;
        }
    };
    let insn = std::mem::size_of::<libc::sock_filter>();
    if bytes.is_empty() || bytes.len() % insn != 0 || bytes.len() / insn > libc::BPF_MAXINSNS as usize {
        warn!("confine: {} is not a BPF program", Path::new(&args[0]).display());
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
            warn!("confine: loading the filter: {}", io::Error::last_os_error());
            return 1;
        }
    }
    let e = exec(&args[1], &args[2..]);
    warn!("confine: {}: {e}", Path::new(&args[1]).display());
    127
}
