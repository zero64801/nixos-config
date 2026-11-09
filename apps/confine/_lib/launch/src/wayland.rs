//! The Wayland security context that tells the compositor this client is sandboxed.

use crate::sys;
use std::os::fd::{AsFd, OwnedFd};
use std::os::unix::net::UnixListener;
use std::path::Path;
use wayland_client::globals::{registry_queue_init, GlobalListContents};
use wayland_client::protocol::wl_registry::{self, WlRegistry};
use wayland_client::{delegate_noop, Connection, Dispatch, QueueHandle};
use wayland_protocols::wp::security_context::v1::client::wp_security_context_manager_v1::WpSecurityContextManagerV1;
use wayland_protocols::wp::security_context::v1::client::wp_security_context_v1::WpSecurityContextV1;

struct State;

impl Dispatch<WlRegistry, GlobalListContents> for State {
    fn event(_: &mut Self, _: &WlRegistry, _: wl_registry::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<Self>) {}
}

delegate_noop!(State: WpSecurityContextManagerV1);
delegate_noop!(State: WpSecurityContextV1);

/// Makes the compositor listen on `socket` for this app alone. The listener lives until the returned descriptor
/// closes, which the launcher holds for the app's lifetime, the way Flatpak's own context is tied to the sandbox.
pub fn create_context(socket: &Path, app_id: &str, instance_id: &str) -> Result<OwnedFd, String> {
    let conn = Connection::connect_to_env().map_err(|e| e.to_string())?;
    let (globals, mut queue) = registry_queue_init::<State>(&conn).map_err(|e| e.to_string())?;
    let qh = queue.handle();
    let manager: WpSecurityContextManagerV1 = globals.bind(&qh, 1..=1, ()).map_err(|_| "the compositor offers no security context".to_string())?;

    let _ = std::fs::remove_file(socket);
    let listener = UnixListener::bind(socket).map_err(|e| format!("{}: {e}", socket.display()))?;
    let (close_read, close_write) = sys::pipe().map_err(|e| e.to_string())?;

    let context = manager.create_listener(listener.as_fd(), close_read.as_fd(), &qh, ());
    context.set_sandbox_engine("confine".into());
    context.set_app_id(app_id.into());
    context.set_instance_id(instance_id.into());
    context.commit();
    context.destroy();
    manager.destroy();
    queue.roundtrip(&mut State).map_err(|e| e.to_string())?;
    Ok(close_write)
}
