#define _GNU_SOURCE

#include <errno.h>
#include <linux/netlink.h>
#include <netinet/in.h>
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

/* The filter the block helpers add to, switched to the 32-bit one under --multiarch. */
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

/* _exact avoids the i386 socketcall rewrite that fails open (libseccomp issue #8). The filter these go into only ever holds the native arch, so unlike upstream a failure here is a real error. */
static void
block_family (enum scmp_compare op, int family)
{
  int r = seccomp_rule_add_exact (ctx, SCMP_ACT_ERRNO (EAFNOSUPPORT),
                                  SCMP_SYS (socket), 1,
                                  SCMP_A0 (op, family));
  if (r < 0)
    fail ("seccomp_rule_add_exact (socket)", r);
}

/* A user namespace can make a network namespace it administers, and from there reach netfilter, the richest source of
 * kernel privilege escalations, which neither a browser's sandbox nor a nested bubblewrap needs. The kernel reads these
 * arguments as 32-bit and the filter compares 64, so equality is masked, or a stray high bit would slip past. */
static void
block_netfilter (void)
{
  static const int calls[] = { SCMP_SYS (setsockopt), SCMP_SYS (getsockopt) };
  /* ip6tables shares its range with ordinary IPv6 options, so its own numbers are named. */
  static const int ip6_options[] = { 64, 65, 68, 69 };
  unsigned i, j;
  int r;

  r = seccomp_rule_add_exact (ctx, SCMP_ACT_ERRNO (EPERM), SCMP_SYS (socket), 2,
                              SCMP_A0 (SCMP_CMP_MASKED_EQ, 0xFFFFFFFFu, AF_NETLINK),
                              SCMP_A2 (SCMP_CMP_MASKED_EQ, 0xFFFFFFFFu, NETLINK_NETFILTER));
  if (r < 0)
    fail ("seccomp_rule_add_exact (socket)", r);

  for (i = 0; i < sizeof calls / sizeof *calls; i++)
    {
      /* Every IPv4 socket option from 64 up belongs to iptables, arptables, ebtables, conntrack or IPVS. */
      r = seccomp_rule_add_exact (ctx, SCMP_ACT_ERRNO (EPERM), calls[i], 2,
                                  SCMP_A1 (SCMP_CMP_MASKED_EQ, 0xFFFFFFFFu, IPPROTO_IP),
                                  SCMP_A2 (SCMP_CMP_GE, 64));
      if (r < 0)
        fail ("seccomp_rule_add_exact (sockopt)", r);

      for (j = 0; j < sizeof ip6_options / sizeof *ip6_options; j++)
        {
          r = seccomp_rule_add_exact (ctx, SCMP_ACT_ERRNO (EPERM), calls[i], 2,
                                      SCMP_A1 (SCMP_CMP_MASKED_EQ, 0xFFFFFFFFu, IPPROTO_IPV6),
                                      SCMP_A2 (SCMP_CMP_MASKED_EQ, 0xFFFFFFFFu, ip6_options[j]));
          if (r < 0)
            fail ("seccomp_rule_add_exact (sockopt)", r);
        }
    }
}

static void
add_rules (int nesting, int userns, int devel, int multiarch, int io_uring)
{
  block (EPERM, SCMP_SYS (syslog));
  block (EPERM, SCMP_SYS (uselib));
  block (EPERM, SCMP_SYS (acct));
  block (EPERM, SCMP_SYS (quotactl));

  /* The kernel keyring is not namespaced. */
  block (EPERM, SCMP_SYS (add_key));
  block (EPERM, SCMP_SYS (keyctl));
  block (EPERM, SCMP_SYS (request_key));

  /* VM and NUMA plumbing has a poor bug history. */
  block (EPERM, SCMP_SYS (move_pages));
  block (EPERM, SCMP_SYS (mbind));
  block (EPERM, SCMP_SYS (get_mempolicy));
  block (EPERM, SCMP_SYS (set_mempolicy));
  block (EPERM, SCMP_SYS (migrate_pages));

  /* modify_ldt leaks kernel addresses but 16-bit code and Wine need it. */
  if (!multiarch)
    block (EPERM, SCMP_SYS (modify_ldt));

  /* TIOCSTI/TIOCLINUX fake input into the controlling terminal (CVE-2017-5226, CVE-2023-28100), and blocking them avoids needing --new-session. */
  block_arg (EPERM, SCMP_SYS (ioctl),
             SCMP_A1 (SCMP_CMP_MASKED_EQ, 0xFFFFFFFFu, (int) TIOCSTI));
  block_arg (EPERM, SCMP_SYS (ioctl),
             SCMP_A1 (SCMP_CMP_MASKED_EQ, 0xFFFFFFFFu, (int) TIOCLINUX));

  /* A mount table of its own is a sandbox's way out, and only a nested bubblewrap such as pressure-vessel builds one. */
  if (!nesting)
    {
      block (EPERM, SCMP_SYS (setns));
      block (EPERM, SCMP_SYS (mount));
      block (EPERM, SCMP_SYS (umount));
      block (EPERM, SCMP_SYS (umount2));
      block (EPERM, SCMP_SYS (pivot_root));

      /* A browser's own sandbox makes user namespaces and chroots into an empty folder, and calls none of the above. */
      if (!userns)
        {
          block (EPERM, SCMP_SYS (unshare));
          block (EPERM, SCMP_SYS (chroot));
          block_arg (EPERM, SCMP_SYS (clone),
                     SCMP_A0 (SCMP_CMP_MASKED_EQ, CLONE_NEWUSER, CLONE_NEWUSER));

          /* seccomp cannot inspect clone3()'s struct clone_args, and ENOSYS makes glibc fall back to the inspectable clone(). */
          block (ENOSYS, SCMP_SYS (clone3));
        }

      /* The new mount API is another mount-table route (CVE-2021-41133). */
      block (ENOSYS, SCMP_SYS (open_tree));
      block (ENOSYS, SCMP_SYS (move_mount));
      block (ENOSYS, SCMP_SYS (fsopen));
      block (ENOSYS, SCMP_SYS (fsconfig));
      block (ENOSYS, SCMP_SYS (fsmount));
      block (ENOSYS, SCMP_SYS (fspick));
      block (ENOSYS, SCMP_SYS (mount_setattr));
    }

  /* io_uring reaches large parts of the kernel that seccomp cannot inspect and carried most kernel exploits in Google's kCTF, and ENOSYS makes libuv and liburing fall back to threads. */
  if (!io_uring)
    {
      block (ENOSYS, SCMP_SYS (io_uring_setup));
      block (ENOSYS, SCMP_SYS (io_uring_enter));
      block (ENOSYS, SCMP_SYS (io_uring_register));
    }

  /* Debugging and profiling are expected to come from outside the sandbox. */
  if (!devel)
    {
      block (EPERM, SCMP_SYS (perf_event_open));
      block (EPERM, SCMP_SYS (ptrace));
      block_arg (EPERM, SCMP_SYS (personality),
                 SCMP_A0 (SCMP_CMP_NE, PER_LINUX));
    }
}

