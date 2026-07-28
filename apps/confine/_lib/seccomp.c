/* Port of Flatpak's setup_seccomp() from common/flatpak-run.c. Emits compiled
 * BPF to stdout so the filter is a fixed store path, not rebuilt per launch. */

#define _GNU_SOURCE

#include <errno.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/personality.h>
#include <sys/socket.h>
#include <unistd.h>

#include <seccomp.h>

#ifndef TIOCSTI
# define TIOCSTI 0x5412
#endif
#ifndef TIOCLINUX
# define TIOCLINUX 0x541C
#endif

static scmp_filter_ctx ctx;

static void
fail (const char *what, int err)
{
  fprintf (stderr, "confine-seccomp: %s: %s\n", what, strerror (err < 0 ? -err : err));
  exit (1);
}

/* A syscall libseccomp cannot name cannot be issued either, skipping is safe. */
static int
tolerable (int r)
{
  return r == 0 || r == -EFAULT || r == -EDOM;
}

static void
block (int errnum, int syscall_nr)
{
  int r = seccomp_rule_add (ctx, SCMP_ACT_ERRNO (errnum), syscall_nr, 0);
  if (!tolerable (r))
    fail ("seccomp_rule_add", r);
}

static void
block_arg (int errnum, int syscall_nr, struct scmp_arg_cmp arg)
{
  int r = seccomp_rule_add (ctx, SCMP_ACT_ERRNO (errnum), syscall_nr, 1, arg);
  if (!tolerable (r))
    fail ("seccomp_rule_add", r);
}

/* _exact avoids the i386 socketcall rewrite that fails open (libseccomp issue #8).
 * Errors ignored as upstream, so under --multiarch this covers the 64-bit arch only. */
static void
block_family (int family)
{
  seccomp_rule_add_exact (ctx, SCMP_ACT_ERRNO (EAFNOSUPPORT),
                          SCMP_SYS (socket), 1,
                          SCMP_A0 (SCMP_CMP_EQ, family));
}

static void
block_families_from (int family)
{
  seccomp_rule_add_exact (ctx, SCMP_ACT_ERRNO (EAFNOSUPPORT),
                          SCMP_SYS (socket), 1,
                          SCMP_A0 (SCMP_CMP_GE, family));
}

static void
usage (void)
{
  fprintf (stderr,
           "usage: confine-seccomp [--allow-nesting] [--devel] [--multiarch]\n"
           "                       [--allow-bluetooth] [--allow-can]\n");
  exit (1);
}

