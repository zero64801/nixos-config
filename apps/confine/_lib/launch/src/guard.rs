//! Keeps an app that may create user namespaces from administering a network of its own.
//! A browser's sandbox puts its processes in namespaces it creates, and in a network namespace of its own a process is
//! the network's admin, which reaches traffic control, IPsec and device setup, old kernel code that needs no privilege
//! there. The browser wants the isolation and none of that, so it is closed here and the namespaces stay.

use crate::sys;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::MetadataExt;

type Insn = libc::sock_filter;

#[cfg(target_arch = "x86_64")]
const ARCH: Option<u32> = Some(0xC000_003E);
#[cfg(target_arch = "aarch64")]
const ARCH: Option<u32> = Some(0xC000_00B7);
#[cfg(target_arch = "riscv64")]
const ARCH: Option<u32> = Some(0xC000_00F3);
#[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64", target_arch = "riscv64")))]
const ARCH: Option<u32> = None;

const NR: u32 = 0;
const ARCH_AT: u32 = 4;

/// The kernel reads the arguments checked here as 32-bit, so only that half is compared and a stray high bit changes nothing.
const fn arg(n: u32) -> u32 {
    16 + 8 * n + if cfg!(target_endian = "big") { 4 } else { 0 }
}

/// Socket ioctls that only read, by number. The rest of the range sets up interfaces, routes, bridges and tunnels, or
/// like SIOCETHTOOL takes its command from memory the filter cannot see.
const READ_ONLY_IOCTLS: [u32; 20] = [
    0x8901, 0x8902, 0x8903, 0x8904, 0x8905, 0x8906, 0x8907, 0x8910, 0x8912, 0x8913, 0x8915, 0x8917, 0x8919, 0x891b, 0x891d, 0x8921, 0x8927,
    0x8933, 0x8942, 0x894b,
];
const SOCKET_IOCTLS: std::ops::Range<u32> = 0x8900..0x8a00;

/// MRT6_BASE, where IPv6 multicast routing starts and nothing else follows.
const IPV6_MULTICAST_ROUTING: u32 = 200;
const SOCK_TYPE_MASK: u32 = 0xf;

fn stmt(code: u32, k: u32) -> Insn {
    Insn { code: code as u16, jt: 0, jf: 0, k }
}

fn load(at: u32) -> Insn {
    stmt(libc::BPF_LD | libc::BPF_W | libc::BPF_ABS, at)
}

fn ret(action: u32) -> Insn {
    stmt(libc::BPF_RET | libc::BPF_K, action)
}

fn allow() -> Insn {
    ret(libc::SECCOMP_RET_ALLOW)
}

fn deny(errno: i32) -> Insn {
    ret(libc::SECCOMP_RET_ERRNO | errno as u32)
}

/// Runs BODY when the loaded value passes the test and skips it otherwise. Every body ends by returning, so what
/// follows still sees the value loaded before it.
fn when(test: u32, k: u32, mut body: Vec<Insn>) -> Vec<Insn> {
    assert!(body.len() <= u8::MAX as usize);
    let mut out = vec![Insn { code: (libc::BPF_JMP | test | libc::BPF_K) as u16, jt: 0, jf: body.len() as u8, k }];
    out.append(&mut body);
    out
}

fn when_eq(k: u32, body: Vec<Insn>) -> Vec<Insn> {
    when(libc::BPF_JEQ, k, body)
}

fn when_ge(k: u32, body: Vec<Insn>) -> Vec<Insn> {
    when(libc::BPF_JGE, k, body)
}

fn refuse_each(values: &[i32]) -> Vec<Insn> {
    values.iter().flat_map(|v| when_eq(*v as u32, vec![deny(libc::EPERM)])).collect()
}

/// A call decided on the argument at AT, allowed unless a rule refuses it.
fn decided_on(at: u32, rules: Vec<Insn>) -> Vec<Insn> {
    let mut body = vec![load(at)];
    body.extend(rules);
    body.push(allow());
    body
}

