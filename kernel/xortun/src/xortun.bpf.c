#include "../include/types.h"
#include <bpf/bpf_helpers.h>
#include <linux/bpf.h>

// Map: stores 4 byte XOR key used to 'encrypt' message from TUN
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __uint(max_entries, 1);
  __type(key, __u32);
  __type(value, __u32); // XOR key
} xor_key SEC(".maps");

char LICENSE[] SEC("license") = "GPL";
