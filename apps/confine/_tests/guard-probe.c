/* Tries what the admin of a network namespace can do, first in the namespace it starts in and then in one of its own,
   and prints one result a line. */
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/sockios.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef IP_XFRM_POLICY
# define IP_XFRM_POLICY 17
#endif

static void
report (const char *name, int rc)
{
  const char *result = "ok";
  static char other[32];

  if (rc < 0)
    switch (errno)
      {
      case EPERM: result = "EPERM"; break;
      case EROFS: result = "EROFS"; break;
      case EACCES: result = "EACCES"; break;
      default: snprintf (other, sizeof other, "errno-%d", errno); result = other;
      }
  printf ("%s=%s\n", name, result);
}

/* A request to add a queueing discipline, which the kernel answers by its permission check before it reads further. */
static int
traffic_control (int netlink)
{
  struct { struct nlmsghdr header; struct tcmsg tc; } request = { 0 };
  struct sockaddr_nl kernel = { .nl_family = AF_NETLINK };
  struct { struct nlmsghdr header; struct nlmsgerr error; char rest[128]; } answer = { 0 };

  request.header.nlmsg_len = sizeof request;
  request.header.nlmsg_type = RTM_NEWQDISC;
  request.header.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
  if (sendto (netlink, &request, sizeof request, 0, (struct sockaddr *) &kernel, sizeof kernel) < 0
      || recv (netlink, &answer, sizeof answer, 0) < 0)
    return -1;
  if (answer.error.error == 0)
    return 0;
  errno = -answer.error.error;
  return -1;
}

int
main (void)
{
  struct ifreq lo = { 0 };
  char policy[8] = { 0 };
  int early, local, tcp, on = 1, fd;

  early = socket (AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
  report ("home-netlink", early);

  if (unshare (CLONE_NEWUSER | CLONE_NEWNET) != 0)
    {
      report ("unshare", -1);
      return 2;
    }

  report ("own-netlink", socket (AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE));
  report ("own-netlink-generic", socket (AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_GENERIC));
  report ("early-netlink-tc", early < 0 ? -1 : traffic_control (early));

  local = socket (AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  strcpy (lo.ifr_name, "lo");
  report ("ioctl-read", ioctl (local, SIOCGIFFLAGS, &lo));
  lo.ifr_flags |= IFF_UP;
  report ("ioctl-interface", ioctl (local, SIOCSIFFLAGS, &lo));
  report ("ioctl-bridge", ioctl (local, SIOCBRADDBR, "probe0"));

  report ("raw-socket", socket (AF_INET, SOCK_RAW | SOCK_CLOEXEC, IPPROTO_UDP));
  tcp = socket (AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  report ("tcp-socket", tcp);
  report ("option-ipsec", setsockopt (tcp, IPPROTO_IP, IP_XFRM_POLICY, policy, sizeof policy));
  report ("option-repair", setsockopt (tcp, IPPROTO_TCP, TCP_REPAIR, &on, sizeof on));
  report ("option-plain", setsockopt (tcp, IPPROTO_TCP, TCP_NODELAY, &on, sizeof on));

  fd = open ("/proc/sys/net/ipv4/ip_forward", O_WRONLY | O_CLOEXEC);
  report ("sysctl", fd);
  return 0;
}
