//! Builds the bubblewrap command line for one app from its config and runs it.

use crate::config::{Config, Home, Network, RuntimeDir, Workdir, X11};
use crate::{dbus, sys, wayland};
use nix::unistd::{Gid, Group, Uid, User};
use std::collections::{BTreeSet, HashSet};
use std::env;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Component, Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

type Res<T> = Result<T, String>;

macro_rules! fail {
    ($($t:tt)*) => { return Err(format!($($t)*)) };
}

/// The launcher identity and the per-app config, read from the wrapper script the kernel ran us for.
struct Script {
    config: PathBuf,
    target: Option<OsString>,
}

fn read_script(path: &OsStr) -> Res<Script> {
    let text = fs::read(path).map_err(|e| format!("{}: {e}", Path::new(path).display()))?;
    let mut config = None;
    let mut target = None;
    for line in text.split(|b| *b == b'\n').skip(1) {
        if let Some(v) = line.strip_prefix(b"config ") {
            config = Some(PathBuf::from(OsStr::from_bytes(v)));
        } else if let Some(v) = line.strip_prefix(b"target ") {
            target = Some(OsStr::from_bytes(v).to_os_string());
        }
    }
    Ok(Script { config: config.ok_or("the launcher script names no config")?, target })
}

fn env_nonempty(name: &str) -> Option<OsString> {
    env::var_os(name).filter(|v| !v.is_empty())
}

fn is_socket(p: &Path) -> bool {
    fs::metadata(p).map(|m| m.file_type().is_socket()).unwrap_or(false)
}

fn is_symlink(p: &Path) -> bool {
    fs::symlink_metadata(p).map(|m| m.file_type().is_symlink()).unwrap_or(false)
}

fn exists_or_link(p: &Path) -> bool {
    p.exists() || is_symlink(p)
}

fn mkdir_private(p: &Path) -> Res<()> {
    fs::create_dir_all(p).map_err(|e| format!("{}: {e}", p.display()))?;
    fs::set_permissions(p, fs::Permissions::from_mode(0o700)).map_err(|e| format!("{}: {e}", p.display()))
}

fn glob_paths(pattern: &Path) -> Vec<PathBuf> {
    let Some(pattern) = pattern.to_str() else { return Vec::new() };
    let opts = glob::MatchOptions { case_sensitive: true, require_literal_separator: true, require_literal_leading_dot: true };
    match glob::glob_with(pattern, opts) {
        Ok(paths) => paths.flatten().collect(),
        Err(_) => Vec::new(),
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Rw,
    Ro,
}

/// Helpers whose sockets the bwrap command line names before they run.
#[derive(Default)]
struct Pending {
    wayland_proxy: Option<(OsString, OsString)>,
    satellite: Option<(Vec<OsString>, PathBuf)>,
    dbus_proxy: Option<Vec<OsString>>,
    dbus_upstreams: Vec<OsString>,
    wants_a11y: bool,
    a11y_at: Option<usize>,
}

/// The app's systemd scope, and whether the helpers started before systemd moved this process join it afterwards.
struct Scope {
    unit: String,
    adopt: bool,
}

/// The helpers that take a few milliseconds to come up, and their pids.
#[derive(Default)]
struct SlowHelpers {
    proxy_ready: Option<OwnedFd>,
    pasta: Option<(Child, PathBuf, Option<fs::File>)>,
    pids: Vec<u32>,
}

/// Where the reaper finds the descriptor it reports the app's end on, fixed since pasta's far side opens it.
const STATUS_FD: i32 = 12;

/// Where the reaper finds the caller's stdin, stdout and stderr, which bwrap and pasta must not hold themselves.
pub const STDIO_FD: i32 = 13;

struct Launch<'a> {
    cfg: &'a Config,
    script: OsString,
    home: PathBuf,
    rt: PathBuf,
    uid: u32,
    gid: u32,
    id: u32,
    instance: PathBuf,
    flatpak_dir: Option<PathBuf>,
    args: Vec<OsString>,
    rw_roots: Vec<PathBuf>,
    visible: Vec<PathBuf>,
    pinned: HashSet<PathBuf>,
    launch_dir: Option<PathBuf>,
    git_guarded: HashSet<PathBuf>,
    removals: Vec<PathBuf>,
    helpers: Vec<Child>,
    holds: Vec<OwnedFd>,
    pending: Pending,
    pasta_args: Vec<OsString>,
    bus: dbus::Bus,
    setup: Option<String>,
    dry: bool,
    waiter: Option<fs::File>,
    caller_group: Option<libc::pid_t>,
    stdio: Option<[OwnedFd; 3]>,
    relay: Option<(OwnedFd, OwnedFd)>,
    stdio_socket: Option<UnixListener>,
}

impl<'a> Launch<'a> {
    fn push<S: Into<OsString>>(&mut self, a: S) {
        self.args.push(a.into());
    }

    fn push3<A: Into<OsString>, B: Into<OsString>, C: Into<OsString>>(&mut self, a: A, b: B, c: C) {
        self.args.push(a.into());
        self.args.push(b.into());
        self.args.push(c.into());
    }

    fn instance_path(&self, name: &str) -> PathBuf {
        self.instance.join(name)
    }

    /// The proxy's sockets sit in a folder of their own, the one part of the instance its sandbox can write to.
    fn proxy_socket(&self, name: &str) -> PathBuf {
        self.instance.join("bus").join(name)
    }

    /// Flatpak's names for the user folders, resolved through user-dirs.dirs, which is parsed rather than sourced since it is user data.
    fn xdg_path(&self, spec: &str) -> Option<PathBuf> {
        let (name, rest) = match spec.find('/') {
            Some(i) => (&spec[..i], &spec[i + 1..]),
            None => (spec, ""),
        };
        let join = |base: PathBuf| if rest.is_empty() { base } else { base.join(rest) };
        let xdg = |var: &str, fallback: &str| env_nonempty(var).map(PathBuf::from).unwrap_or_else(|| self.home.join(fallback));
        let (key, default) = match name {
            "xdg-config" => return Some(join(xdg("XDG_CONFIG_HOME", ".config"))),
            "xdg-cache" => return Some(join(xdg("XDG_CACHE_HOME", ".cache"))),
            "xdg-data" => return Some(join(xdg("XDG_DATA_HOME", ".local/share"))),
            "xdg-state" => return Some(join(xdg("XDG_STATE_HOME", ".local/state"))),
            "xdg-desktop" => ("DESKTOP", "Desktop"),
            "xdg-documents" => ("DOCUMENTS", "Documents"),
            "xdg-download" => ("DOWNLOAD", "Downloads"),
            "xdg-music" => ("MUSIC", "Music"),
            "xdg-pictures" => ("PICTURES", "Pictures"),
            "xdg-public-share" => ("PUBLICSHARE", "Public"),
            "xdg-videos" => ("VIDEOS", "Videos"),
            "xdg-templates" => ("TEMPLATES", "Templates"),
            _ => return None,
        };
        let mut value = self.home.join(default);
        let dirs_file = xdg("XDG_CONFIG_HOME", ".config").join("user-dirs.dirs");
        if let Ok(text) = fs::read(&dirs_file) {
            let prefix = format!("XDG_{key}_DIR=\"");
            for line in text.split(|b| *b == b'\n') {
                let Some(v) = line.strip_prefix(prefix.as_bytes()).and_then(|v| v.strip_suffix(b"\"")) else { continue };
                if let Some(r) = v.strip_prefix(b"$HOME/") {
                    value = self.home.join(OsStr::from_bytes(r));
                } else if v.starts_with(b"/") {
                    value = PathBuf::from(OsStr::from_bytes(v));
                }
            }
        }
        // A disabled user folder points at the home itself, which Flatpak leaves out too.
        if value == self.home {
            warn!("confine: {name} is the whole home, left out");
            return None;
        }
        Some(join(value))
    }

    fn resolve(&self, spec: &str) -> Option<PathBuf> {
        if let Some(rest) = spec.strip_prefix("xdg-run/") {
            Some(self.rt.join(rest))
        } else if spec.starts_with("xdg-") {
            self.xdg_path(spec)
        } else if let Some(rest) = spec.strip_prefix("./") {
            self.launch_dir.as_ref().map(|d| d.join(rest))
        } else if spec.starts_with('/') {
            Some(PathBuf::from(spec))
        } else {
            Some(self.home.join(spec))
        }
    }

    fn pin(&mut self, dir: &Path) {
        if self.pinned.insert(dir.to_path_buf()) {
            self.push3("--bind", dir, dir);
        }
    }

    /// A read only path inside a writable shared folder could be swapped out from inside by renaming a folder above it,
    /// so every folder in between is pinned in place and none of them may be a link.
    fn guard_path(&mut self, path: &Path) -> Res<()> {
        let Some(root) = self.rw_roots.iter().filter(|r| path.starts_with(r) && path != r.as_path()).max_by_key(|r| r.as_os_str().len()).cloned() else {
            return Ok(());
        };
        let rel = path.strip_prefix(&root).map_err(|e| e.to_string())?.to_path_buf();
        let mut dir = root;
        for comp in rel.components() {
            let Component::Normal(part) = comp else { continue };
            dir.push(part);
            if is_symlink(&dir) {
                fail!("refusing to start, {} is a link inside a shared folder, so the sandbox could redirect what it guards", dir.display());
            }
            if dir != path && dir.is_dir() {
                let d = dir.clone();
                self.pin(&d);
            }
        }
        Ok(())
    }

    fn add_bind(&mut self, mode: Mode, src: PathBuf, dest: PathBuf, create: bool) -> Res<()> {
        if mode == Mode::Rw {
            // Absolute paths are never created, that would paper over an unmounted disk.
            if create {
                fs::create_dir_all(&src).map_err(|e| format!("{}: {e}", src.display()))?;
            }
            self.push3("--bind-try", &src, &dest);
            if src == dest && src.is_dir() {
                self.rw_roots.push(src.clone());
            }
        } else {
            if src == dest && exists_or_link(&src) {
                self.guard_path(&src)?;
            }
            self.push3("--ro-bind-try", &src, &dest);
        }
        if src == dest {
            self.visible.push(src);
        }
        Ok(())
    }