static void
usage (void)
{
  fprintf (stderr,
           "usage: confine-seccomp [--allow-nesting] [--allow-userns] [--devel] [--multiarch]\n"
           "                       [--allow-bluetooth] [--allow-can] [--allow-io-uring]\n");
  exit (1);
}

int
main (int argc, char **argv)
{
  int nesting = 0, userns = 0, devel = 0, multiarch = 0, bluetooth = 0, can = 0, io_uring = 0;
  int allowed[8], n_allowed = 0;
  int i, family, r;
  scmp_filter_ctx native;

  for (i = 1; i < argc; i++)
    {
      if (strcmp (argv[i], "--allow-nesting") == 0)
        nesting = 1;
      else if (strcmp (argv[i], "--allow-userns") == 0)
        userns = 1;
      else if (strcmp (argv[i], "--devel") == 0)
        devel = 1;
      else if (strcmp (argv[i], "--multiarch") == 0)
        multiarch = 1;
      else if (strcmp (argv[i], "--allow-bluetooth") == 0)
        bluetooth = 1;
      else if (strcmp (argv[i], "--allow-can") == 0)
        can = 1;
      else if (strcmp (argv[i], "--allow-io-uring") == 0)
        io_uring = 1;
      else
        usage ();
    }

  native = ctx = seccomp_init (SCMP_ACT_ALLOW);
  if (ctx == NULL)
    fail ("seccomp_init", ENOMEM);

  add_rules (nesting, userns, devel, multiarch, io_uring);

  /* Native ABI only, like the family rules below and for their reason. */
  if (userns || nesting)
    block_netfilter ();

  /* Keep this list numerically ordered, the gap walk below depends on it. */
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
        block_family (SCMP_CMP_EQ, family);
      family = allowed[i] + 1;
    }
  block_family (SCMP_CMP_GE, family);

  /* i386 code creates sockets through socketcall, which keeps the family in memory where seccomp cannot read it, and any
   * exact socket rule then fails on both arches. Blocking socketcall outright breaks the 32-bit Steam client (flatpak
   * reverted exactly that in 1a6ec6a1), so the 32-bit ABI gets its own filter without the family rules, merged in so
   * the native ABI keeps them. A 64-bit process can still reach the unfiltered families through int 0x80 on purpose. */
  if (multiarch)
    {
      ctx = seccomp_init (SCMP_ACT_ALLOW);
      if (ctx == NULL)
        fail ("seccomp_init", ENOMEM);
      r = seccomp_arch_add (ctx, SCMP_ARCH_X86);
      if (r < 0)
        fail ("seccomp_arch_add", r);
      r = seccomp_arch_remove (ctx, SCMP_ARCH_NATIVE);
      if (r < 0)
        fail ("seccomp_arch_remove", r);

      add_rules (nesting, userns, devel, multiarch, io_uring);

      /* On success the merge frees the 32-bit filter. */
      r = seccomp_merge (native, ctx);
      if (r < 0)
        fail ("seccomp_merge", r);
    }

  r = seccomp_export_bpf (native, STDOUT_FILENO);
  if (r < 0)
    fail ("seccomp_export_bpf", r);

  seccomp_release (native);
  return 0;
}
