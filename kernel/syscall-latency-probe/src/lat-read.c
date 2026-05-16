#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define NUM_BUCKETS 5

static volatile int running = 1;

void handle_sig(int sig) { running = 0; }

static const char *bucket_labels[NUM_BUCKETS] = {
    "0-1us    ", "1-10us   ", "10-100us ", "100-1ms  ", "1ms+     ",
};

void print_histogram(int map_fd) {
  __u64 counts[NUM_BUCKETS] = {0};
  __u64 max = 0;

  // Read all buckets
  for (__u32 i = 0; i < NUM_BUCKETS; i++) {
    bpf_map_lookup_elem(map_fd, &i, &counts[i]);
    if (counts[i] > max)
      max = counts[i];
  }

  printf("\nsys_read latency histogram\n");
  printf("──────────────────────────────────────────\n");

  for (int i = 0; i < NUM_BUCKETS; i++) {
    // Scale bar to 40 chars max
    int bar_len = max > 0 ? (int)(counts[i] * 40 / max) : 0;

    printf("  %s │", bucket_labels[i]);
    for (int j = 0; j < bar_len; j++)
      printf("█");
    printf(" %llu\n", counts[i]);
  }
  printf("──────────────────────────────────────────\n");
}

void clear_histogram(int map_fd) {
  __u64 zero = 0;
  for (__u32 i = 0; i < NUM_BUCKETS; i++) {
    bpf_map_update_elem(map_fd, &i, &zero, BPF_ANY);
  }
}

int main(void) {
  signal(SIGINT, handle_sig);
  signal(SIGTERM, handle_sig);

  // Open and load BPF object
  struct bpf_object *obj = bpf_object__open("lat-read.bpf.o");
  if (!obj) {
    fprintf(stderr, "Failed to open BPF object\n");
    return 1;
  }

  if (bpf_object__load(obj)) {
    fprintf(stderr, "Failed to load BPF object: %s\n", strerror(errno));
    bpf_object__close(obj);
    return 1;
  }

  // Attach kprobe
  struct bpf_program *kprobe_prog =
      bpf_object__find_program_by_name(obj, "kprobe_sys_read");
  if (!kprobe_prog) {
    fprintf(stderr, "Failed to find kprobe program\n");
    bpf_object__close(obj);
    return 1;
  }

  struct bpf_link *kprobe_link = bpf_program__attach(kprobe_prog);
  if (!kprobe_link) {
    fprintf(stderr, "Failed to attach kprobe: %s\n", strerror(errno));
    bpf_object__close(obj);
    return 1;
  }

  // Attach kretprobe
  struct bpf_program *kretprobe_prog =
      bpf_object__find_program_by_name(obj, "kretprobe_sys_read");
  if (!kretprobe_prog) {
    fprintf(stderr, "Failed to find kretprobe program\n");
    bpf_link__destroy(kprobe_link);
    bpf_object__close(obj);
    return 1;
  }

  struct bpf_link *kretprobe_link = bpf_program__attach(kretprobe_prog);
  if (!kretprobe_link) {
    fprintf(stderr, "Failed to attach kretprobe: %s\n", strerror(errno));
    bpf_link__destroy(kprobe_link);
    bpf_object__close(obj);
    return 1;
  }

  // Get histogram map fd
  struct bpf_map *hist_map = bpf_object__find_map_by_name(obj, "histogram");
  if (!hist_map) {
    fprintf(stderr, "Failed to find histogram map\n");
    bpf_link__destroy(kretprobe_link);
    bpf_link__destroy(kprobe_link);
    bpf_object__close(obj);
    return 1;
  }
  int hist_fd = bpf_map__fd(hist_map);

  printf("Tracing sys_read latency... Ctrl+C to stop\n");
  printf("Histogram resets every second\n");

  while (running) {
    sleep(1);
    print_histogram(hist_fd);
    clear_histogram(hist_fd);
  }

  printf("\nDetaching probes\n");
  bpf_link__destroy(kretprobe_link);
  bpf_link__destroy(kprobe_link);
  bpf_object__close(obj);
  return 0;
}