    fn add_spec(&mut self, mode: Mode, from: &str, to: &str) -> Res<()> {
        let (Some(src), Some(dest)) = (self.resolve(from), self.resolve(to)) else { return Ok(()) };
        let create = !(from.starts_with('/') || from.starts_with("./"));
        self.add_bind(mode, src, dest, create)
    }

    /// A pattern binds whatever matches when the app starts, each match at its own path.
    fn add_matches(&mut self, mode: Mode, pattern: &str) -> Res<()> {
        let base = if pattern.starts_with('/') {
            PathBuf::from(pattern)
        } else if pattern.starts_with("xdg-") {
            match self.xdg_path(pattern) {
                Some(p) => p,
                None => return Ok(()),
            }
        } else if let Some(rest) = pattern.strip_prefix("./") {
            match &self.launch_dir {
                Some(d) => d.join(rest),
                None => return Ok(()),
            }
        } else {
            self.home.join(pattern)
        };
        for m in glob_paths(&base) {
            self.add_bind(mode, m.clone(), m, false)?;
        }
        Ok(())
    }

    fn guard_git_dir(&mut self, gitdir: &Path) -> Res<()> {
        self.pin(gitdir);
        for sub in ["config", "config.worktree", "commondir"] {
            let p = gitdir.join(sub);
            if exists_or_link(&p) {
                self.guard_path(&p)?;
                self.push3("--ro-bind", &p, &p);
            }
        }
        let hooks = gitdir.join("hooks");
        if exists_or_link(&hooks) {
            self.guard_path(&hooks)?;
            self.push3("--ro-bind", &hooks, &hooks);
        } else {
            // The sandbox could otherwise create the folder, so an empty read only one takes its place.
            let empty = self.instance_path("empty");
            self.push3("--ro-bind", empty, &hooks);
        }
        Ok(())
    }

    /// Git outside the sandbox later runs a repository's hooks and config commands, and follows commondir to another
    /// repository's config, so each repository in a writable shared folder keeps those read only, with its .git pinned
    /// so it cannot be renamed away and rebuilt.
    fn git_guard(&mut self) -> Res<()> {
        let empty = self.instance_path("empty");
        fs::DirBuilder::new().mode(0o755).create(&empty).map_err(|e| format!("{}: {e}", empty.display()))?;
        for root in self.rw_roots.clone() {
            for git_path in find_git(&root, self.cfg.git_guard.depth) {
                self.guard_path(&git_path)?;
                self.git_guarded.insert(git_path.clone());
                if git_path.is_file() {
                    self.push3("--ro-bind", &git_path, &git_path);
                    continue;
                }
                if git_path.join("commondir").exists() {
                    self.git_guarded.insert(git_path.join("commondir"));
                }
                self.guard_git_dir(&git_path)?;
                for sub in ["modules", "worktrees"] {
                    for nested in sorted_children(&git_path.join(sub)) {
                        if nested.is_dir() && !is_symlink(&nested) {
                            self.guard_git_dir(&nested)?;
                        }
                    }
                }
            }
        }
        Ok(())
    }

    /// Repositories made while the sandbox ran had no guard, and a commondir in a checkout redirects git to another
    /// repository's config, so those are reported when the sandbox ends and the commondir is removed.
    fn audit_git(&mut self) {
        let mut flagged = Vec::new();
        for root in self.rw_roots.clone() {
            for git_path in find_git(&root, self.cfg.git_guard.depth) {
                // Git follows a linked .git wherever it points, and so would a removal through it, so one is only reported.
                if is_symlink(&git_path) {
                    flagged.push(format!("{} (a link)", git_path.display()));
                    continue;
                }
                let commondir = git_path.join("commondir");
                if git_path.is_dir() && exists_or_link(&commondir) && !self.git_guarded.contains(&commondir) {
                    let removed = git_path.strip_prefix(&root).is_ok_and(|dir| sys::unlink_beneath(&root, dir, OsStr::new("commondir")).is_ok());
                    flagged.push(format!("{} ({})", commondir.display(), if removed { "removed" } else { "could not be removed" }));
                }
                if !self.git_guarded.contains(&git_path) && git_is_risky(&git_path) {
                    flagged.push(git_path.display().to_string());
                }
            }
        }
        if flagged.is_empty() {
            return;
        }
        let summary = format!("Repositories changed inside {} could run code through git outside it: {}", self.cfg.name, flagged.join(" "));
        // The notification first, it still arrives when the terminal that started the app is long gone.
        if let Some(conn) = self.bus.get() {
            dbus::notify(conn, "Check these repositories before using git on them", &summary);
        }
        warn!("confine: {summary}");
    }

    fn add_devices(&mut self) {
        for pattern in self.cfg.devices.clone() {
            for m in glob_paths(Path::new(&pattern)) {
                if !m.exists() {
                    continue;
                }
                // A link such as /dev/input/by-id/*-fido is bound at its target, the path programs find through sysfs.
                let Ok(dev) = fs::canonicalize(&m) else { continue };
                if !self.cfg.security_keys && is_security_key(&dev) {
                    warn!("confine: left out {}, a security key, which needs securityKeys = true", dev.display());
                    continue;
                }
                self.push3("--dev-bind", &dev, &dev);
            }
        }
    }

