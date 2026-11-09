use serde::Deserialize;
use std::collections::BTreeMap;

/// Everything the launcher needs about one app, written by wrap.nix at build time.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Config {
    pub app_id: String,
    pub name: String,
    pub context_app_id: String,
    pub data_dirs_prefix: String,
    pub tools: Tools,
    pub static_args: Vec<String>,
    pub filter: Option<String>,
    pub network: Network,
    pub pasta_args: Vec<String>,
    pub network_setups: BTreeMap<String, String>,
    pub wayland: bool,
    pub wayland_proxy: bool,
    pub security_context: bool,
    pub x11: X11,
    pub pipewire: bool,
    pub pulse: bool,
    pub gpu: bool,
    pub sysfs: bool,
    pub sysfs_dirs: Vec<String>,
    pub portals: bool,
    pub home: Home,
    pub host_accounts: bool,
    pub devices: Vec<String>,
    pub security_keys: bool,
    pub binds_rw: Vec<Bind>,
    pub binds_ro: Vec<Bind>,
    pub symlinks: Vec<Symlink>,
    pub runtime_dir: RuntimeDir,
    pub workdir: Option<Workdir>,
    pub git_guard: GitGuard,
    pub dbus: Dbus,
    pub env: Vec<(String, String)>,
    pub env_passthrough: Vec<String>,
    pub host_env: Vec<String>,
    pub gpu_env: Vec<String>,
    pub masked_files: Vec<String>,
    pub masked_dirs: Vec<String>,
    pub scope: bool,
    pub resources: Vec<(String, String)>,
    pub extra_bwrap_args: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Tools {
    pub bwrap: String,
    pub pasta: Option<String>,
    pub dbus_proxy: Option<String>,
    pub satellite: Option<String>,
    pub wayland_proxy: Option<String>,
}

#[derive(Deserialize, PartialEq, Eq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum Network {
    None,
    Host,
    Isolated,
}

#[derive(Deserialize, PartialEq, Eq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum X11 {
    None,
    Host,
    Isolated,
}

#[derive(Deserialize, PartialEq, Eq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum Home {
    Private,
    Ephemeral,
    Host,
}

#[derive(Deserialize, PartialEq, Eq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum RuntimeDir {
    Private,
    Shared,
}

#[derive(Deserialize, PartialEq, Eq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum Workdir {
    Ro,
    Rw,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Bind {
    pub from: String,
    pub to: String,
    pub pattern: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Symlink {
    pub link: String,
    pub target: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GitGuard {
    pub enable: bool,
    pub depth: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Dbus {
    pub filter: bool,
    pub session_args: Vec<String>,
    pub system_args: Option<Vec<String>>,
    pub a11y_args: Option<Vec<String>>,
}
