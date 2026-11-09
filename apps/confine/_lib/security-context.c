#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <wayland-client.h>

#include "security-context-v1-client-protocol.h"

static struct wp_security_context_manager_v1 *manager;

static void
registry_global (void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version)
{
  (void) data;
  (void) version;
  if (strcmp (interface, wp_security_context_manager_v1_interface.name) == 0)
    manager = wl_registry_bind (registry, name, &wp_security_context_manager_v1_interface, 1);
}

static void
registry_global_remove (void *data, struct wl_registry *registry, uint32_t name)
{
  (void) data;
  (void) registry;
  (void) name;
}

static const struct wl_registry_listener registry_listener = { registry_global, registry_global_remove };

int
main (int argc, char **argv)
{
  if (argc != 5)
    {
      fprintf (stderr, "usage: confine-security-context SOCKET ENGINE APP_ID INSTANCE_ID\n");
      return 2;
    }

  /* The context must not outlive the launcher, a stray one would keep accepting clients. */
  pid_t parent = getppid ();
  if (prctl (PR_SET_PDEATHSIG, SIGTERM) != 0 || getppid () != parent)
    return 1;

  struct sockaddr_un addr = { .sun_family = AF_UNIX };
  if (strlen (argv[1]) >= sizeof addr.sun_path)
    {
      fprintf (stderr, "confine-security-context: socket path too long: %s\n", argv[1]);
      return 1;
    }
  strcpy (addr.sun_path, argv[1]);

  int listen_fd = socket (AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  unlink (argv[1]);
  if (listen_fd < 0 || bind (listen_fd, (struct sockaddr *) &addr, sizeof addr) != 0
      || listen (listen_fd, SOMAXCONN) != 0)
    {
      perror ("confine-security-context: listening socket");
      return 1;
    }

  /* The compositor stops accepting on listen_fd once the write end, kept by this process, closes. */
  int close_fds[2];
  if (pipe2 (close_fds, O_CLOEXEC) != 0)
    {
      perror ("confine-security-context: pipe");
      return 1;
    }

  struct wl_display *display = wl_display_connect (NULL);
  if (display == NULL)
    {
      fprintf (stderr, "confine-security-context: cannot connect to the Wayland compositor\n");
      return 1;
    }
  struct wl_registry *registry = wl_display_get_registry (display);
  wl_registry_add_listener (registry, &registry_listener, NULL);
  if (wl_display_roundtrip (display) < 0)
    {
      fprintf (stderr, "confine-security-context: the compositor connection failed\n");
      return 1;
    }
  if (manager == NULL)
    {
      fprintf (stderr, "confine-security-context: the compositor offers no wp_security_context_manager_v1\n");
      return 3;
    }

  struct wp_security_context_v1 *context
    = wp_security_context_manager_v1_create_listener (manager, listen_fd, close_fds[0]);
  wp_security_context_v1_set_sandbox_engine (context, argv[2]);
  wp_security_context_v1_set_app_id (context, argv[3]);
  wp_security_context_v1_set_instance_id (context, argv[4]);
  wp_security_context_v1_commit (context);
  wp_security_context_v1_destroy (context);
  if (wl_display_roundtrip (display) < 0)
    {
      fprintf (stderr, "confine-security-context: the compositor refused the security context\n");
      return 1;
    }

  close (listen_fd);
  close (close_fds[0]);
  wl_display_disconnect (display);

  if (printf ("ready\n") < 0 || fflush (stdout) != 0)
    return 1;

  for (;;)
    pause ();
}
