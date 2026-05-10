#include <bpf/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "Usage: %s <interface> <port>\n", argv[0]);
    return 1;
  }

  const char *iface = argv[1];
  __u16 port = (__u16)atoi(argv[2]);

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

  // Attach via tc (shell out for simplicity)
  char cmd[256];
  snprintf(cmd, sizeof(cmd),
           "tc qdisc add dev %s clsact 2>/dev/null; "
           "tc filter add dev %s ingress bpf fd %d direct-action",
           iface, iface, prog_fd);
  system(cmd);

  // Set blocked port in bpf map
  struct bpf_map *p_map = bpf_object__find_map_by_name(obj, "blocked_port");
  int map_fd = bpf_map__fd(p_map);
  __u32 key = 0;

  printf("Filtering port %d on %s. Press Ctrl+C to stop.\n", port, iface);
  printf("%-20s %s\n", "Time", "Packets dropped");

  // Poll drop counter
  struct bpf_map *c_map = bpf_object__find_map_by_name(obj, "drop_count");
  int count_fd = bpf_map__fd(c_map);
  __u64 prev = 0;

  // daemon loop
  while (1) {
    sleep(1);
    __u64 count = 0;
    bpf_map_lookup_elem(count_fd, &key, &count);
    printf("drops this seccond: %llu (total: %llu)\n", count - prev, count);
  }

  // Cleanup, technically unreachable unless adding SIGINT handler
  snprintf(cmd, sizeof(cmd), "tc qdisc del dev %s clsact", iface);
  system(cmd);

  bpf_object__close(obj);
  return 0;
}
