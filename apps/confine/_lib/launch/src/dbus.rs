//! Session bus calls: the app's systemd scope, the accessibility bus address, document portal exports and notifications.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::os::fd::AsFd;
use std::ffi::OsString;
use std::os::unix::ffi::OsStringExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::{Fd, OwnedValue, Value};

/// Connected on first use, since most launches only need the bus for the scope.
#[derive(Default)]
pub struct Bus {
    conn: Option<Connection>,
    tried: bool,
}

impl Bus {
    pub fn get(&mut self) -> Option<&Connection> {
        if !self.tried {
            self.tried = true;
            self.conn = Connection::session().ok();
        }
        self.conn.as_ref()
    }
}

fn bytes(v: &str) -> Result<u64, String> {
    if v == "infinity" {
        return Ok(u64::MAX);
    }
    let (num, mult) = match v.chars().last() {
        Some('K') => (&v[..v.len() - 1], 1u64 << 10),
        Some('M') => (&v[..v.len() - 1], 1 << 20),
        Some('G') => (&v[..v.len() - 1], 1 << 30),
        Some('T') => (&v[..v.len() - 1], 1 << 40),
        _ => (v, 1),
    };
    num.parse::<u64>().ok().and_then(|n| n.checked_mul(mult)).ok_or_else(|| format!("{v} is not a size"))
}

fn number(v: &str) -> Result<u64, String> {
    if v == "infinity" {
        return Ok(u64::MAX);
    }
    v.parse::<u64>().map_err(|_| format!("{v} is not a number"))
}

/// systemd-run's spellings, turned into the typed properties StartTransientUnit takes.
fn resource(key: &str, value: &str) -> Result<(String, Value<'static>), String> {
    Ok(match key {
        "MemoryMax" | "MemoryHigh" | "MemorySwapMax" | "MemoryLow" | "MemoryMin" => (key.into(), bytes(value)?.into()),
        "CPUWeight" | "StartupCPUWeight" | "IOWeight" | "StartupIOWeight" | "TasksMax" => (key.into(), number(value)?.into()),
        "CPUQuota" => {
            let percent = value.strip_suffix('%').and_then(|p| p.parse::<u64>().ok()).ok_or_else(|| format!("CPUQuota {value} is not a percentage"))?;
            ("CPUQuotaPerSecUSec".into(), (percent * 10_000).into())
        }
        _ => return Err(format!("resource {key} is not supported")),
    })
}

pub enum ScopeError {
    /// No user manager answers on this bus, as from inside a sandbox, where the proxy hides it.
    Unreachable,
    Refused(String),
}

impl std::fmt::Display for ScopeError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            ScopeError::Unreachable => f.write_str("no user manager is reachable"),
            ScopeError::Refused(e) => f.write_str(e),
        }
    }
}

const UNREACHABLE: [&str; 3] =
    ["org.freedesktop.DBus.Error.ServiceUnknown", "org.freedesktop.DBus.Error.NameHasNoOwner", "org.freedesktop.DBus.Error.AccessDenied"];

/// Asks the user manager for a scope holding this process, as Flatpak does for app-flatpak-*.scope.
pub fn start_scope(conn: &Connection, unit: &str, description: &str, resources: &[(String, String)], delegate: bool) -> Result<(), ScopeError> {
    let mut props: Vec<(String, Value)> = vec![
        ("Description".into(), description.into()),
        // 0 is the caller as the bus saw it connect, which stays right from inside a pid namespace.
        ("PIDs".into(), vec![0u32].into()),
        ("CollectMode".into(), "inactive-or-failed".into()),
    ];
    if delegate {
        // systemd only moves further processes into a delegated unit. An empty controller list delegates no resource
        // control, and nothing in the sandbox could use it anyway, it has a cgroup namespace of its own and no cgroupfs.
        props.push(("DelegateControllers".into(), Vec::<String>::new().into()));
    }
    for (k, v) in resources {
        props.push(resource(k, v).map_err(ScopeError::Refused)?);
    }
    let aux: Vec<(String, Vec<(String, Value)>)> = Vec::new();
    conn.call_method(
        Some("org.freedesktop.systemd1"),
        "/org/freedesktop/systemd1",
        Some("org.freedesktop.systemd1.Manager"),
        "StartTransientUnit",
        &(unit, "fail", props, aux),
    )
    .map_err(|e| match &e {
        zbus::Error::MethodError(name, _, _) if UNREACHABLE.contains(&name.as_str()) => ScopeError::Unreachable,
        _ => ScopeError::Refused(e.to_string()),
    })?;
    Ok(())
}

/// Moves processes of this user into a delegated scope.
pub fn attach_to_scope(conn: &Connection, unit: &str, pids: &[u32]) -> Result<(), String> {
    conn.call_method(
        Some("org.freedesktop.systemd1"),
        "/org/freedesktop/systemd1",
        Some("org.freedesktop.systemd1.Manager"),
        "AttachProcessesToUnit",
        &(unit, "", pids),
    )
    .map(drop)
    .map_err(|e| e.to_string())
}