int
main (int argc, char **argv)
{
  int nesting = 0, devel = 0, multiarch = 0, bluetooth = 0, can = 0;
  int allowed[8], n_allowed = 0;
  int i, family, r;

  for (i = 1; i < argc; i++)
    {
      if (strcmp (argv[i], "--allow-nesting") == 0)
        nesting = 1;
      else if (strcmp (argv[i], "--devel") == 0)
        devel = 1;
      else if (strcmp (argv[i], "--multiarch") == 0)
        multiarch = 1;
      else if (strcmp (argv[i], "--allow-bluetooth") == 0)
        bluetooth = 1;
      else if (strcmp (argv[i], "--allow-can") == 0)
        can = 1;
      else
        usage ();
    }

  ctx = seccomp_init (SCMP_ACT_ALLOW);
  if (ctx == NULL)
    fail ("seccomp_init", ENOMEM);

  /* Without the x86 arch token the filter does not apply to 32-bit binaries. */
  if (multiarch)
    {
      r = seccomp_arch_add (ctx, SCMP_ARCH_X86);
      if (r < 0 && r != -EEXIST)
        fail ("seccomp_arch_add", r);
    }

  block (EPERM, SCMP_SYS (syslog));           /* dmesg */
  block (EPERM, SCMP_SYS (uselib));
  block (EPERM, SCMP_SYS (acct));             /* disabling accounting */
  block (EPERM, SCMP_SYS (quotactl));

  /* Kernel keyring, which is not namespaced. */
  block (EPERM, SCMP_SYS (add_key));
  block (EPERM, SCMP_SYS (keyctl));
  block (EPERM, SCMP_SYS (request_key));

  /* VM and NUMA plumbing with a poor bug history. */
  block (EPERM, SCMP_SYS (move_pages));
  block (EPERM, SCMP_SYS (mbind));
  block (EPERM, SCMP_SYS (get_mempolicy));
  block (EPERM, SCMP_SYS (set_mempolicy));
  block (EPERM, SCMP_SYS (migrate_pages));

  /* modify_ldt leaks kernel addresses but 16-bit code and Wine need it. */
  if (!multiarch)
    block (EPERM, SCMP_SYS (modify_ldt));

  /* TIOCSTI/TIOCLINUX fake input into the controlling terminal (CVE-2017-5226,
   * CVE-2023-28100). Blocking them avoids needing --new-session. */
  block_arg (EPERM, SCMP_SYS (ioctl),
             SCMP_A1 (SCMP_CMP_MASKED_EQ, 0xFFFFFFFFu, (int) TIOCSTI));
  block_arg (EPERM, SCMP_SYS (ioctl),
             SCMP_A1 (SCMP_CMP_MASKED_EQ, 0xFFFFFFFFu, (int) TIOCLINUX));

  /* Mount namespace escape route. pressure-vessel and Chromium's zygote need it. */
  if (!nesting)
    {
      block (EPERM, SCMP_SYS (unshare));
      block (EPERM, SCMP_SYS (setns));
      block (EPERM, SCMP_SYS (mount));
      block (EPERM, SCMP_SYS (umount));
      block (EPERM, SCMP_SYS (umount2));
      block (EPERM, SCMP_SYS (pivot_root));
      block (EPERM, SCMP_SYS (chroot));
      block_arg (EPERM, SCMP_SYS (clone),
                 SCMP_A0 (SCMP_CMP_MASKED_EQ, CLONE_NEWUSER, CLONE_NEWUSER));

      /* seccomp cannot inspect clone3()'s struct clone_args. ENOSYS makes
       * glibc fall back to inspectable clone(). */
      block (ENOSYS, SCMP_SYS (clone3));

      /* The new mount API is another mount-table route (CVE-2021-41133). */
      block (ENOSYS, SCMP_SYS (open_tree));
      block (ENOSYS, SCMP_SYS (move_mount));
      block (ENOSYS, SCMP_SYS (fsopen));
      block (ENOSYS, SCMP_SYS (fsconfig));
      block (ENOSYS, SCMP_SYS (fsmount));
      block (ENOSYS, SCMP_SYS (fspick));
      block (ENOSYS, SCMP_SYS (mount_setattr));
    }

  /* Debugging and profiling are expected to come from outside the sandbox. */
  if (!devel)
    {
      block (EPERM, SCMP_SYS (perf_event_open));
      block (EPERM, SCMP_SYS (ptrace));
      block_arg (EPERM, SCMP_SYS (personality),
                 SCMP_A0 (SCMP_CMP_NE, PER_LINUX));
    }

  /* Socket families outside this list are refused. Keep it numerically
   * ordered, the gap walk below depends on it. */
  allowed[n_allowed++] = AF_UNSPEC;
  allowed[n_allowed++] = AF_LOCAL;
  allowed[n_allowed++] = AF_INET;
  allowed[n_allowed++] = AF_INET6;
  allowed[n_allowed++] = AF_NETLINK;
  if (can)
    allowed[n_allowed++] = AF_CAN;
  if (bluetooth)
    allowed[n_allowed++] = AF_BLUETOOTH;

  family = 0;
  for (i = 0; i < n_allowed; i++)
    {
      for (; family < allowed[i]; family++)
        block_family (family);
      family = allowed[i] + 1;
    }
  block_families_from (family);

  r = seccomp_export_bpf (ctx, STDOUT_FILENO);
  if (r < 0)
    fail ("seccomp_export_bpf", r);

  seccomp_release (ctx);
  return 0;
}
