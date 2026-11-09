#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/personality.h>
#include <sys/ptrace.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef TIOCSTI
# define TIOCSTI 0x5412
#endif
#ifndef TIOCLINUX
# define TIOCLINUX 0x541C
#endif
#ifndef AF_PACKET
# define AF_PACKET 17
#endif
#ifndef SYS_clone3
# define SYS_clone3 435
#endif
#ifndef SYS_open_tree
# define SYS_open_tree 428
#endif
#ifndef SYS_io_uring_setup
# define SYS_io_uring_setup 425
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
    case EBADF:        return "EBADF";
    default:           return "other";
    }
}

#ifdef __i386__
/* The multiplexed path older i386 libcs take, which hides the family behind a pointer seccomp cannot follow. */
static long
socketcall_socket (int family, int type)
{
  unsigned long args[3] = { (unsigned long) family, (unsigned long) type, 0 };

  return syscall (SYS_socketcall, 1 /* SYS_SOCKET */, args);
}
#endif

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
    /* Unfiltered this is EINVAL, the filter answers ENOSYS so libc falls back to clone(). */
    rc = syscall (SYS_clone3, NULL, 0);
  else if (strcmp (argv[1], "tiocsti") == 0)
    rc = ioctl (0, TIOCSTI, "x");
  else if (strcmp (argv[1], "tioclinux") == 0)
    {
      char subcode = 6; /* TIOCL_GETSHIFTSTATE, which only reads. */

      rc = ioctl (0, TIOCLINUX, &subcode);
    }
  else if (strcmp (argv[1], "open_tree") == 0)
    /* Without OPEN_TREE_CLONE this is an O_PATH open that needs no privilege. */
    rc = syscall (SYS_open_tree, AT_FDCWD, "/", 0);
  else if (strcmp (argv[1], "setns") == 0)
    /* Unfiltered the kernel rejects the descriptor with EBADF. */
    rc = setns (-1, 0);
  else if (strcmp (argv[1], "personality") == 0)
    rc = personality (PER_BSD);
#ifdef SYS_modify_ldt
  else if (strcmp (argv[1], "modify_ldt") == 0)
    {
      char ldt[16];

      rc = syscall (SYS_modify_ldt, 0 /* read */, ldt, sizeof ldt);
    }
#endif
  else if (strcmp (argv[1], "socket_packet") == 0)
    rc = socket (AF_PACKET, SOCK_DGRAM, 0);
  else if (strcmp (argv[1], "socket_inet") == 0)
    rc = socket (AF_INET, SOCK_STREAM, 0);
  /* No bluetooth probe, the build sandbox's network namespace refuses AF_BLUETOOTH so every variant would answer EAFNOSUPPORT. */
  else if (strcmp (argv[1], "socket_can") == 0)
    rc = socket (AF_CAN, SOCK_RAW, 1 /* CAN_RAW */);
#ifdef __i386__
  else if (strcmp (argv[1], "socketcall_inet") == 0)
    rc = socketcall_socket (AF_INET, SOCK_STREAM);
  else if (strcmp (argv[1], "socketcall_packet") == 0)
    rc = socketcall_socket (AF_PACKET, SOCK_DGRAM);
#endif
  else if (strcmp (argv[1], "ptrace") == 0)
    rc = ptrace (PTRACE_TRACEME, 0, NULL, NULL);
  else if (strcmp (argv[1], "io_uring") == 0)
    /* A NULL params pointer makes a reachable io_uring_setup fail with EFAULT before it creates anything. */
    rc = syscall (SYS_io_uring_setup, 1, NULL);
  else
    {
      fprintf (stderr, "confine-seccomp-probe: unknown probe %s\n", argv[1]);
      return 2;
    }

  printf ("%s\n", rc >= 0 ? "ok" : errname ());
  return 0;
}