/// Each rule names something only a network's admin may do, which no app is in the sandbox's own network, so nothing
/// that works today depends on it.
fn program(arch: u32) -> Vec<Insn> {
    let mut p = vec![load(ARCH_AT)];
    // The app's filter decides what another ABI may do.
    p.push(Insn { code: (libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K) as u16, jt: 1, jf: 0, k: arch });
    p.push(allow());
    p.push(load(NR));
    // x32 numbers its calls apart from the ones named below.
    if cfg!(target_arch = "x86_64") {
        p.extend(when_ge(0x4000_0000, vec![deny(libc::ENOSYS)]));
    }

    let mut ours = when_ge(SOCKET_IOCTLS.end, vec![allow()]);
    for n in READ_ONLY_IOCTLS {
        ours.extend(when_eq(n, vec![allow()]));
    }
    ours.push(deny(libc::EPERM));
    p.extend(when_eq(libc::SYS_ioctl as u32, decided_on(arg(1), when_ge(SOCKET_IOCTLS.start, ours))));

    // Netlink carries nearly all of a network's administration, and the kernel ties a socket to the network it is made
    // in. Only the process outside can tell which one that is, so it decides. Raw sockets need the admin's rights too.
    let raw = || {
        let mut body = vec![load(arg(1)), stmt(libc::BPF_ALU | libc::BPF_AND | libc::BPF_K, SOCK_TYPE_MASK)];
        body.extend(when_eq(libc::SOCK_RAW as u32, vec![deny(libc::EPERM)]));
        body.push(allow());
        body
    };
    let mut families = when_eq(libc::AF_NETLINK as u32, vec![ret(libc::SECCOMP_RET_USER_NOTIF)]);
    families.extend(when_eq(libc::AF_INET as u32, raw()));
    families.extend(when_eq(libc::AF_INET6 as u32, raw()));
    p.extend(when_eq(libc::SYS_socket as u32, decided_on(arg(0), families)));

    // IPsec policy, multicast routing, TCP repair and buffers past the system limit.
    let mut ipv6 = refuse_each(&[libc::IPV6_IPSEC_POLICY, libc::IPV6_XFRM_POLICY]);
    ipv6.extend(when_ge(IPV6_MULTICAST_ROUTING, vec![deny(libc::EPERM)]));
    let option = |rules| decided_on(arg(2), rules);
    let mut levels = when_eq(libc::SOL_SOCKET as u32, option(refuse_each(&[libc::SO_SNDBUFFORCE, libc::SO_RCVBUFFORCE])));
    levels.extend(when_eq(libc::IPPROTO_IP as u32, option(refuse_each(&[libc::IP_IPSEC_POLICY, libc::IP_XFRM_POLICY]))));
    levels.extend(when_eq(libc::IPPROTO_IPV6 as u32, option(ipv6)));
    levels.extend(when_eq(libc::IPPROTO_TCP as u32, option(refuse_each(&[libc::TCP_REPAIR, libc::TCP_REPAIR_QUEUE, libc::TCP_REPAIR_OPTIONS, libc::TCP_REPAIR_WINDOW]))));
    p.extend(when_eq(libc::SYS_setsockopt as u32, decided_on(arg(1), levels)));

    p.push(allow());
    p
}

fn namespace_of(m: &std::fs::Metadata) -> (u64, u64) {
    (m.dev(), m.ino())
}

/// The reaper's half: loads the filter for the app to inherit and hands its listener out of the sandbox, together with
/// the network namespace the sandbox starts in. The app must never hold the listener, or it would answer for itself.
pub fn arm(socket: OwnedFd) -> io::Result<()> {
    let arch = ARCH.ok_or_else(|| io::Error::new(io::ErrorKind::Unsupported, "seccomp.userns is not supported on this architecture"))?;
    let home = std::fs::File::open("/proc/self/ns/net")?;
    let mut filter = program(arch);
    let prog = libc::sock_fprog { len: filter.len() as u16, filter: filter.as_mut_ptr() };
    let listener = unsafe {
        if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0 {
            return Err(io::Error::last_os_error());
        }
        let r = libc::syscall(libc::SYS_seccomp, libc::SECCOMP_SET_MODE_FILTER, libc::SECCOMP_FILTER_FLAG_NEW_LISTENER, &prog as *const libc::sock_fprog);
        if r < 0 {
            return Err(io::Error::last_os_error());
        }
        OwnedFd::from_raw_fd(r as i32)
    };
    sys::send_fds(socket.as_raw_fd(), &[listener.as_raw_fd(), home.as_raw_fd()])
}

