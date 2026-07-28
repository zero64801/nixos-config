/* One syscall per run, so no probe can affect the next. */

#define _GNU_SOURCE

#include <errno.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/ptrace.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef TIOCSTI
# define TIOCSTI 0x5412
#endif
#ifndef AF_PACKET
# define AF_PACKET 17
#endif
#ifndef SYS_clone3
# define SYS_clone3 435
#endif

static const char *
errname (void)
{
  switch (errno)
    {
    case EPERM:        return "EPERM";
    case ENOSYS:       return "ENOSYS";
    case EAFNOSUPPORT: return "EAFNOSUPPORT";
    case ENOTTY:       return "ENOTTY";
    case EINVAL:       return "EINVAL";
    case EACCES:       return "EACCES";
    case EFAULT:       return "EFAULT";
    default:           return "other";
    }
}

int
main (int argc, char **argv)
{
  long rc;

  if (argc != 2)
    {
      fprintf (stderr, "usage: confine-seccomp-probe NAME\n");
      return 2;
    }

  errno = 0;

  if (strcmp (argv[1], "keyctl") == 0)
    /* KEYCTL_GET_KEYRING_ID on the thread keyring, which normally succeeds. */
    rc = syscall (SYS_keyctl, 0, -1, 1);
  else if (strcmp (argv[1], "userns") == 0)
    rc = unshare (CLONE_NEWUSER);
  else if (strcmp (argv[1], "clone3") == 0)
    /* Unfiltered this is EINVAL, the filter answers ENOSYS so libc falls
     * back to clone(). */
    rc = syscall (SYS_clone3, NULL, 0);
  else if (strcmp (argv[1], "tiocsti") == 0)
    rc = ioctl (0, TIOCSTI, "x");
  else if (strcmp (argv[1], "socket_packet") == 0)
    rc = socket (AF_PACKET, SOCK_DGRAM, 0);
  else if (strcmp (argv[1], "socket_inet") == 0)
    rc = socket (AF_INET, SOCK_STREAM, 0);
  /* No bluetooth probe: the build sandbox's network namespace refuses
   * AF_BLUETOOTH, so every variant would answer EAFNOSUPPORT. */
  else if (strcmp (argv[1], "socket_can") == 0)
    rc = socket (AF_CAN, SOCK_RAW, 1 /* CAN_RAW */);
  else if (strcmp (argv[1], "ptrace") == 0)
    rc = ptrace (PTRACE_TRACEME, 0, NULL, NULL);
  else
    {
      fprintf (stderr, "confine-seccomp-probe: unknown probe %s\n", argv[1]);
      return 2;
    }

  printf ("%s\n", rc >= 0 ? "ok" : errname ());
  return 0;
}