/// Children forked before systemd moves this process would stay outside the scope, so this waits for the move.
pub fn wait_for_scope(unit: &str) -> bool {
    let needle = format!("/{unit}");
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if let Ok(c) = std::fs::read_to_string("/proc/self/cgroup") {
            if c.lines().any(|l| l.trim_end().ends_with(&needle)) {
                return true;
            }
        }
        std::thread::sleep(Duration::from_micros(500));
    }
    false
}

pub fn a11y_address(conn: &Connection) -> Option<String> {
    let reply = conn.call_method(Some("org.a11y.Bus"), "/org/a11y/bus", Some("org.a11y.Bus"), "GetAddress", &()).ok()?;
    reply.body().deserialize::<String>().ok()
}

const DOCUMENTS: &str = "org.freedesktop.portal.Documents";
const DOCUMENTS_PATH: &str = "/org/freedesktop/portal/documents";
const ADD_REUSE_EXISTING: u32 = 1 << 0;
const ADD_DIRECTORY: u32 = 1 << 3;

/// Where the document portal's filesystem is mounted, None without a document portal. The call starts the portal.
pub fn documents_mount_point(conn: &Connection) -> Option<PathBuf> {
    let reply = conn.call_method(Some(DOCUMENTS), DOCUMENTS_PATH, Some(DOCUMENTS), "GetMountPoint", &()).ok()?;
    let mut path: Vec<u8> = reply.body().deserialize().ok()?;
    path.retain(|byte| *byte != 0);
    Some(PathBuf::from(OsString::from_vec(path)))
}

/// Exports one file or folder for the app with read and write access and returns the document id, as flatpak run --file-forwarding does.
pub fn add_document(conn: &Connection, app_id: &str, path: &Path) -> Result<String, String> {
    let file: File = OpenOptions::new().read(true).custom_flags(libc::O_PATH).open(path).map_err(|e| e.to_string())?;
    let is_dir = file.metadata().map_err(|e| e.to_string())?.is_dir();
    let proxy = Proxy::new(conn, DOCUMENTS, DOCUMENTS_PATH, DOCUMENTS).map_err(|e| e.to_string())?;
    let version: u32 = proxy.get_property("version").map_err(|e| format!("no document portal: {e}"))?;
    // AddFull arrived in version 2 and folders in version 4, Flatpak draws the same lines.
    if version < 2 || (is_dir && version < 4) {
        return Err(format!("document portal version {version} is too old"));
    }
    let flags = ADD_REUSE_EXISTING | if is_dir { ADD_DIRECTORY } else { 0 };
    let fds = vec![Fd::from(file.as_fd())];
    let reply = conn
        .call_method(Some(DOCUMENTS), DOCUMENTS_PATH, Some(DOCUMENTS), "AddFull", &(fds, flags, app_id, vec!["read", "write"]))
        .map_err(|e| e.to_string())?;
    let (ids, _extra): (Vec<String>, HashMap<String, OwnedValue>) = reply.body().deserialize().map_err(|e| e.to_string())?;
    ids.into_iter().next().ok_or_else(|| "the document portal returned no id".into())
}

pub fn notify(conn: &Connection, summary: &str, body: &str) {
    let hints: HashMap<&str, Value> = HashMap::new();
    let _ = conn.call_method(
        Some("org.freedesktop.Notifications"),
        "/org/freedesktop/Notifications",
        Some("org.freedesktop.Notifications"),
        "Notify",
        &("confine", 0u32, "dialog-warning", summary, body, Vec::<&str>::new(), hints, -1i32),
    );
}

#[cfg(test)]
mod tests {
    use super::resource;
    use zbus::zvariant::Value;

    fn ok(key: &str, value: &str) -> (String, Value<'static>) {
        resource(key, value).unwrap()
    }

    #[test]
    fn sizes_take_systemd_run_suffixes() {
        assert_eq!(ok("MemoryMax", "4G"), ("MemoryMax".into(), Value::from(4u64 << 30)));
        assert_eq!(ok("MemoryHigh", "512M"), ("MemoryHigh".into(), Value::from(512u64 << 20)));
        assert_eq!(ok("MemorySwapMax", "1024"), ("MemorySwapMax".into(), Value::from(1024u64)));
        assert_eq!(ok("MemoryMax", "infinity"), ("MemoryMax".into(), Value::from(u64::MAX)));
        assert!(resource("MemoryMax", "4g").is_err());
        assert!(resource("MemoryMax", "99999999999T").is_err());
    }

    #[test]
    fn cpu_quota_becomes_microseconds_per_second() {
        assert_eq!(ok("CPUQuota", "50%"), ("CPUQuotaPerSecUSec".into(), Value::from(500_000u64)));
        assert_eq!(ok("CPUQuota", "200%"), ("CPUQuotaPerSecUSec".into(), Value::from(2_000_000u64)));
        assert!(resource("CPUQuota", "50").is_err());
    }

    #[test]
    fn numbers_and_unknown_keys() {
        assert_eq!(ok("TasksMax", "500"), ("TasksMax".into(), Value::from(500u64)));
        assert!(resource("TasksMax", "lots").is_err());
        assert!(resource("ExecStart", "/bin/sh").is_err());
    }
}