    fn build(&mut self) -> Res<()> {
        let cfg = self.cfg;
        self.args.extend(cfg.static_args.iter().map(OsString::from));

        // A link like the host's, a mounted copy would hide that the running system is a store path.
        for link in ["/run/current-system", "/run/booted-system"] {
            if let Ok(t) = fs::read_link(link) {
                self.push3("--symlink", t, link);
            }
        }

        // Shebangs, system() and popen() expect /bin/sh and /usr/bin/env, kept read-only like Flatpak's /usr so the app cannot swap them.
        for dir in ["/bin", "/usr/bin"] {
            let links: Vec<(PathBuf, PathBuf)> = sorted_children(Path::new(dir)).into_iter().filter_map(|p| fs::read_link(&p).ok().map(|t| (t, p))).collect();
            if !links.is_empty() {
                self.push("--tmpfs");
                self.push(dir);
                for (t, p) in links {
                    self.push3("--symlink", t, p);
                }
                self.push("--remount-ro");
                self.push(dir);
            }
        }

        // resolved answers over a unix socket, which would carry lookups around a network setup's tunnel.
        if cfg.network != Network::None && self.setup.is_none() {
            self.push3("--ro-bind-try", "/run/systemd/resolve", "/run/systemd/resolve");
        }

        // Masks only land on existing paths, the /etc bind is read-only.
        for f in &cfg.masked_files {
            if Path::new(f).is_file() {
                self.push3("--ro-bind", "/dev/null", f);
            }
        }
        for d in &cfg.masked_dirs {
            if Path::new(d).is_dir() {
                self.push("--tmpfs");
                self.push(d);
            }
        }

        let user = lookup_user(self.uid);
        let user_name = user.as_ref().map(|u| u.name.clone()).or_else(|| env::var("USER").ok()).unwrap_or_else(|| self.uid.to_string());
        if !cfg.host_accounts {
            // Only this user and the overflow id, as Flatpak writes them, so the host's other accounts stay out.
            let real_name = user.as_ref().map(|u| u.gecos.clone()).unwrap_or_default();
            let group_name = lookup_group(self.gid).unwrap_or_else(|| self.gid.to_string());
            let passwd = format!(
                "{user_name}:x:{}:{}:{real_name}:{}:/bin/sh\nnfsnobody:x:65534:65534:Unmapped user:/:/sbin/nologin\n",
                self.uid,
                self.gid,
                self.home.display()
            );
            let group = format!("{group_name}:x:{}:{user_name}\nnfsnobody:x:65534:\n", self.gid);
            let (pf, gf) = (self.instance_path("passwd"), self.instance_path("group"));
            fs::write(&pf, passwd).map_err(|e| e.to_string())?;
            fs::write(&gf, group).map_err(|e| e.to_string())?;
            self.push3("--ro-bind", pf, "/etc/passwd");
            self.push3("--ro-bind", gf, "/etc/group");
        }

        // Host plugin trees stay out because mismatched toolkit plugins crash apps and GSettings must fall back to the keyfile backend.
        let mut lc: Vec<OsString> = env::vars_os().map(|(k, _)| k).filter(|k| k.as_bytes().starts_with(b"LC_")).collect();
        lc.sort();
        let mut pass: Vec<OsString> = cfg.host_env.iter().map(OsString::from).chain(lc).collect();
        if cfg.gpu {
            pass.extend(cfg.gpu_env.iter().map(OsString::from));
        }
        pass.extend(cfg.env_passthrough.iter().map(OsString::from));
        for var in pass {
            if let Some(v) = env::var_os(&var).filter(|v| !v.is_empty()) {
                self.push3("--setenv", var, v);
            }
        }

        let home = self.home.clone();
        self.push3("--setenv", "HOME", &home);
        self.push3("--setenv", "USER", env_nonempty("USER").unwrap_or_else(|| user_name.clone().into()));
        self.push3("--setenv", "LOGNAME", env_nonempty("LOGNAME").unwrap_or_else(|| user_name.clone().into()));
        let rt = self.rt.clone();
        self.push3("--setenv", "XDG_RUNTIME_DIR", &rt);
        let mut data_dirs = OsString::from(&cfg.data_dirs_prefix);
        data_dirs.push(":");
        data_dirs.push(env_nonempty("XDG_DATA_DIRS").unwrap_or_else(|| "/run/current-system/sw/share".into()));
        self.push3("--setenv", "XDG_DATA_DIRS", data_dirs);

        let app_dir = rt.join("app").join(&cfg.app_id);
        if cfg.runtime_dir == RuntimeDir::Shared {
            mkdir_private(&app_dir)?;
            self.push3("--bind", &app_dir, &rt);
        } else {
            self.push3("--dir", &rt, "--chmod");
            self.push("0700");
            self.push(&rt);
        }

        // Last, the final --setenv wins in bwrap and declared env outranks host values.
        for (k, v) in &cfg.env {
            self.push3("--setenv", k, v);
        }

        mkdir_private(&app_dir)?;
        self.push3("--bind", &app_dir, &app_dir);

        match cfg.home {
            Home::Private => {
                let base = env_nonempty("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".local/share"));
                let private_home = base.join("confine").join(&cfg.app_id);
                fs::create_dir_all(&private_home).map_err(|e| format!("{}: {e}", private_home.display()))?;
                self.push3("--bind", private_home, &home);
            }
            Home::Ephemeral => {
                self.push("--dir");
                self.push(&home);
            }
            Home::Host => {
                self.push3("--bind", &home, &home);
                self.rw_roots.push(home.clone());
                self.visible.push(home.clone());
            }
        }

        if cfg.workdir.is_some() || !cfg.binds_ro.is_empty() || !cfg.binds_rw.is_empty() {
            self.launch_dir = env::current_dir().ok();
        }
        if let Some(mode) = cfg.workdir {
            let Some(launch_dir) = self.launch_dir.clone() else { fail!("cannot tell which folder it was started in") };
            // The home itself, or anything above it, would hand over every file the sandbox exists to hide. HOME can point elsewhere, the account's home cannot.
            let account_home = user.as_ref().map(|u| u.dir.clone());
            for h in [Some(home.clone()), account_home].into_iter().flatten() {
                if launch_dir == Path::new("/") || (!h.as_os_str().is_empty() && h.starts_with(&launch_dir)) {
                    fail!("refusing to share {}, it contains your whole home", launch_dir.display());
                }
            }
            self.push3(if mode == Workdir::Rw { "--bind" } else { "--ro-bind" }, &launch_dir, &launch_dir);
            self.push("--chdir");
            self.push(&launch_dir);
            if mode == Workdir::Rw {
                self.rw_roots.push(launch_dir.clone());
            }
            self.visible.push(launch_dir);
        }

        // Writable binds come first, a later mount of a parent would hide a read only path inside it.
        for (mode, binds) in [(Mode::Rw, &cfg.binds_rw), (Mode::Ro, &cfg.binds_ro)] {
            for b in binds {
                if b.pattern {
                    self.add_matches(mode, &b.from)?;
                } else {
                    self.add_spec(mode, &b.from, &b.to)?;
                }
            }
        }

        for s in &cfg.symlinks {
            let dest = if let Some(rest) = s.link.strip_prefix("xdg-run/") {
                rt.join(rest)
            } else if s.link.starts_with('/') {
                PathBuf::from(&s.link)
            } else {
                home.join(&s.link)
            };
            self.push3("--symlink", &s.target, dest);
        }

        if cfg.git_guard.enable {
            self.git_guard()?;
        }

        self.add_devices();

        if cfg.sysfs {
            // /sys/class/net holds a link per interface into the net folders of /sys/devices, which carry names and MACs.
            let dirs: BTreeSet<PathBuf> = sorted_children(Path::new("/sys/class/net"))
                .into_iter()
                .filter_map(|l| fs::canonicalize(l).ok().and_then(|t| t.parent().map(Path::to_path_buf)))
                .collect();
            for d in dirs {
                self.push("--tmpfs");
                self.push(d);
            }
        }

        if cfg.gpu {
            for node in glob_paths(Path::new("/dev/nvidia*")) {
                if node.exists() {
                    self.push3("--dev-bind", &node, &node);
                }
            }
        }

        let isolated_x11 = cfg.x11 == X11::Isolated;
        let mut host_socket = OsString::new();
        let mut context_socket = OsString::new();
        if cfg.wayland || isolated_x11 {
            let display = env_nonempty("WAYLAND_DISPLAY").unwrap_or_else(|| "wayland-0".into());
            host_socket = Path::new(&display).file_name().map(OsStr::to_os_string).unwrap_or(display);
            if !self.dry && !is_socket(&rt.join(&host_socket)) {
                fail!("no wayland socket at {}", rt.join(&host_socket).display());
            }
            context_socket = host_socket.clone();
        }
        if cfg.security_context {
            // The compositor keeps fake input, screen capture, window management and background clipboard reads from
            // security context clients, the way it does for Flatpak. A nested launch reuses its parent's context.
            if env_nonempty("CONFINE_WAYLAND_SANDBOXED").is_none() {
                let name = format!("confine-{}.{}.context", cfg.app_id, self.id);
                if !self.dry {
                    let socket = rt.join(&name);
                    self.removals.push(socket.clone());
                    let hold = wayland::create_context(&socket, &cfg.context_app_id, &self.id.to_string())
                        .map_err(|e| format!("the compositor gave no Wayland security context, refusing to start without one, which only waylandSecurityContext = false allows: {e}"))?;
                    self.holds.push(hold);
                }
                context_socket = name.into();
            }
            self.push3("--setenv", "CONFINE_WAYLAND_SANDBOXED", "1");
        }
        if cfg.wayland {
            let mut wayland_socket = context_socket.clone();
            if cfg.wayland_proxy {
                // Relays only core protocols, which also drops GPU buffer sharing, input methods and fractional scaling, so it stays off by default.
                let name: OsString = format!("confine-{}.{}", cfg.app_id, self.id).into();
                self.removals.push(rt.join(&name));
                self.pending.wayland_proxy = Some((context_socket.clone(), name.clone()));
                wayland_socket = name;
            }
            self.push3("--ro-bind", rt.join(&wayland_socket), rt.join(&host_socket));
            self.push3("--setenv", "WAYLAND_DISPLAY", &host_socket);
        }

        if isolated_x11 {
            // --unshare-net matters, abstract X sockets are scoped by network namespace.
            let x11_dir = self.instance_path("X11");
            fs::create_dir_all(&x11_dir).map_err(|e| e.to_string())?;
            let mut sat: Vec<OsString> = [
                "--unshare-user", "--unshare-ipc", "--unshare-pid", "--unshare-net", "--unshare-uts", "--unshare-cgroup-try",
                "--disable-userns", "--new-session", "--die-with-parent", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
                "--ro-bind", "/nix/store", "/nix/store", "--ro-bind-try", "/run/current-system", "/run/current-system",
                "--ro-bind", "/etc", "/etc", "--dir",
            ]
            .iter()
            .map(OsString::from)
            .collect();
            sat.push(rt.clone().into());
            sat.extend(["--ro-bind".into(), rt.join(&context_socket).into(), rt.join(&host_socket).into()]);
            sat.extend(["--bind".into(), x11_dir.clone().into(), "/tmp/.X11-unix".into()]);
            sat.extend(["--setenv".into(), "XDG_RUNTIME_DIR".into(), rt.clone().into()]);
            sat.extend(["--setenv".into(), "WAYLAND_DISPLAY".into(), host_socket.clone()]);
            sat.extend(["--unsetenv".into(), "DISPLAY".into()]);
            if cfg.gpu {
                for (a, b) in [("--dev-bind-try", "/dev/dri"), ("--ro-bind-try", "/run/opengl-driver"), ("--ro-bind-try", "/run/opengl-driver-32")] {
                    sat.extend([a.into(), b.into(), b.into()]);
                }
                for d in &cfg.sysfs_dirs {
                    sat.extend(["--ro-bind-try".into(), d.into(), d.into()]);
                }
            }
            sat.push("--".into());
            sat.push(cfg.tools.satellite.clone().ok_or("no xwayland-satellite in the config")?.into());
            sat.push(":99".into());
            self.pending.satellite = Some((sat, x11_dir.clone()));
            self.push3("--bind", x11_dir, "/tmp/.X11-unix");
            self.push3("--setenv", "DISPLAY", ":99");
        }

        if cfg.x11 == X11::Host {
            if let Some(display) = env_nonempty("DISPLAY") {
                let d = display.to_string_lossy().into_owned();
                let num = d.rsplit(':').next().unwrap_or("").split('.').next().unwrap_or("").to_string();
                let socket = PathBuf::from(format!("/tmp/.X11-unix/X{num}"));
                if is_socket(&socket) {
                    self.push3("--ro-bind", &socket, &socket);
                    self.push3("--setenv", "DISPLAY", display);
                }
                if let Some(xauth) = env_nonempty("XAUTHORITY").filter(|x| Path::new(x).exists()) {
                    self.push3("--ro-bind", &xauth, &xauth);
                    self.push3("--setenv", "XAUTHORITY", xauth);
                }
            }
        }

        if cfg.pipewire {
            // The -manager socket can rewire the graph and tap other apps' audio.
            for n in 0..=9 {
                let s = rt.join(format!("pipewire-{n}"));
                if is_socket(&s) {
                    self.push3("--ro-bind", &s, &s);
                }
            }
        }

        if cfg.pulse {
            let native = rt.join("pulse/native");
            if is_socket(&native) {
                // libpulse chmods its runtime folder and fails when it is a bind target, and shm needs an IPC namespace the sandbox does not share.
                let pulse_config = self.instance_path("pulse-config");
                fs::write(&pulse_config, "enable-shm=no\n").map_err(|e| e.to_string())?;
                self.push("--dir");
                self.push("/run/flatpak/pulse");
                self.push3("--ro-bind", native, "/run/flatpak/pulse/native");
                self.push3("--ro-bind", pulse_config, "/run/flatpak/pulse/config");
                self.push3("--symlink", "../../flatpak/pulse", rt.join("pulse"));
                self.push3("--setenv", "PULSE_SERVER", "unix:/run/flatpak/pulse/native");
                self.push3("--setenv", "PULSE_CLIENTCONFIG", "/run/flatpak/pulse/config");
            }
        }

        if cfg.dbus.filter {
            self.push3("--ro-bind", self.proxy_socket("session"), rt.join("bus"));
            self.push3("--setenv", "DBUS_SESSION_BUS_ADDRESS", format!("unix:path={}/bus", rt.display()));
            if cfg.dbus.system_args.is_some() {
                self.push3("--ro-bind", self.proxy_socket("system"), "/run/dbus/system_bus_socket");
            }
            // The proxy only makes the accessibility socket once it runs, so its binds go in here after it started.
            if self.pending.wants_a11y {
                self.pending.a11y_at = Some(self.args.len());
            }
        } else if is_socket(&rt.join("bus")) {
            self.push3("--ro-bind", rt.join("bus"), rt.join("bus"));
            self.push3("--setenv", "DBUS_SESSION_BUS_ADDRESS", format!("unix:path={}/bus", rt.display()));
        }

        if cfg.portals {
            self.push3("--ro-bind", self.instance_path("flatpak-info"), "/.flatpak-info");
            // Only this app's slice, the top level doc folder holds every app's grants. The portal is asked where it is
            // mounted, which starts it as Flatpak's launch does: a folder made here ahead of the portal would end up
            // under its mount, and the sandbox would keep that empty folder instead of the files picked for it.
            if !self.dry {
                if let Some(mount) = self.bus.get().and_then(dbus::documents_mount_point) {
                    self.push3("--bind-try", mount.join("by-app").join(&cfg.app_id), rt.join("doc"));
                }
            }
        }

        if cfg.network == Network::Isolated {
            // pasta maps the caller to uid 0 and Chromium refuses to run as root.
            self.push3("--uid", self.uid.to_string(), "--gid");
            self.push(self.gid.to_string());
        }

        self.args.extend(cfg.extra_bwrap_args.iter().map(OsString::from));
        Ok(())
    }

    /// The caller's stdin, stdout and stderr go to the sandbox alone. Everything outside it writes to a pipe this process
    /// passes on instead, or whoever reads the launch's output would wait for the helpers long after the launch returned.
    fn detach_stdio(&self, c: &mut Command) {
        let Some((_, relay)) = &self.relay else { return };
        let output = || relay.try_clone().map(Stdio::from).unwrap_or_else(|_| Stdio::inherit());
        c.stdin(Stdio::null()).stdout(output()).stderr(output());
    }

    /// Onto this process's stderr, which is the caller's until the launch has returned.
    fn drain_relay(&self) {
        let Some((relay, _)) = &self.relay else { return };
        let mut buf = [0u8; 4096];
        while let Some(n) = sys::read_available(relay.as_raw_fd(), &mut buf).filter(|n| *n > 0) {
            let _ = std::io::stderr().write_all(&buf[..n]);
        }
    }

    /// pasta closes what it inherits, so its far side asks for the caller's stdin, stdout and stderr here once the network setup is done.
    fn pass_stdio(&mut self) {
        let (Some(listener), Some(stdio)) = (&self.stdio_socket, &self.stdio) else { return };
        let Ok((conn, _)) = listener.accept() else { return };
        let _ = sys::send_fds(conn.as_raw_fd(), &[stdio[0].as_raw_fd(), stdio[1].as_raw_fd(), stdio[2].as_raw_fd()]);
        self.stdio_socket = None;
    }

    fn command(&self, program: &str) -> Command {
        let mut c = Command::new(program);
        self.detach_stdio(&mut c);
        let mask = sys::handled_signals();
        unsafe {
            c.pre_exec(move || {
                sys::unblock_in_child(&mask)?;
                sys::die_with_parent()
            });
        }
        c
    }

    /// bwrap and pasta carry the sandbox, which stays in the caller's job and so keeps its terminal, while this process and its helpers sit in a group that kill(0) from inside cannot reach.
    fn sandbox_command(&self, program: &str) -> Command {
        let mut c = Command::new(program);
        self.detach_stdio(&mut c);
        if let Some(group) = self.caller_group {
            c.process_group(group);
        }
        unsafe { c.pre_exec(sys::block_only_terminal_interrupts) };
        c
    }

    fn wait_for_socket(path: &Path, what: &str) -> Res<()> {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !is_socket(path) {
            if Instant::now() > deadline {
                fail!("{what} never came up");
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        Ok(())
    }

    fn prepare_dbus_proxy(&mut self) {
        let cfg = self.cfg;
        if !cfg.dbus.filter {
            return;
        }
        let session_bus = env_nonempty("DBUS_SESSION_BUS_ADDRESS").unwrap_or_else(|| format!("unix:path={}/bus", self.rt.display()).into());
        let mut proxy: Vec<OsString> = vec!["--fd=3".into(), session_bus.clone(), self.proxy_socket("session").into()];
        proxy.extend(cfg.dbus.session_args.iter().map(OsString::from));
        self.pending.dbus_upstreams.push(session_bus);
        if let Some(system) = &cfg.dbus.system_args {
            let system_bus: OsString = "unix:path=/run/dbus/system_bus_socket".into();
            proxy.extend([system_bus.clone(), self.proxy_socket("system").into()]);
            proxy.extend(system.iter().map(OsString::from));
            self.pending.dbus_upstreams.push(system_bus);
        }
        if let Some(a11y) = &cfg.dbus.a11y_args {
            let address = match env_nonempty("AT_SPI_BUS_ADDRESS") {
                Some(a) => Some(a),
                None if !self.dry => self.bus.get().and_then(dbus::a11y_address).map(OsString::from),
                None => None,
            };
            if let Some(address) = address {
                proxy.extend([address.clone(), self.proxy_socket("a11y").into()]);
                proxy.extend(a11y.iter().map(OsString::from));
                self.pending.dbus_upstreams.push(address);
                self.pending.wants_a11y = true;
            }
        }
        self.pending.dbus_proxy = Some(proxy);
    }

    /// The proxy parses whatever the app sends and holds the unfiltered buses, so it runs in a sandbox of its own that
    /// sees the store, the buses it relays and its own sockets, under the strict filter. The portal inspects the bus
    /// peer, which is the proxy, so the forged /.flatpak-info sits in this namespace too.
    fn spawn_dbus_proxy(&mut self) -> Res<Option<(OwnedFd, u32)>> {
        let cfg = self.cfg;
        let Some(args) = self.pending.dbus_proxy.clone() else { return Ok(None) };
        let (ready_read, ready_write) = sys::pipe().map_err(|e| e.to_string())?;
        let tool = cfg.tools.dbus_proxy.clone().ok_or("no xdg-dbus-proxy in the config")?;
        let sockets = self.instance_path("bus");
        fs::DirBuilder::new().mode(0o700).create(&sockets).map_err(|e| format!("{}: {e}", sockets.display()))?;
        let mut c = Command::new(&cfg.tools.bwrap);
        c.args(["--unshare-user", "--unshare-ipc", "--unshare-pid", "--unshare-uts", "--unshare-cgroup-try", "--disable-userns", "--new-session", "--as-pid-1"]);
        c.args(["--die-with-parent", "--clearenv", "--ro-bind", "/nix/store", "/nix/store"]);
        // A bus on a socket file needs no network, any other kind of address may.
        let mut files_only = true;
        for address in &self.pending.dbus_upstreams {
            match bus_socket(address) {
                Some(socket) => {
                    c.arg("--ro-bind-try").arg(&socket).arg(&socket);
                }
                None => files_only = false,
            }
        }
        if files_only {
            c.arg("--unshare-net");
        }
        c.arg("--bind").arg(&sockets).arg(&sockets);
        if cfg.portals {
            c.arg("--ro-bind").arg(self.instance_path("flatpak-info")).arg("/.flatpak-info");
        }
        let filter = match &cfg.tools.dbus_proxy_filter {
            Some(f) => Some(fs::File::open(f).map_err(|e| format!("{f}: {e}"))?),
            None => None,
        };
        let mut pairs = vec![(ready_write.as_raw_fd(), 3)];
        if let Some(f) = &filter {
            c.args(["--seccomp", "4"]);
            pairs.push((f.as_raw_fd(), 4));
        }
        c.arg("--").arg(&tool).args(&args);
        self.detach_stdio(&mut c);
        let mask = sys::handled_signals();
        unsafe {
            c.pre_exec(move || {
                sys::unblock_in_child(&mask)?;
                sys::die_with_parent()?;
                sys::remap_fds(&pairs)
            });
        }
        let child = c.spawn().map_err(|e| format!("xdg-dbus-proxy: {e}"))?;
        drop(ready_write);
        let pid = child.id();
        self.helpers.push(child);
        Ok(Some((ready_read, pid)))
    }

    /// The proxy writes one byte when ready and exits when this end closes, so the end is held for the whole run.
    fn finish_dbus_proxy(&mut self, ready: OwnedFd) -> Res<()> {
        let ok = sys::poll_readable(&[ready.as_raw_fd()], 10_000).map(|r| r[0]).unwrap_or(false);
        let mut byte = [0u8; 1];
        let got = ok && unsafe { libc::read(ready.as_raw_fd(), byte.as_mut_ptr().cast(), 1) } == 1;
        if !got || !is_socket(&self.proxy_socket("session")) {
            fail!("the D-Bus proxy never came up");
        }
        self.holds.push(ready);
        if let Some(at) = self.pending.a11y_at.take() {
            let socket = self.proxy_socket("a11y");
            if is_socket(&socket) {
                let extra: Vec<OsString> = vec![
                    "--ro-bind".into(),
                    socket.into(),
                    "/run/flatpak/at-spi-bus".into(),
                    "--setenv".into(),
                    "AT_SPI_BUS_ADDRESS".into(),
                    "unix:path=/run/flatpak/at-spi-bus".into(),
                ];
                self.args.splice(at..at, extra);
            }
        }
        Ok(())
    }

    fn prepare_pasta(&mut self) -> Res<()> {
        let cfg = self.cfg;
        if cfg.network != Network::Isolated {
            return Ok(());
        }
        // A host port has one listener, so the first running instance of an app holds its ports and a later one starts
        // without them rather than not at all, as when a running editor is handed another file.
        if !cfg.from_host.is_empty() && (self.dry || self.claim_ports()?) {
            for spec in &cfg.from_host {
                self.pasta_args.extend(["-t".into(), spec.into(), "-u".into(), spec.into()]);
            }
        } else {
            self.pasta_args.extend(["-t", "none", "-u", "none"].map(OsString::from));
        }
        self.pasta_args.extend(cfg.pasta_args.iter().map(OsString::from));
        if let Some(i) = default_route_v4() {
            self.pasta_args.extend(["--outbound-if4".into(), i]);
        }
        if let Some(i) = default_route_v6() {
            self.pasta_args.extend(["--outbound-if6".into(), i]);
        }
        Ok(())
    }

    /// A lock the kernel drops with this process however it ends, on a file the sandbox cannot reach.
    fn claim_ports(&mut self) -> Res<bool> {
        let path = self.rt.join("confine").join(format!(".{}.ports", self.cfg.app_id));
        let file = fs::OpenOptions::new().write(true).create(true).truncate(false).mode(0o600).open(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Ok(false);
        }
        self.holds.push(file.into());
        Ok(true)
    }

    /// pasta sets its namespace up while the command line is built, and its far side waits for the arguments on a FIFO.
    /// pasta closes inherited descriptors, so the filter, info and status descriptors open on that side, after any network setup.
    fn spawn_pasta(&mut self) -> Res<(Child, PathBuf, Option<fs::File>)> {
        let cfg = self.cfg;
        let args_fifo = self.instance_path("args");
        let info_fifo = self.instance_path("info");
        for fifo in [&args_fifo, &info_fifo] {
            sys::mkfifo(fifo).map_err(|e| e.to_string())?;
        }
        let (status, status_fifo) = if cfg.linger {
            let fifo = self.instance_path("status");
            sys::mkfifo(&fifo).map_err(|e| e.to_string())?;
            // Open before the far side's writer, so its open does not wait and no end of file comes before it.
            let status = fs::OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK).open(&fifo).map_err(|e| e.to_string())?;
            (Some(status), fifo.into_os_string())
        } else {
            (None, OsString::new())
        };
        let stdio_socket = self.instance_path("stdio");
        self.stdio_socket = Some(UnixListener::bind(&stdio_socket).map_err(|e| format!("{}: {e}", stdio_socket.display()))?);
        let me = env::current_exe().map_err(|e| e.to_string())?;
        let mut c = self.sandbox_command(cfg.tools.pasta.as_deref().ok_or("no pasta in the config")?);
        unsafe { c.pre_exec(sys::die_with_parent) };
        c.args(&self.pasta_args).arg("--").arg(me).arg("--inner");
        c.arg(self.setup.as_deref().unwrap_or("")).arg(cfg.filter.as_deref().unwrap_or("")).arg(&info_fifo).arg(&status_fifo);
        c.arg(&cfg.tools.bwrap).arg(&args_fifo).arg(&stdio_socket);
        if self.setup.is_some() {
            c.env("CONFINE_INSTANCE", &self.instance);
        }
        let child = c.spawn().map_err(|e| format!("pasta: {e}"))?;
        Ok((child, args_fifo, status))
    }

    fn spawn_slow_helpers(&mut self) -> Res<SlowHelpers> {
        let mut h = SlowHelpers::default();
        if let Some((ready, pid)) = self.spawn_dbus_proxy()? {
            h.proxy_ready = Some(ready);
            h.pids.push(pid);
        }
        if self.cfg.network == Network::Isolated {
            let (child, fifo, status) = self.spawn_pasta()?;
            h.pids.push(child.id());
            h.pasta = Some((child, fifo, status));
        }
        Ok(h)
    }

    /// Waits for systemd to move this process into the scope, then moves in the helpers started before that. Without
    /// the scope the app would run free of its resource limits, so with limits set that refuses to start.
    fn enter_scope(&mut self, scope: &Scope, early: &[u32]) -> Res<()> {
        let joined = if !dbus::wait_for_scope(&scope.unit) {
            Err("systemd never moved the launcher into it".to_string())
        } else if early.is_empty() {
            Ok(())
        } else {
            match self.bus.get() {
                Some(conn) => adopt(conn, &scope.unit, early),
                None => Err("no session bus".into()),
            }
        };
        match joined {
            Ok(()) => Ok(()),
            Err(e) if self.cfg.resources.is_empty() => {
                warn!("confine: running outside the scope {}: {e}", scope.unit);
                Ok(())
            }
            Err(e) => fail!("refusing to start outside the scope {}, which carries the resource limits: {e}", scope.unit),
        }
    }

    /// Display helpers need the security context the command line build made.
    fn start_display_helpers(&mut self) -> Res<()> {
        let cfg = self.cfg;
        if let Some((upstream, name)) = self.pending.wayland_proxy.take() {
            let tool = cfg.tools.wayland_proxy.clone().ok_or("no wayland-proxy-virtwl in the config")?;
            let mut c = self.command(&tool);
            c.env("WAYLAND_DISPLAY", &upstream).arg({
                let mut a = OsString::from("--wayland-display=");
                a.push(&name);
                a
            });
            self.helpers.push(c.spawn().map_err(|e| format!("wayland-proxy-virtwl: {e}"))?);
            Self::wait_for_socket(&self.rt.join(&name), "the wayland proxy")?;
        }
        if let Some((args, x11_dir)) = self.pending.satellite.take() {
            let mut c = self.command(&cfg.tools.bwrap);
            c.args(&args);
            self.helpers.push(c.spawn().map_err(|e| format!("xwayland-satellite: {e}"))?);
            Self::wait_for_socket(&x11_dir.join("X99"), "xwayland-satellite")?;
        }
        Ok(())
    }

    /// Files handed over from outside arrive between @@ markers, as in Flatpak's desktop entries, and one the sandbox
    /// cannot already see is exported through the document portal for this app alone.
    fn forward(&mut self, args: Vec<OsString>) -> Vec<OsString> {
        let mut out = Vec::with_capacity(args.len());
        let mut fencing: Option<bool> = None;
        for arg in args {
            match arg.as_bytes() {
                b"@@" | b"@@u" => {
                    fencing = match fencing {
                        None => Some(arg.as_bytes() == b"@@u"),
                        Some(_) => None,
                    };
                    continue;
                }
                _ => {}
            }
            match fencing {
                Some(uri) if self.cfg.portals => out.push(self.forward_one(arg, uri)),
                _ => out.push(arg),
            }
        }
        out
    }

    fn forward_one(&mut self, arg: OsString, uri: bool) -> OsString {
        let raw = arg.as_bytes();
        let path = if uri {
            if let Some(rest) = raw.strip_prefix(b"file://") {
                let rest = rest.strip_prefix(b"localhost").unwrap_or(rest);
                PathBuf::from(OsString::from_vec(percent_decode(rest)))
            } else if raw.starts_with(b"/") {
                PathBuf::from(&arg)
            } else {
                return arg;
            }
        } else {
            PathBuf::from(&arg)
        };
        let path = if path.is_absolute() { path } else { env::current_dir().map(|d| d.join(&path)).unwrap_or(path) };
        let Ok(path) = fs::canonicalize(&path) else { return arg };
        if self.visible.iter().any(|v| path.starts_with(v)) || path.starts_with("/nix/store") || path.starts_with(self.rt.join("doc")) {
            return arg;
        }
        let app_id = self.cfg.app_id.clone();
        let doc = match self.bus.get().ok_or_else(|| "no session bus".to_string()).and_then(|c| dbus::add_document(c, &app_id, &path)) {
            Ok(d) => d,
            Err(e) => {
                warn!("confine: could not hand {} to the document portal: {e}", path.display());
                return arg;
            }
        };
        let doc_path = self.rt.join("doc").join(doc).join(path.file_name().unwrap_or_default());
        if uri {
            let mut s = OsString::from("file://");
            s.push(OsStr::from_bytes(&percent_encode(doc_path.as_os_str().as_bytes())));
            s
        } else {
            doc_path.into()
        }
    }

    fn cleanup(&mut self) {
        self.drain_relay();
        for h in &mut self.helpers {
            sys::kill(h.id(), libc::SIGTERM);
        }
        if self.cfg.git_guard.enable && !self.dry {
            self.audit_git();
        }
        let _ = fs::remove_dir_all(&self.instance);
        if let Some(d) = &self.flatpak_dir {
            let _ = fs::remove_dir_all(d);
        }
        for r in &self.removals {
            let _ = fs::remove_file(r);
        }
    }
}

/// The socket file behind a bus address, for the plain kind every desktop uses.
fn bus_socket(address: &OsStr) -> Option<PathBuf> {
    let address = address.to_str()?;
    if address.contains([';', '%']) {
        return None;
    }
    address.strip_prefix("unix:")?.split(',').find_map(|pair| pair.strip_prefix("path=")).map(PathBuf::from)
}

fn sorted_children(dir: &Path) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = match fs::read_dir(dir) {
        Ok(rd) => rd.flatten().filter(|e| !e.file_name().as_bytes().starts_with(b".")).map(|e| e.path()).collect(),
        Err(_) => Vec::new(),
    };
    v.sort();
    v
}

/// Like find ROOT -maxdepth DEPTH -name .git, without descending into node_modules, a .git or a linked folder.
fn find_git(root: &Path, depth: usize) -> Vec<PathBuf> {
    fn walk(dir: &Path, level: usize, depth: usize, out: &mut Vec<PathBuf>) {
        let Ok(rd) = fs::read_dir(dir) else { return };
        for e in rd.flatten() {
            let name = e.file_name();
            if name == ".git" {
                out.push(e.path());
                continue;
            }
            if name == "node_modules" || level >= depth {
                continue;
            }
            if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                walk(&e.path(), level + 1, depth, out);
            }
        }
    }
    let mut out = Vec::new();
    walk(root, 1, depth, &mut out);
    out
}

