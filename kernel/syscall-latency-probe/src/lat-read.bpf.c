#include "../include/types.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <linux/bpf.h>

// Number of histogram latency buckets (microseconds)
// 0: 0-1us, 1: 1-10us, 2: 10-100us, 3: 100-1000us, 4: 1000us+
#define NUM_BUCKETS 5

// Per-pid entry timestamp map
// Keyed by pid, value is the ktime_get_ns() at syscall entry
struct {
  __uint(type, BPF_MAP_TYPE_HASH);
  __uint(max_entries, 10240);
  __type(key, __u32);
  __type(value, __u64);
} entry_ts SEC(".maps");

// Histogram map
// Index = bucket, value = count of syscalls in that bucket
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __uint(max_entries, NUM_BUCKETS);
  __type(key, __u32);
  __type(value, __u64);
} histogram SEC(".maps");

// kprobe attach point fires at sys_read entry
SEC("kprobe/__x64_sys_read")
int kprobe_sys_read(struct pt_regs *ctx) {
  __u32 pid = bpf_get_current_pid_tgid() & 0xFFFFFFFF;
  __u64 ts = bpf_ktime_get_ns();
  bpf_map_update_elem(&entry_ts, &pid, &ts, BPF_ANY);
  return 0;
}

// kretprobe attach point fires at sys_read return
SEC("kretprobe/__x64_sys_read")
int kretprobe_sys_read(struct pt_regs *ctx) {
  __u32 pid = bpf_get_current_pid_tgid() & 0xFFFFFFFF;

  // Look up entry timestamp for this pid
  __u64 *start = bpf_map_lookup_elem(&entry_ts, &pid);
  if (!start)
    return 0;

  // Compute delta in microseconds
  __u64 delta_us = (bpf_ktime_get_ns() - *start) / 1000;

  // Clean up entry timestamp
  bpf_map_delete_elem(&entry_ts, &pid);

  // Bucket the delta
  __u32 bucket;
  if (delta_us < 1)
    bucket = 0; // 0-1us
  else if (delta_us < 10)
    bucket = 1; // 1-10us
  else if (delta_us < 100)
    bucket = 2; // 10-100us
  else if (delta_us < 1000)
    bucket = 3; // 100-1000us
  else
    bucket = 4; // 1000us+

  // Increment histogram bucket atomically
  __u64 *count = bpf_map_lookup_elem(&histogram, &bucket);
  if (count)
    __sync_fetch_and_add(count, 1);

  return 0;
}

char LICENSE[] SEC("license") = "GPL";
