// XOR is its own inverse, applying the same XOR key twice restores the
// original bytes. In this example this mocks encryption, we know the XOR key
// the kernal XORs the bytes via the BPF program when sending ping from tun0.
// tun1 then XORs again with same key, unscrambling and printing the message
// You should be aple to update the key live using
// `sudo bpftool map update name xor_key key 0 0 0 0 value 0xDE 0xAD 0xFF 0xFF`
#include "../include/types.h"
#include <arpa/inet.h>
#include <asm-generic/errno-base.h>
#include <bits/types/struct_timeval.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <bpf/libbpf_legacy.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/bpf.h>
#include <linux/if_link.h>
#include <linux/if_tun.h>
#include <linux/pkt_sched.h>
#include <net/if.h>
#include <netinet/ip.h>
#include <netinet/ip_icmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#define MTU 2048
#define DEF_KEY 0xDEADBEEF

static volatile int running = 1;
void handle_sig(int sig) { running = 0; }

// ICMP chucksum
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
  return ~sum;
}

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

// Bring tun interface up to prevent race condition of doing manually
// eg. sudo ip addr add 10.0.0.1 peer 10.0.0.2 dev %s;
// sudo ip link set %s up
int tun_up(const char *iface_name, const char *addr, const char *peer) {
  int sockfd = socket(AF_INET, SOCK_DGRAM, 0);
  if (sockfd < 0) {
    perror("create tun socket failed");
    return -1;
  }
  struct ifreq ifr = {0};
  strncpy(ifr.ifr_name, iface_name, IFNAMSIZ);

  // Set address
  struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
  sin->sin_family = AF_INET;
  inet_pton(AF_INET, addr, &sin->sin_addr);
  if (ioctl(sockfd, SIOCSIFADDR, &ifr) < 0) {
    perror("SIOCSIFADDR");
    close(sockfd);
    return -1;
  }

  // Set peer address
  inet_pton(AF_INET, peer, &sin->sin_addr);
  if (ioctl(sockfd, SIOCSIFDSTADDR, &ifr) < 0) {
    perror("SIOCSIFDSTADDR");
    close(sockfd);
    return -1;
  }

  // Bring interface up
  if (ioctl(sockfd, SIOCGIFFLAGS, &ifr) < 0) {
    perror("SIOCGIFFLAGS");
    close(sockfd);
    return -1;
  }
  ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
  if (ioctl(sockfd, SIOCSIFFLAGS, &ifr) < 0) {
    perror("SIOCSIFFLAGS");
    close(sockfd);
    return -1;
  }

  close(sockfd);
  return 0;
}

// Manually handle the tun1 response to avoid infinite routing loop where tun0
// -> sends to tun1 but never gets response
void handle_tun0(int tun0_fd, int tun1_fd, uint8_t *buf, int len,
                 uint32_t key) {
  struct iphdr *iph = (struct iphdr *)buf;
  if (iph->version != 4)
    return;
  if (iph->protocol != IPPROTO_ICMP)
    return;

  struct icmphdr *icmp = (struct icmphdr *)(buf + iph->ihl * 4);
  if (icmp->type != ICMP_ECHO)
    return;

  printf("tun0 -> tun1: %d bytes (key=0x%08X) [ICMP echo request]\n", len, key);

  // XOR the ICMP payload (after ICMP header) to simulate encrypted transit
  int ip_hdr_len = iph->ihl * 4;
  int icmp_hdr_len = sizeof(struct icmphdr);
  int data_offset = ip_hdr_len + icmp_hdr_len;
  int data_len = len - data_offset;

  if (data_len > 0) {
    uint8_t *data = buf + data_offset;
    uint8_t *keybytes = (uint8_t *)&key;
    for (int i = 0; i < data_len; i++) {
      data[i] ^= keybytes[i % 4];
    }
  }

  printf("tun1 -> tun0: %d bytes (key=0x%08X) [crafting ICMP echo reply]\n",
         len, key);

  // XOR back (simulate decryption on tun1 side)
  if (data_len > 0) {
    uint8_t *data = buf + data_offset;
    uint8_t *keybytes = (uint8_t *)&key;
    for (int i = 0; i < data_len; i++) {
      data[i] ^= keybytes[i % 4];
    }
  }

  // Craft ICMP echo reply
  // Swap src/dst IP
  uint32_t tmp = iph->saddr;
  iph->saddr = iph->daddr;
  iph->daddr = tmp;
  iph->ttl = 64;
  iph->check = 0;
  iph->check = checksum(iph, ip_hdr_len);

  // Set ICMP type to reply
  icmp->type = ICMP_ECHOREPLY;
  icmp->checksum = 0;
  icmp->checksum = checksum(icmp, len - ip_hdr_len);

  // Write reply back to tun0
  if (write(tun0_fd, buf, len) < 0) {
    perror("write tun0 reply");
  }
}

