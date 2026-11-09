/* Usage: confine-document-add APP_ID PATH
 *
 * Exports PATH through the document portal with read and write access for APP_ID and prints the document id, the way
 * flatpak run --file-forwarding hands over files the app cannot otherwise see. */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <systemd/sd-bus.h>

#define DOCUMENTS_NAME "org.freedesktop.portal.Documents"
#define DOCUMENTS_PATH "/org/freedesktop/portal/documents"

enum
{
  ADD_REUSE_EXISTING = 1 << 0,
  ADD_DIRECTORY = 1 << 3,
};

static void
fail (const char *what, int err)
{
  fprintf (stderr, "confine-document-add: %s: %s\n", what, strerror (err < 0 ? -err : err));
  exit (1);
}

int
main (int argc, char **argv)
{
  sd_bus *bus = NULL;
  sd_bus_message *call = NULL, *reply = NULL;
  sd_bus_error error = SD_BUS_ERROR_NULL;
  struct stat st;
  uint32_t version = 0, flags = ADD_REUSE_EXISTING;
  const char *doc_id;
  int fd, r;

  if (argc != 3)
    {
      fprintf (stderr, "usage: confine-document-add APP_ID PATH\n");
      return 2;
    }

  fd = open (argv[2], O_PATH | O_CLOEXEC);
  if (fd < 0)
    fail (argv[2], errno);
  if (fstat (fd, &st) < 0)
    fail (argv[2], errno);
  if (S_ISDIR (st.st_mode))
    flags |= ADD_DIRECTORY;

  r = sd_bus_open_user (&bus);
  if (r < 0)
    fail ("session bus", r);

  r = sd_bus_get_property_trivial (bus, DOCUMENTS_NAME, DOCUMENTS_PATH, DOCUMENTS_NAME, "version", &error, 'u', &version);
  if (r < 0)
    {
      fprintf (stderr, "confine-document-add: no document portal: %s\n", error.message ? error.message : strerror (-r));
      return 1;
    }
  /* AddFull arrived in version 2 and directories in version 4, Flatpak draws the same lines. */
  if (version < 2 || ((flags & ADD_DIRECTORY) && version < 4))
    {
      fprintf (stderr, "confine-document-add: document portal version %u is too old\n", version);
      return 1;
    }

  r = sd_bus_message_new_method_call (bus, &call, DOCUMENTS_NAME, DOCUMENTS_PATH, DOCUMENTS_NAME, "AddFull");
  if (r < 0)
    fail ("new call", r);
  r = sd_bus_message_append (call, "ahus", 1, fd, flags, argv[1]);
  if (r < 0)
    fail ("append", r);
  r = sd_bus_message_append (call, "as", 2, "read", "write");
  if (r < 0)
    fail ("append", r);

  r = sd_bus_call (bus, call, 0, &error, &reply);
  if (r < 0)
    {
      fprintf (stderr, "confine-document-add: %s\n", error.message ? error.message : strerror (-r));
      return 1;
    }

  r = sd_bus_message_enter_container (reply, 'a', "s");
  if (r < 0)
    fail ("reply", r);
  r = sd_bus_message_read (reply, "s", &doc_id);
  if (r <= 0)
    fail ("reply", r < 0 ? r : EBADMSG);

  printf ("%s\n", doc_id);

  sd_bus_message_unref (reply);
  sd_bus_message_unref (call);
  sd_bus_unref (bus);
  close (fd);
  return 0;
}