/// A repository made inside can run code through git outside: a gitfile pointing anywhere, a hook, or a config command.
fn git_is_risky(gitdir: &Path) -> bool {
    if gitdir.is_file() {
        return true;
    }
    for hook in sorted_children(&gitdir.join("hooks")) {
        let executable = fs::metadata(&hook).map(|m| m.is_file() && m.mode() & 0o111 != 0).unwrap_or(false);
        if executable && !hook.as_os_str().as_bytes().ends_with(b".sample") {
            return true;
        }
    }
    const KEYS: [&str; 15] = [
        "fsmonitor", "hookspath", "sshcommand", "askpass", "pager", "editor", "textconv", "clean", "smudge", "process", "program", "helper", "driver",
        "external", "command",
    ];
    for file in ["config", "config.worktree"] {
        let Ok(text) = fs::read_to_string(gitdir.join(file)) else { continue };
        for line in text.lines() {
            let l = line.trim_start().to_ascii_lowercase();
            if l.starts_with("[include") {
                return true;
            }
            if let Some((key, _)) = l.split_once('=') {
                if KEYS.contains(&key.trim()) {
                    return true;
                }
            }
        }
    }
    false
}

/// udev tags FIDO and other security keys, and an app that did not ask for one should not be able to request signatures from it.
fn is_security_key(dev: &Path) -> bool {
    let Ok(meta) = fs::metadata(dev) else { return false };
    if !meta.file_type().is_char_device() {
        return false;
    }
    let rdev = meta.rdev();
    let path = format!("/run/udev/data/c{}:{}", libc::major(rdev), libc::minor(rdev));
    fs::read_to_string(path).map(|t| t.lines().any(|l| l == "E:ID_SECURITY_TOKEN=1")).unwrap_or(false)
}

