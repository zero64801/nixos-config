/* Usage: confine-seccomp-exec FILTER COMMAND [ARGS...]
 *
 * Loads a BPF program exported by confine-seccomp and runs COMMAND under it, so a process that joins a running sandbox
 * from outside, as confine enter does, is held to the same filter as the app. */

#define _GNU_SOURCE
#include <errno.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <unistd.h>

static void
fail (const char *what, int err)
{
  fprintf (stderr, "confine-seccomp-exec: %s: %s\n", what, strerror (err));
  exit (1);
}

int
main (int argc, char **argv)
{
  struct sock_fprog prog;
  struct stat st;
  FILE *f;
  size_t n;

  if (argc < 3)
    {
      fprintf (stderr, "usage: confine-seccomp-exec FILTER COMMAND [ARGS...]\n");
      return 2;
    }

  f = fopen (argv[1], "rb");
  if (f == NULL)
    fail (argv[1], errno);
  if (fstat (fileno (f), &st) < 0)
    fail (argv[1], errno);
  if (st.st_size <= 0 || st.st_size % sizeof (struct sock_filter) != 0
      || st.st_size / sizeof (struct sock_filter) > BPF_MAXINSNS)
    {
      fprintf (stderr, "confine-seccomp-exec: %s is not a BPF program\n", argv[1]);
      return 1;
    }

  n = st.st_size / sizeof (struct sock_filter);
  prog.len = n;
  prog.filter = calloc (n, sizeof (struct sock_filter));
  if (prog.filter == NULL)
    fail ("calloc", ENOMEM);
  if (fread (prog.filter, sizeof (struct sock_filter), n, f) != n)
    fail (argv[1], EIO);
  fclose (f);

  if (prctl (PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0)
    fail ("no_new_privs", errno);
  if (prctl (PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog) < 0)
    fail ("seccomp", errno);

  execvp (argv[2], argv + 2);
  fail (argv[2], errno);
}
