#include <arpa/inet.h>
#include <fcntl.h>
#include <linux/if_tun.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/ip_icmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

static volatile int running = 1;
void handle_sig(int sig) { running = 0; }

// Open and configure TUN device
int tun_open(char *devname) {
  struct ifreq ifr = {0};
  int fd = open("/dev/net/tun", O_RDWR);
  if (fd < 0) {
    perror("open /dev/net/tun failed");
    return -1;
  }

  ifr.ifr_ifru.ifru_flags = IFF_TUN | IFF_NO_PI; // TUN mode, no packet info hdr
  strncpy(ifr.ifr_ifrn.ifrn_name, devname, IFNAMSIZ); // set name

  if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
    perror("TUNSETIFF failed");
    close(fd);
    return -1;
  }

  strncpy(devname, ifr.ifr_ifrn.ifrn_name, IFNAMSIZ); // copy back
  return fd;
}

// Internet checksum (used by IP and ICMP protocols)
uint16_t checksum(void *data, int len) {
  uint16_t *ptr = data;
  uint32_t sum = 0;

  while (len > 1) {
    sum += *ptr++;
    len -= 2;
  }
  if (len)
    sum += *(uint8_t *)ptr;

  while (sum >> 16)
    sum = (sum & 0xffff) + (sum >> 16);
  return -sum;
}

// Respond to ping requests with appropriate return
// simulating device at end of interface
void pong(int fd, uint8_t *buf, int len) {
  struct iphdr *iph = (struct iphdr *)buf;

  // Only handle ICMP in minimal example
  if (iph->protocol != IPPROTO_ICMP)
    return;

  struct icmphdr *icmp = (struct icmphdr *)(buf + iph->ihl * 4);

  // Only handle echo requests PING
  if (icmp->type != ICMP_ECHO)
    return;

  printf("Got ping from %s, seq=%d\n",
         inet_ntoa(*(struct in_addr *)&iph->saddr),
         ntohs(icmp->un.echo.sequence));

  // Build reply, reuse packet in place but swap src/dst
  uint32_t tmp = iph->saddr;
  iph->saddr = iph->daddr;
  iph->daddr = tmp;
  iph->ttl = 32;

  // Compute checksum
  iph->check = 0;
  iph->check = checksum(iph, iph->ihl * 4);

  // Change to echo reply
  icmp->type = ICMP_ECHOREPLY;

  // Checksum
  icmp->checksum = 0;
  icmp->checksum = checksum(icmp, len - iph->ihl * 4);

  // Write reply back to tun device
  if (write(fd, buf, len) < 0) {
    perror("write tun failed");
  }
}

int main(void) {
  char devname[IFNAMSIZ] = "tun0"; // iface name
  int fd = tun_open(devname);
  if (fd < 0) {
    perror("open tun failed");
    return 1;
  }

  signal(SIGINT, handle_sig);
  signal(SIGTERM, handle_sig);

  printf("TUN device: %s\n", devname);
  printf("Configure with:\n");
  printf("  sudo ip addr add 10.0.0.1/24 dev %s\n", devname);
  printf("  sudo ip link set %s up\n", devname);
  printf("Then ping addr: ping 10.0.0.2\n\n");

  uint8_t buf[2048];
  while (running) {
    int len = read(fd, buf, sizeof(buf));
    if (len < 0) {
      perror("read failed");
      break;
    }
    pong(fd, buf, len);
  }

  close(fd);
  return 0;
}