fn default_route_v4() -> Option<OsString> {
    let text = fs::read_to_string("/proc/net/route").ok()?;
    text.lines().skip(1).find_map(|l| {
        let f: Vec<&str> = l.split_whitespace().collect();
        (f.len() > 7 && f[1] == "00000000" && f[7] == "00000000").then(|| f[0].into())
    })
}

fn default_route_v6() -> Option<OsString> {
    let text = fs::read_to_string("/proc/net/ipv6_route").ok()?;
    text.lines().find_map(|l| {
        let f: Vec<&str> = l.split_whitespace().collect();
        (f.len() == 10 && f[0] == "00000000000000000000000000000000" && f[1] == "00" && f[9] != "lo").then(|| f[9].into())
    })
}

fn percent_decode(s: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        if s[i] == b'%' && i + 2 < s.len() {
            if let Ok(b) = u8::from_str_radix(std::str::from_utf8(&s[i + 1..i + 3]).unwrap_or("zz"), 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(s[i]);
        i += 1;
    }
    out
}

fn percent_encode(s: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len());
    for &b in s {
        if b.is_ascii_alphanumeric() || b"/._~-".contains(&b) {
            out.push(b);
        } else {
            out.extend(format!("%{b:02X}").bytes());
        }
    }
    out
}

enum Info {
    Pipe(OwnedFd),
    Fifo(PathBuf, PathBuf, Vec<OsString>),
    Path(PathBuf),
}

