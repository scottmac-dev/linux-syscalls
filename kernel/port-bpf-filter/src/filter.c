#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <bpf/libbpf_legacy.h>
#include <errno.h>
#include <linux/if_link.h>
#include <linux/pkt_sched.h>
#include <net/if.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile int running = 1;
static char iface_name[64];

void handle_sig(int sig) { running = 0; }

void cleanup(void) {
  char cmd[128];
  snprintf(cmd, sizeof(cmd), "tc qdisc del dev %s clsact", iface_name);
  system(cmd);
  printf("\nCleaned up tc qdisc on %s\n", iface_name);
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "Usage: %s <interface> <port>\n", argv[0]);
    return 1;
  }

  strncpy(iface_name, argv[1], sizeof(iface_name) - 1);
  __u16 port = (__u16)atoi(argv[2]);

  signal(SIGINT, handle_sig);
  signal(SIGTERM, handle_sig);

  // Load BPF object file
  struct bpf_object *obj = bpf_object__open("filter.bpf.o");
  if (!obj) {
    fprintf(stderr, "Failed to load BPF object\n");
    return 1;
  }

  // Get program fd
  struct bpf_program *prog =
      bpf_object__find_program_by_name(obj, "port_filter");
  int prog_fd = bpf_program__fd(prog);

  // Get interface index
  unsigned int ifindex = if_nametoindex(iface_name);
  if (!ifindex) {
    fprintf(stderr, "Failed to get interface %s\n", iface_name);
    bpf_object__close(obj);
    return 1;
  }

  // Create clsact qdisc
  char cmd[256];
  snprintf(cmd, sizeof(cmd), "tc qdisc add dev %s clsact", iface_name);
  int rc = system(cmd);
  if (rc != 0) {
    fprintf(stderr, "Failed to create clsact: %s\n", strerror(rc));
    cleanup();
    bpf_object__close(obj);
    return 1;
  }

  // Attach using libbpf tc API
  DECLARE_LIBBPF_OPTS(bpf_tc_hook, hook, .ifindex = ifindex,
                      .attach_point = BPF_TC_INGRESS);

  DECLARE_LIBBPF_OPTS(bpf_tc_opts, opts, .handle = 0, .priority = 1,
                      .prog_fd = prog_fd);

  int err = bpf_tc_attach(&hook, &opts);
  if (err) {
    fprintf(stderr, "Failed to attach TC filter: %s\n", strerror(-err));
    cleanup();
    bpf_object__close(obj);
    return 1;
  }

  printf("TC filter attaches on %s ingress\n", iface_name);

  // Get map fds
  struct bpf_map *p_map = bpf_object__find_map_by_name(obj, "blocked_port");
  if (!p_map) {
    fprintf(stderr, "Failed to find blocked_port map\n");
    cleanup();
    bpf_object__close(obj);
    return 1;
  }
  int port_fd = bpf_map__fd(p_map);

  // Poll drop counter
  struct bpf_map *c_map = bpf_object__find_map_by_name(obj, "drop_count");
  if (!c_map) {
    fprintf(stderr, "Failed to find drop_count map\n");
    cleanup();
    bpf_object__close(obj);
    return 1;
  }
  int count_fd = bpf_map__fd(c_map);

  // Set blocked port
  __u32 key = 0;
  if (bpf_map_update_elem(port_fd, &key, &port, BPF_ANY) < 0) {
    fprintf(stderr, "Failed to set blocked port: %s\n", strerror(errno));
    cleanup();
    bpf_object__close(obj);
    return 1;
  }

  printf("Filtering port %d on %s.\n", port, iface_name);
  printf("Press Ctrl+C to stop.\n\n");
  printf("%-10s %s\n", "this sec", "total");

  __u64 prev = 0;
  // daemon loop
  while (running) {
    sleep(1);
    __u64 count = 0;
    bpf_map_lookup_elem(count_fd, &key, &count);
    printf("%-10llu %llu\n", count - prev, count);
    prev = count;
  }

  cleanup();
  bpf_object__close(obj);
  return 0;
}
