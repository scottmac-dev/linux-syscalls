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

// XOR packet payload bytes with key, 4 bytes at a time, remainder byte by byte
void xor_payload(uint8_t *buf, int len, uint32_t key) {
  struct iphdr *iph = (struct iphdr *)buf;

  // Skip the IP header, only XOR the payload
  int header_len = iph->ihl * 4;
  if (header_len >= len)
    return; // no payload

  uint8_t *payload = buf + header_len;
  int payload_len = len - header_len;

  int i = 0;
  // 4 bytes at a time
  for (; i <= payload_len - 4; i += 4) {
    uint32_t chunk;
    memcpy(&chunk, payload + i, 4);
    chunk ^= key;
    memcpy(payload + i, &chunk, 4);
  }

  // Remaining bytes
  uint8_t *keybytes = (uint8_t *)&key;
  for (int j = 0; i < payload_len; i++, j++) {
    payload[i] ^= keybytes[j];
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
        perror("read tun0 failed");
        break;
      }
      printf("tun0 -> tun1: %d bytes (key=0x%8X)\n", len, xor_key);
      xor_payload(buf, len, xor_key);

      if (write(tun1_fd, buf, len) < 0) {
        perror("write tun1 failed");
        continue;
      }
    }

    // Packet inbound tun1 = scrambled, unscramble and send to tun0
    if (FD_ISSET(tun1_fd, &fds)) {
      int len = read(tun1_fd, buf, sizeof(buf));
      if (len < 0) {
        perror("read tun1 failed");
        break;
      }
      printf("tun1 -> tun0: %d bytes (key=0x%8X)\n", len, xor_key);
      xor_payload(buf, len, xor_key);
      if (write(tun0_fd, buf, len) < 0) {
        perror("write tun0 failed");
        continue;
      }
    }
  }

  printf("\nShutting down\n");
  close(tun0_fd);
  close(tun1_fd);
  return 0;
}