/// The processes and everything below them, read from every thread's children, since any thread can fork.
fn descendants(roots: &[u32]) -> Vec<u32> {
    let mut seen = HashSet::new();
    let mut stack = roots.to_vec();
    while let Some(pid) = stack.pop() {
        if !seen.insert(pid) {
            continue;
        }
        let Ok(tasks) = fs::read_dir(format!("/proc/{pid}/task")) else { continue };
        for t in tasks.flatten() {
            if let Ok(kids) = fs::read_to_string(t.path().join("children")) {
                stack.extend(kids.split_whitespace().filter_map(|k| k.parse::<u32>().ok()));
            }
        }
    }
    seen.into_iter().collect()
}

fn is_zombie(pid: u32) -> bool {
    // The state follows the command name, which may itself hold parentheses.
    fs::read_to_string(format!("/proc/{pid}/stat")).is_ok_and(|s| s.rsplit_once(')').is_some_and(|(_, rest)| rest.trim_start().starts_with('Z')))
}

/// Helpers started before systemd moved this process are still in its old cgroup, with whatever they forked since.
/// Each round moves in every one found outside and reads the tree again, since one could fork between the read and its
/// move, until none is left. Whatever forks after its parent moved is born in the scope.
fn adopt(conn: &zbus::blocking::Connection, unit: &str, roots: &[u32]) -> Res<()> {
    let needle = format!("/{unit}");
    let mut error = String::from("its helpers kept forking");
    for _ in 0..8 {
        // A helper that already ended keeps its old cgroup until it is reaped and cannot be moved, its failure shows up where it is needed.
        let outside: Vec<u32> = descendants(roots)
            .into_iter()
            .filter(|p| !is_zombie(*p))
            .filter(|p| fs::read_to_string(format!("/proc/{p}/cgroup")).is_ok_and(|c| c.lines().any(|l| l.starts_with("0::") && !l.ends_with(&needle))))
            .collect();
        if outside.is_empty() {
            return Ok(());
        }
        // A process that exits before systemd looks fails the whole call, and the next read leaves it out.
        if let Err(e) = dbus::attach_to_scope(conn, unit, &outside) {
            error = e;
        }
    }
    Err(error)
}

/// Hands pasta's far side its bwrap arguments. Opened without blocking, so a far side that died instead of reading
/// cannot hang the launcher.
fn send_args(fifo: &Path, args: &[OsString], child: &mut Child) -> Res<()> {
    let deadline = Instant::now() + Duration::from_secs(10);
    let file = loop {
        match fs::OpenOptions::new().write(true).custom_flags(libc::O_NONBLOCK).open(fifo) {
            Ok(f) => break f,
            Err(e) if e.raw_os_error() == Some(libc::ENXIO) => {
                if child.try_wait().map(|s| s.is_some()).unwrap_or(true) {
                    fail!("the sandbox ended before it started");
                }
                if Instant::now() > deadline {
                    fail!("the sandbox never asked for its arguments");
                }
                std::thread::sleep(Duration::from_micros(200));
            }
            Err(e) => fail!("{}: {e}", fifo.display()),
        }
    };
    // Blocking again for the writes, a full FIFO otherwise fails a large command line with EAGAIN.
    unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETFL, 0) };
    let mut buf = Vec::new();
    for a in args {
        buf.extend_from_slice(a.as_bytes());
        buf.push(0);
    }
    (&file).write_all(&buf).map_err(|e| format!("{}: {e}", fifo.display()))
}