int main(void) {
  signal(SIGINT, handle_sig);
  signal(SIGTERM, handle_sig);

  // Load BPF object file
  struct bpf_object *obj = bpf_object__open("xortun.bpf.o");
  if (!obj) {
    fprintf(stderr, "Failed to open BPF object\n");
    return 1;
  }

  // Load
  if (bpf_object__load(obj)) {
    fprintf(stderr, "Failed to load BPF object: %s\n", strerror(errno));
    bpf_object__close(obj);
    return 1;
  }

  // Get keymap from eBPF
  struct bpf_map *key_map = bpf_object__find_map_by_name(obj, "xor_key");
  if (!key_map) {
    fprintf(stderr, "Failed to find xor_keymap\n");
    bpf_object__close(obj);
    return 1;
  }
  int map_fd = bpf_map__fd(key_map);

  // Set default key
  __u32 map_key = 0;
  __u32 xor_key = DEF_KEY;
  if (bpf_map_update_elem(map_fd, &map_key, &xor_key, BPF_ANY) < 0) {
    fprintf(stderr, "Failed to set XOR key: %s\n", strerror(errno));
    bpf_object__close(obj);
    return 1;
  }

  printf("XOR key set to 0x%08X\n", xor_key);

  // Open tun devices
  char tun0_name[IFNAMSIZ] = "tun0";
  char tun1_name[IFNAMSIZ] = "tun1";

  int tun0_fd = tun_open(tun0_name);
  if (tun0_fd < 0) {
    perror("open tun0 failed");
    return 1;
  }

  int tun1_fd = tun_open(tun1_name);
  if (tun1_fd < 0) {
    perror("open tun1 failed");
    close(tun0_fd);
    return 1;
  }

  printf("Opened %s and %s\n", tun0_name, tun1_name);
  printf("Configuring interfaces...\n");

  if (tun_up(tun0_name, "10.0.0.1", "10.0.0.2") < 0) {
    fprintf(stderr, "Failed to bring up %s\n", tun0_name);
    close(tun0_fd);
    close(tun1_fd);
    bpf_object__close(obj);
    return 1;
  }
  printf("%s up: 10.0.0.1 peer 10.0.0.2\n", tun0_name);

  if (tun_up(tun1_name, "10.1.0.1", "10.1.0.2") < 0) {
    fprintf(stderr, "Failed to bring up %s\n", tun1_name);
    close(tun0_fd);
    close(tun1_fd);
    bpf_object__close(obj);
    return 1;
  }
  printf("%s up: 10.1.0.1 peer 10.1.0.2\n", tun1_name);

  printf("\nBoth interfaces up, starting loop\n");
  printf("ping 10.0.0.2 to test\n");
  printf("Press Ctrl+C to stop\n\n");
  uint8_t buf[MTU];
  int maxfd = (tun0_fd > tun1_fd ? tun0_fd : tun1_fd) + 1;

  while (running) {
    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(tun0_fd, &fds);
    FD_SET(tun1_fd, &fds);

    // waits for either fd to be readable with 1s timeout for singnal handling
    struct timeval tv = {.tv_sec = 1, .tv_usec = 0};
    int rt = select(maxfd, &fds, NULL, NULL, &tv);
    if (rt < 0) {
      if (errno == EINTR)
        continue;
      perror("select failed");
      break;
    }
    if (rt == 0)
      continue; // timeout

    // Read key from BPF map, can be changed live
    bpf_map_lookup_elem(map_fd, &map_key, &xor_key);

    // Packet inbound tun0 = plaintext, scramble and send to tun1
    if (FD_ISSET(tun0_fd, &fds)) {
      int len = read(tun0_fd, buf, sizeof(buf));
      if (len < 0) {
        perror("read tun0");
        continue;
      }
      handle_tun0(tun0_fd, tun1_fd, buf, len, xor_key);
    }

    if (FD_ISSET(tun1_fd, &fds)) {
      // Drain tun1 to keep it clean but we handle replies manually in handle
      // tun0
      read(tun1_fd, buf, sizeof(buf));
    }
  }

  printf("\nShutting down\n");
  close(tun0_fd);
  close(tun1_fd);
  return 0;
}