/// The launcher's half, on a thread of its own so a slow answer never holds up the launch. Without it the kernel
/// refuses the calls, and so does every way this can fail.
pub fn serve(socket: OwnedFd) {
    let Ok([listener, home]) = sys::recv_fds::<2>(socket.as_raw_fd()) else { return };
    drop(socket);
    // Held open for as long as it is compared against, so the kernel cannot give its number to another namespace.
    let home = std::fs::File::from(home);
    let Ok(home_id) = home.metadata().map(|m| namespace_of(&m)) else { return };
    // Anything but a waiting call means every process under the filter is gone.
    while sys::poll_events(listener.as_raw_fd()).is_ok_and(|events| events & libc::POLLIN != 0) && answer(&listener, home_id) {}
}

/// False once the listener is of no more use.
fn answer(listener: &OwnedFd, home: (u64, u64)) -> bool {
    let mut request: libc::seccomp_notif = unsafe { std::mem::zeroed() };
    if unsafe { libc::ioctl(listener.as_raw_fd(), libc::SECCOMP_IOCTL_NOTIF_RECV, &mut request) } != 0 {
        // A caller killed while it waited leaves nothing to read.
        return matches!(io::Error::last_os_error().raw_os_error(), Some(libc::ENOENT | libc::EINTR));
    }
    // A thread cannot leave its network namespace while it waits here and nothing else can move it, so the namespace
    // read now is the one the socket would be made in. The id check rules out that the number went to another process
    // meanwhile.
    let namespace = std::fs::metadata(format!("/proc/{}/ns/net", request.pid)).map(|m| namespace_of(&m));
    let still_waiting = unsafe { libc::ioctl(listener.as_raw_fd(), libc::SECCOMP_IOCTL_NOTIF_ID_VALID, &request.id) } == 0;
    let mut response: libc::seccomp_notif_resp = unsafe { std::mem::zeroed() };
    response.id = request.id;
    if still_waiting && namespace.is_ok_and(|n| n == home) {
        // There the caller is no admin and the kernel's own checks hold. The filter only looked at plain numbers,
        // which the caller cannot change under it the way it could change memory.
        response.flags = libc::SECCOMP_USER_NOTIF_FLAG_CONTINUE as u32;
    } else {
        response.error = -libc::EPERM;
    }
    unsafe { libc::ioctl(listener.as_raw_fd(), libc::SECCOMP_IOCTL_NOTIF_SEND, &response) };
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALLOW: u32 = libc::SECCOMP_RET_ALLOW;
    const ASK: u32 = libc::SECCOMP_RET_USER_NOTIF;
    const EPERM: u32 = libc::SECCOMP_RET_ERRNO | libc::EPERM as u32;
    const ARCH: u32 = 0xC000_003E;

    /// Runs the program the way the kernel would, for the instructions it uses.
    fn run(p: &[Insn], arch: u32, nr: i64, args: [u64; 3]) -> u32 {
        let word = |at: u32| match at {
            0 => nr as u32,
            4 => arch,
            at => {
                let value = args[((at - 16) / 8) as usize];
                if (at - 16) % 8 == arg(0) - 16 { value as u32 } else { (value >> 32) as u32 }
            }
        };
        let (mut a, mut pc) = (0u32, 0usize);
        loop {
            let i = p[pc];
            pc += 1;
            let class = i.code as u32 & 0x07;
            if class == libc::BPF_LD {
                a = word(i.k);
            } else if class == libc::BPF_ALU {
                a &= i.k;
            } else if class == libc::BPF_RET {
                return i.k;
            } else {
                let taken = if i.code as u32 & 0xf0 == libc::BPF_JEQ { a == i.k } else { a >= i.k };
                pc += if taken { i.jt } else { i.jf } as usize;
            }
        }
    }

    fn verdict(nr: i64, args: [u64; 3]) -> u32 {
        run(&program(ARCH), ARCH, nr, args)
    }

    #[test]
    fn every_jump_lands_inside_the_program() {
        let p = program(ARCH);
        assert!(p.len() <= libc::BPF_MAXINSNS as usize);
        for (at, i) in p.iter().enumerate() {
            if i.code as u32 & 0x07 == libc::BPF_JMP {
                assert!(at + 1 + (i.jt.max(i.jf) as usize) < p.len(), "instruction {at} jumps past the end");
            }
        }
        assert_eq!(p.last().map(|i| i.code as u32 & 0x07), Some(libc::BPF_RET));
    }

    #[test]
    fn netlink_goes_to_the_launcher_and_other_sockets_do_not() {
        assert_eq!(verdict(libc::SYS_socket, [libc::AF_NETLINK as u64, libc::SOCK_RAW as u64, 0]), ASK);
        assert_eq!(verdict(libc::SYS_socket, [libc::AF_NETLINK as u64 | 1 << 32, libc::SOCK_RAW as u64, 0]), ASK);
        assert_eq!(verdict(libc::SYS_socket, [libc::AF_UNIX as u64, libc::SOCK_STREAM as u64, 0]), ALLOW);
        assert_eq!(verdict(libc::SYS_socket, [libc::AF_INET as u64, (libc::SOCK_STREAM | libc::SOCK_CLOEXEC) as u64, 0]), ALLOW);
        assert_eq!(verdict(libc::SYS_socket, [libc::AF_INET6 as u64, libc::SOCK_DGRAM as u64, 0]), ALLOW);
    }

    #[test]
    fn raw_sockets_are_refused() {
        for family in [libc::AF_INET, libc::AF_INET6] {
            assert_eq!(verdict(libc::SYS_socket, [family as u64, libc::SOCK_RAW as u64, 0]), EPERM);
            assert_eq!(verdict(libc::SYS_socket, [family as u64, (libc::SOCK_RAW | libc::SOCK_NONBLOCK) as u64 | 1 << 40, 0]), EPERM);
        }
    }

    #[test]
    fn socket_ioctls_only_read() {
        let ioctl = |n: u64| verdict(libc::SYS_ioctl, [3, n, 0]);
        // SIOCGIFFLAGS, SIOCGIFINDEX, and FIONREAD and a DRM call from outside the range.
        for n in [0x8913, 0x8933, 0x541b, 0xc010_6400, 0x88ff, 0x8a00] {
            assert_eq!(ioctl(n), ALLOW, "{n:#x}");
        }
        // SIOCADDRT, SIOCSIFFLAGS, SIOCETHTOOL, SIOCBRADDBR, SIOCDEVPRIVATE, and SIOCSIFFLAGS behind a stray high bit.
        for n in [0x890b, 0x8914, 0x8946, 0x89a0, 0x89f0, 0x8914 | 1 << 32] {
            assert_eq!(ioctl(n), EPERM, "{n:#x}");
        }
    }

    #[test]
    fn admin_socket_options_are_refused() {
        let set = |level: i32, option: i32| verdict(libc::SYS_setsockopt, [3, level as u64, option as u64]);
        assert_eq!(set(libc::IPPROTO_IP, libc::IP_XFRM_POLICY), EPERM);
        assert_eq!(set(libc::IPPROTO_IPV6, libc::IPV6_XFRM_POLICY), EPERM);
        assert_eq!(set(libc::IPPROTO_IPV6, 200), EPERM);
        assert_eq!(set(libc::IPPROTO_TCP, libc::TCP_REPAIR), EPERM);
        assert_eq!(set(libc::SOL_SOCKET, libc::SO_RCVBUFFORCE), EPERM);
        assert_eq!(set(libc::SOL_SOCKET, libc::SO_RCVBUF), ALLOW);
        assert_eq!(set(libc::IPPROTO_TCP, libc::TCP_NODELAY), ALLOW);
        assert_eq!(set(libc::IPPROTO_IPV6, libc::IPV6_V6ONLY), ALLOW);
        assert_eq!(set(libc::IPPROTO_IP, libc::IP_TOS), ALLOW);
    }

    #[test]
    fn other_calls_and_other_abis_pass() {
        assert_eq!(verdict(libc::SYS_read, [0, 0, 0]), ALLOW);
        assert_eq!(verdict(libc::SYS_getsockopt, [3, libc::IPPROTO_IP as u64, libc::IP_XFRM_POLICY as u64]), ALLOW);
        assert_eq!(run(&program(ARCH), 0x4000_0003, libc::SYS_socket, [libc::AF_NETLINK as u64, 0, 0]), ALLOW);
    }
}