/// bwrap writes its pid and namespaces once the sandbox stands. Reading them on the side records the instance for
/// confine ps and enter, and for the portal, without holding up the app.
fn record_instance(info: Info, launch_pid: u32, state: PathBuf, flatpak_dir: Option<PathBuf>) {
    // A FIFO opened before its writer would read end-of-file at once, so this open waits for pasta's far side.
    let file = match info {
        Info::Pipe(fd) => fs::File::from(fd),
        Info::Path(path) | Info::Fifo(path, _, _) => match fs::File::open(&path) {
            Ok(f) => f,
            Err(_) => return,
        },
    };
    let mut text = String::new();
    if (&file).read_to_string(&mut text).is_err() || text.is_empty() {
        return;
    }
    let Ok(mut json) = serde_json::from_str::<serde_json::Value>(&text) else { return };
    let Some(want) = json.get("mnt-namespace").and_then(|v| v.as_u64()) else { return };
    let mut found = None;
    for _ in 0..40 {
        found = sandbox_pid(launch_pid, want);
        if found.is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    let Some(pid) = found else {
        warn!("confine: could not find the sandbox's pid");
        return;
    };
    if let Ok(mut f) = fs::OpenOptions::new().append(true).open(&state) {
        let _ = writeln!(f, "pid={pid}");
    }
    if let Some(dir) = flatpak_dir {
        // The portal opens a pidfd on child-pid, and since 1.19 a missing file fails the whole lookup.
        json["child-pid"] = pid.into();
        let _ = fs::write(dir.join("bwrapinfo.json"), json.to_string());
    }
}

/// bwrap names its first sandboxed process, but pasta puts a pid namespace in between, so the host pid is the first
/// descendant of the launch whose mount namespace is the sandbox's.
fn sandbox_pid(launch_pid: u32, want: u64) -> Option<u32> {
    let mut frontier = vec![launch_pid];
    for _ in 0..8 {
        let mut next = Vec::new();
        for pid in frontier {
            if fs::metadata(format!("/proc/{pid}/ns/mnt")).map(|m| m.ino()).ok() == Some(want) {
                return Some(pid);
            }
            if let Ok(kids) = fs::read_to_string(format!("/proc/{pid}/task/{pid}/children")) {
                next.extend(kids.split_whitespace().filter_map(|k| k.parse::<u32>().ok()));
            }
        }
        if next.is_empty() {
            return None;
        }
        frontier = next;
    }
    None
}

pub fn run(argv: &[OsString]) -> i32 {
    match launch(argv) {
        Ok(code) => code,
        Err(e) => {
            warn!("confine: {e}");
            1
        }
    }
}

fn launch(argv: &[OsString]) -> Res<i32> {
    sys::close_inherited().map_err(|e| format!("closing the descriptors the caller left open: {e}"))?;
    let script_path = argv[0].clone();
    let script = read_script(&script_path)?;
    let mut rest: Vec<OsString> = argv[1..].to_vec();
    let target = match script.target {
        Some(t) => t,
        None if !rest.is_empty() => rest.remove(0),
        None => fail!("no command to run"),
    };
    let config_text = fs::read(&script.config).map_err(|e| format!("{}: {e}", script.config.display()))?;
    let cfg: Config = serde_json::from_slice(&config_text).map_err(|e| format!("{}: {e}", script.config.display()))?;

    let dry = env_nonempty("CONFINE_DRY_RUN").is_some();
    let home = PathBuf::from(env_nonempty("HOME").ok_or("HOME is unset, refusing to guess where the sandbox lives")?);
    let (uid, gid) = (sys::uid(), sys::gid());
    let rt = env_nonempty("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(format!("/run/user/{uid}")));

    // Blocked before any thread starts, so the signals wait for the loop below and children get them unblocked.
    let mask = sys::handled_signals();
    sys::block(&mask).map_err(|e| e.to_string())?;

    // The sandbox shares its process group with whoever is in it at the start, and kill(0) inside reaches them all.
    // The foreground job of a terminal has to stay where the terminal reads and signals, anything else takes a group of its own, as Flatpak does.
    if !dry && !sys::in_terminal_foreground() {
        let _ = sys::own_process_group();
    }

    // The helpers die with the process that started them, so a child runs the sandbox to its end while this one returns once the app's main process ends, as `flatpak run` does.
    // No thread runs yet, which makes the fork safe.
    let (waiter, caller_group) = if dry {
        (None, None)
    } else {
        let (result_read, result_write) = sys::pipe().map_err(|e| e.to_string())?;
        let (caller, group) = (sys::pid(), sys::process_group());
        match sys::fork().map_err(|e| format!("fork: {e}"))? {
            0 => {
                drop(result_read);
                // Killed outright, the caller's side passes no signal on, so until the app's status is handed over its end arrives here as SIGTERM.
                sys::signal_on_parent_death(libc::SIGTERM).map_err(|e| e.to_string())?;
                if sys::parent_pid() != caller {
                    return Ok(128 + libc::SIGTERM);
                }
                // This process cleans up and audits, so it leaves the group the sandbox can signal.
                sys::own_process_group().and_then(|()| sys::block_terminal_stop()).map_err(|e| e.to_string())?;
                (Some(fs::File::from(result_write)), Some(group))
            }
            pid => {
                drop(result_write);
                return wait_for_supervisor(pid, result_read, &mask);
            }
        }
    };

    let (stdio, relay) = if dry {
        (None, None)
    } else {
        let keep = |fd| sys::dup_cloexec(fd).map_err(|e| e.to_string());
        let (read, write) = sys::pipe().map_err(|e| e.to_string())?;
        sys::set_nonblocking(read.as_raw_fd()).map_err(|e| e.to_string())?;
        (Some([keep(0)?, keep(1)?, keep(2)?]), Some((read, write)))
    };

    let mut bus = dbus::Bus::default();
    // A scope of its own lets the whole app be listed, stopped and limited as one unit, as Flatpak's app-flatpak-*.scope
    // does. Flatpak runs on without one, and so does confine unless the scope carries resource limits.
    let mut scope = None;
    if cfg.scope && !dry {
        let unit = format!("app-confine-{}-{}.scope", cfg.app_id, sys::pid());
        // Helpers started before systemd moves this process join the scope by pid, which means the same to systemd only
        // from its own pid namespace.
        let adopt = sys::in_initial_pid_namespace() && (cfg.dbus.filter || cfg.network == Network::Isolated);
        let started = match bus.get() {
            Some(conn) => dbus::start_scope(conn, &unit, &format!("{} (confined)", cfg.name), &cfg.resources, adopt),
            None => Err(dbus::ScopeError::Unreachable),
        };
        match started {
            Ok(()) => scope = Some(Scope { unit, adopt }),
            Err(e) if !cfg.resources.is_empty() => fail!("refusing to start without the scope that carries the resource limits: {e}"),
            // A nested launch sees no user manager through its parent's proxy and stays in its parent's scope.
            Err(dbus::ScopeError::Unreachable) => {}
            Err(e) => warn!("confine: running without a scope: {e}"),
        }
    }

    // Only a declared setup may run outside bwrap, never a path from the environment.
    let setup = match env::var("CONFINE_NETWORK_SETUP") {
        Ok(n) if !n.is_empty() => match cfg.network_setups.get(&n) {
            Some(p) => Some(p.clone()),
            None => fail!("{} has no network setup named {n}", cfg.app_id),
        },
        _ => None,
    };

    let confine_dir = rt.join("confine");
    fs::create_dir_all(&confine_dir).map_err(|e| format!("{}: {e}", confine_dir.display()))?;
    if cfg.portals {
        let _ = fs::create_dir_all(rt.join(".flatpak"));
    }
    // Random ids claimed by an atomic mkdir, as Flatpak allocates its own, so neither another instance nor a real Flatpak sharing .flatpak can collide.
    let mut claimed = None;
    for _ in 0..100 {
        let id = sys::random_u32();
        let dir = confine_dir.join(format!("{}.{id}", cfg.app_id));
        if fs::DirBuilder::new().mode(0o700).create(&dir).is_err() {
            continue;
        }
        if cfg.portals {
            let fdir = rt.join(".flatpak").join(id.to_string());
            if fs::DirBuilder::new().mode(0o700).create(&fdir).is_err() {
                let _ = fs::remove_dir(&dir);
                continue;
            }
            claimed = Some((id, dir, Some(fdir)));
        } else {
            claimed = Some((id, dir, None));
        }
        break;
    }
    let (id, instance, flatpak_dir) = claimed.ok_or("could not allocate an instance id")?;

    let mut l = Launch {
        cfg: &cfg,
        script: script_path,
        home,
        rt,
        uid,
        gid,
        id,
        instance,
        flatpak_dir,
        args: Vec::with_capacity(256),
        rw_roots: Vec::new(),
        visible: vec![],
        pinned: HashSet::new(),
        launch_dir: None,
        git_guarded: HashSet::new(),
        removals: Vec::new(),
        helpers: Vec::new(),
        holds: Vec::new(),
        pending: Pending::default(),
        pasta_args: Vec::new(),
        bus,
        setup,
        dry,
        waiter,
        caller_group,
        stdio,
        relay,
        stdio_socket: None,
    };
    let result = l.body(scope, target, rest, &mask);
    l.cleanup();
    result
}

/// The caller's side passes SIGTERM and SIGHUP on as the launcher always did, outlives SIGINT and SIGQUIT, and ends with the app's status once the sandbox's process hands it over or ends.
fn wait_for_supervisor(pid: libc::pid_t, result: OwnedFd, mask: &libc::sigset_t) -> Res<i32> {
    let result = fs::File::from(result);
    let sigfd = sys::signalfd(mask).map_err(|e| e.to_string())?;
    let mut stopped_by = None;
    loop {
        let ready = sys::poll_readable(&[result.as_raw_fd(), sigfd.as_raw_fd()], -1).map_err(|e| e.to_string())?;
        if ready[1] {
            if let Some(sig) = sys::read_signal(&sigfd) {
                if sig == libc::SIGTERM || sig == libc::SIGHUP {
                    sys::kill(pid as u32, sig);
                    stopped_by.get_or_insert(sig);
                }
            }
        }
        if ready[0] {
            let mut byte = [0u8; 1];
            match (&result).read(&mut byte) {
                Ok(1) if stopped_by.is_none() => return Ok(byte[0].into()),
                Ok(1) => {}
                _ => break,
            }
        }
    }
    let (_, status) = sys::waitpid(pid, 0).map_err(|e| e.to_string())?;
    Ok(match stopped_by {
        Some(sig) => 128 + sig,
        None => sys::exit_code(status),
    })
}

impl<'a> Launch<'a> {
    fn body(&mut self, scope: Option<Scope>, target: OsString, rest: Vec<OsString>, mask: &libc::sigset_t) -> Res<i32> {
        let cfg = self.cfg;
        let state = format!(
            "app={}\nname={}\nlauncher={}\nlauncher_pid={}\nscope={}\nstarted={}\nfilter={}\n",
            cfg.app_id,
            cfg.name,
            Path::new(&self.script).display(),
            sys::pid(),
            scope.as_ref().map(|s| s.unit.as_str()).unwrap_or(""),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0),
            cfg.filter.as_deref().unwrap_or("")
        );
        fs::write(self.instance_path("state"), state).map_err(|e| e.to_string())?;
        if cfg.portals {
            // The portal reads the network share from here and reports an app without it as offline.
            let context = if cfg.network == Network::None { "" } else { "\n[Context]\nshared=network;\n" };
            let info = format!(
                "[Application]\nname={}\n\n[Instance]\ninstance-id={}\nsession-bus-proxy={}\nsystem-bus-proxy={}\n{context}",
                cfg.app_id,
                self.id,
                cfg.dbus.filter,
                cfg.dbus.filter && cfg.dbus.system_args.is_some()
            );
            fs::write(self.instance_path("flatpak-info"), info).map_err(|e| e.to_string())?;
        }

        self.visible.push(self.rt.join("doc"));
        self.prepare_dbus_proxy();
        self.prepare_pasta()?;

        // The D-Bus proxy and pasta take a few milliseconds to come up, as does systemd to move this process into the
        // scope, so they start at once and the command line is built meanwhile. They join the scope once this process
        // is in it, and pasta's far side waits for its arguments until then, so the app lands there too.
        let early = !self.dry && scope.as_ref().is_none_or(|s| s.adopt);
        let mut slow = if early { self.spawn_slow_helpers()? } else { SlowHelpers::default() };
        self.build()?;
        if let Some(s) = &scope {
            self.enter_scope(s, &slow.pids)?;
        }
        if !self.dry && !early {
            slow = self.spawn_slow_helpers()?;
        }
        let rest = self.forward(rest);

        if self.dry {
            let to_json = |v: &[OsString]| serde_json::Value::from(v.iter().map(|a| a.to_string_lossy().into_owned()).collect::<Vec<_>>());
            let mut plan = serde_json::json!({ "bwrap": to_json(&self.args), "target": target.to_string_lossy(), "args": to_json(&rest) });
            if cfg.network == Network::Isolated {
                plan["pasta"] = to_json(&self.pasta_args);
            }
            if let Some((sat, _)) = &self.pending.satellite {
                plan["satellite"] = to_json(sat);
            }
            if let Some(p) = &self.pending.dbus_proxy {
                plan["dbusProxy"] = to_json(p);
            }
            let _ = writeln!(std::io::stdout(), "{plan}");
            return Ok(0);
        }

        self.start_display_helpers()?;
        if let Some(ready) = slow.proxy_ready.take() {
            self.finish_dbus_proxy(ready)?;
        }

        // With the reaper as pid 1 instead of bwrap's own init, bwrap waits for the last process rather than the first.
        let mut bwrap_args = self.args.clone();
        bwrap_args.extend(["--as-pid-1".into(), "--".into()]);
        bwrap_args.push(env::current_exe().map_err(|e| e.to_string())?.into());
        bwrap_args.extend(["--reap".into(), if cfg.linger { STATUS_FD.to_string().into() } else { "-".into() }, target]);
        bwrap_args.extend(rest);

        let (mut child, info, status) = if let Some((child, args_fifo, status)) = slow.pasta.take() {
            (child, Info::Fifo(self.instance_path("info"), args_fifo, bwrap_args), status)
        } else {
            let (info_read, info_write) = sys::pipe().map_err(|e| e.to_string())?;
            let status = if cfg.linger { Some(sys::pipe().map_err(|e| e.to_string())?) } else { None };
            let filter_fd = match &cfg.filter {
                Some(f) => Some(fs::File::open(f).map_err(|e| format!("{f}: {e}"))?),
                None => None,
            };
            let mut c = self.sandbox_command(&cfg.tools.bwrap);
            let mut pairs = vec![(info_write.as_raw_fd(), 11)];
            pairs.extend(status.as_ref().map(|(_, write)| (write.as_raw_fd(), STATUS_FD)));
            pairs.extend(self.stdio.iter().flatten().zip(STDIO_FD..).map(|(fd, at)| (fd.as_raw_fd(), at)));
            if let Some(f) = &filter_fd {
                c.args(["--seccomp", "10"]);
                pairs.push((f.as_raw_fd(), 10));
            }
            c.args(["--info-fd", "11"]).args(&bwrap_args);
            unsafe { c.pre_exec(move || sys::remap_fds(&pairs)) };
            let child = c.spawn().map_err(|e| format!("bwrap: {e}"))?;
            drop(info_write);
            (child, Info::Pipe(info_read), status.map(|(read, _)| fs::File::from(read)))
        };

        let info = match info {
            Info::Fifo(info_fifo, args_fifo, args) => {
                if let Err(e) = send_args(&args_fifo, &args, &mut child) {
                    sys::kill(child.id(), libc::SIGKILL);
                    let _ = child.wait();
                    fail!("{e}");
                }
                Info::Path(info_fifo)
            }
            other => other,
        };

        let launch_pid = child.id();
        let state = self.instance_path("state");
        let fdir = self.flatpak_dir.clone();
        std::thread::spawn(move || record_instance(info, launch_pid, state, fdir));

        self.wait(child, status, mask)
    }

    /// SIGINT and SIGQUIT come from the terminal, which sends them to the app too, so the launcher only outlives them.
    /// SIGTERM and SIGHUP go to the launcher alone and are passed on, and the launcher then ends as the signal would
    /// have ended it, since pasta, the child for an isolated network, exits cleanly on SIGTERM.
    /// A status byte from the reaper means the app ended while others run on, which the caller hears of at once.
    fn wait(&mut self, mut child: Child, mut status: Option<fs::File>, mask: &libc::sigset_t) -> Res<i32> {
        let pidfd = sys::pidfd_open(child.id()).map_err(|e| e.to_string())?;
        let sigfd = sys::signalfd(mask).map_err(|e| e.to_string())?;
        let mut stopped_by = None;
        loop {
            let mut fds = vec![pidfd.as_raw_fd(), sigfd.as_raw_fd()];
            let mut watch = |fd: Option<i32>| {
                fds.extend(fd);
                fd.map(|_| fds.len() - 1)
            };
            let relay_at = watch(self.relay.as_ref().map(|(read, _)| read.as_raw_fd()));
            let status_at = watch(status.as_ref().map(|s| s.as_raw_fd()));
            let socket_at = watch(self.stdio_socket.as_ref().map(|s| s.as_raw_fd()));
            let ready = sys::poll_readable(&fds, -1).map_err(|e| e.to_string())?;
            let is_ready = |at: Option<usize>| at.is_some_and(|i| ready[i]);
            if ready[1] {
                if let Some(sig) = sys::read_signal(&sigfd) {
                    if sig == libc::SIGTERM || sig == libc::SIGHUP {
                        sys::kill(child.id(), sig);
                        stopped_by.get_or_insert(sig);
                    }
                }
            }
            if is_ready(relay_at) {
                self.drain_relay();
            }
            if is_ready(socket_at) {
                self.pass_stdio();
            }
            if is_ready(status_at) {
                let mut byte = [0u8; 1];
                if status.take().is_some_and(|s| (&s).read(&mut byte).ok() == Some(1)) {
                    self.drain_relay();
                    if let Some(mut waiter) = self.waiter.take() {
                        // The caller's side ends on its own from here, and what the app left running outlives it.
                        let _ = sys::signal_on_parent_death(0);
                        let _ = waiter.write_all(&byte);
                    }
                    // Nothing outside the sandbox may hold the caller's output open past the launch.
                    self.stdio = None;
                    self.stdio_socket = None;
                    sys::release_stdio();
                }
            }
            if ready[0] {
                break;
            }
        }
        let status = child.wait().map_err(|e| e.to_string())?;
        Ok(match stopped_by {
            Some(sig) => 128 + sig,
            None => status.code().unwrap_or_else(|| 128 + status.signal().unwrap_or(0)),
        })
    }
}

/// Runs on pasta's far side: Usage: confine-launch --inner SETUP FILTER INFO STATUS BWRAP ARGS_FIFO STDIO_SOCKET
pub fn inner(args: &[OsString]) -> i32 {
    if args.len() != 7 {
        warn!("confine: bad --inner call");
        return 2;
    }
    let (setup, filter, info, status, bwrap, args_fifo, stdio) = (&args[0], &args[1], &args[2], &args[3], &args[4], &args[5], &args[6]);
    // pasta blocks SIGUSR1 for its own start and leaves it so for what it runs.
    if let Err(e) = sys::block_only_terminal_interrupts() {
        warn!("confine: {e}");
        return 1;
    }
    // A launcher that fails before sending the arguments takes pasta with it, and this then goes too instead of waiting.
    if let Err(e) = sys::die_with_parent() {
        warn!("confine: {e}");
        return 1;
    }
    // The arguments arrive once the launcher moved this process into the app's scope, so the setup below runs in it too.
    let mut raw = Vec::new();
    if let Err(e) = fs::File::open(args_fifo).and_then(|mut f| f.read_to_end(&mut raw)) {
        warn!("confine: {}: {e}", Path::new(args_fifo).display());
        return 1;
    }
    if raw.is_empty() {
        return 1;
    }
    if !setup.is_empty() {
        match Command::new(setup).status() {
            Ok(s) if s.success() => {}
            _ => return 1,
        }
    }
    // pasta closed what it inherited, so the caller's stdin, stdout and stderr come over a socket and wait where the reaper takes them from.
    if !stdio.is_empty() {
        let placed = UnixStream::connect(stdio)
            .and_then(|socket| sys::recv_fds(socket.as_raw_fd()))
            .and_then(|fds| sys::remap_fds(&[(fds[0].as_raw_fd(), STDIO_FD), (fds[1].as_raw_fd(), STDIO_FD + 1), (fds[2].as_raw_fd(), STDIO_FD + 2)]));
        if let Err(e) = placed {
            warn!("confine: {}: {e}", Path::new(stdio).display());
            return 1;
        }
    }
    // Before the descriptors opened below, so none of them can take its number. None for a sandbox that ends with its app.
    if !status.is_empty() {
        if let Err(e) = sys::open_inheritable(status, libc::O_WRONLY).and_then(|fd| sys::move_fd(fd, STATUS_FD)) {
            warn!("confine: {}: {e}", Path::new(status).display());
            return 1;
        }
    }
    let mut final_args: Vec<OsString> = Vec::new();
    if !filter.is_empty() {
        match sys::open_inheritable(filter, libc::O_RDONLY) {
            Ok(fd) => final_args.extend(["--seccomp".into(), fd.to_string().into()]),
            Err(e) => {
                warn!("confine: {}: {e}", Path::new(filter).display());
                return 1;
            }
        }
    }
    match sys::open_inheritable(info, libc::O_WRONLY) {
        Ok(fd) => final_args.extend(["--info-fd".into(), fd.to_string().into()]),
        Err(e) => {
            warn!("confine: {}: {e}", Path::new(info).display());
            return 1;
        }
    }
    final_args.extend(raw.strip_suffix(&[0]).unwrap_or(&raw).split(|b| *b == 0).map(|a| OsStr::from_bytes(a).to_os_string()));
    let e = sys::exec(bwrap, &final_args);
    warn!("confine: {}: {e}", Path::new(bwrap).display());
    127
}

struct Account {
    name: String,
    gecos: String,
    dir: PathBuf,
}

/// The account files first, since a lookup through the NSS daemon can take tens of milliseconds, the daemon only for
/// accounts the files do not list.
fn lookup_user(uid: u32) -> Option<Account> {
    if let Ok(text) = fs::read_to_string("/etc/passwd") {
        for line in text.lines() {
            let f: Vec<&str> = line.split(':').collect();
            if f.len() >= 7 && f[2].parse::<u32>().ok() == Some(uid) {
                return Some(Account { name: f[0].into(), gecos: f[4].into(), dir: f[5].into() });
            }
        }
    }
    User::from_uid(Uid::from_raw(uid)).ok().flatten().map(|u| Account { name: u.name, gecos: u.gecos.to_string_lossy().into_owned(), dir: u.dir })
}

fn lookup_group(gid: u32) -> Option<String> {
    if let Ok(text) = fs::read_to_string("/etc/group") {
        for line in text.lines() {
            let f: Vec<&str> = line.split(':').collect();
            if f.len() >= 3 && f[2].parse::<u32>().ok() == Some(gid) {
                return Some(f[0].into());
            }
        }
    }
    Group::from_gid(Gid::from_raw(gid)).ok().flatten().map(|g| g.name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_decoding_leaves_broken_escapes_alone() {
        assert_eq!(percent_decode(b"a%20b"), b"a b");
        assert_eq!(percent_decode(b"%41"), b"A");
        assert_eq!(percent_decode(b"x%"), b"x%");
        assert_eq!(percent_decode(b"x%4"), b"x%4");
        assert_eq!(percent_decode(b"%zz%41"), b"%zzA");
    }

    #[test]
    fn percent_encoding_round_trips() {
        for path in [&b"/home/u/My File.txt"[..], b"/tmp/100%/#?&", "/tmp/caf\u{e9}".as_bytes(), b"/a/\xff\x00b"] {
            let encoded = percent_encode(path);
            assert!(encoded.iter().all(|b| b.is_ascii_alphanumeric() || b"/._~-%".contains(b)));
            assert_eq!(percent_decode(&encoded), path);
        }
    }

    #[test]
    fn bus_addresses_give_up_their_socket_file() {
        assert_eq!(bus_socket(OsStr::new("unix:path=/run/user/1000/bus")), Some(PathBuf::from("/run/user/1000/bus")));
        assert_eq!(bus_socket(OsStr::new("unix:path=/run/user/1000/at-spi/bus_0,guid=abc")), Some(PathBuf::from("/run/user/1000/at-spi/bus_0")));
        assert_eq!(bus_socket(OsStr::new("unix:abstract=/tmp/dbus-x")), None);
        assert_eq!(bus_socket(OsStr::new("tcp:host=localhost,port=1")), None);
        assert_eq!(bus_socket(OsStr::new("unix:path=/a;unix:path=/b")), None);
    }

    #[test]
    fn scripts_name_their_config_and_target() {
        let dir = env::temp_dir().join(format!("confine-launch-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("app");
        fs::write(&path, "#!/nix/store/x/bin/confine-launch\nconfig /nix/store/y.json\ntarget /nix/store/z/bin/app\n").unwrap();
        let s = read_script(path.as_os_str()).ok().unwrap();
        assert_eq!(s.config, Path::new("/nix/store/y.json"));
        assert_eq!(s.target.as_deref(), Some(OsStr::new("/nix/store/z/bin/app")));
        fs::write(&path, "#!/nix/store/x/bin/confine-launch\ntarget /bin/app\n").unwrap();
        assert!(read_script(path.as_os_str()).is_err());
        fs::remove_dir_all(&dir).unwrap();
    }
}
