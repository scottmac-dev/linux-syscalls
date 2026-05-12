#include "../include/types.h"
#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/pkt_cls.h>
#include <linux/tcp.h>
#include <linux/udp.h>

// Map: stores blocked port (key=0, value=port num)
// Store as map to make port changable from user space, constant port
// would be static
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __uint(max_entries, 1);
  __type(key, __u32);
  __type(value, __u16);
} blocked_port SEC(".maps");

// Map: counter of dropped packets
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __uint(max_entries, 1);
  __type(key, __u32);
  __type(value, __u64);
} drop_count SEC(".maps");

// Apply to the tc submodule
SEC("tc")
int port_filter(struct __sk_buff *skb) {
  void *data = (void *)(long)skb->data;         // data from socket buff
  void *data_end = (void *)(long)skb->data_end; // bounds

  // Parse ethernet header
  struct ethhdr *eth = data;
  if ((void *)(eth + 1) > data_end)
    return TC_ACT_OK; // end of data, must do bounds check

  // Only allow IPv4, other types ok
  if (eth->h_proto != bpf_htons(ETH_P_IP))
    return TC_ACT_OK;

  // Parse IP header
  struct iphdr *ip = (void *)(eth + 1);
  if ((void *)(ip + 1) > data_end)
    return TC_ACT_OK; // bounds check

  __u16 dst_port = 0;

  // Parse TCP/UDP destination port
  if (ip->protocol == IPPROTO_TCP) {
    struct tcphdr *tcp = (void *)(ip + 1);
    if ((void *)(tcp + 1) > data_end)
      return TC_ACT_OK; // bounds check

    dst_port = bpf_ntohs(tcp->dest);
  } else if (ip->protocol == IPPROTO_UDP) {
    struct udphdr *udp = (void *)(ip + 1);
    if ((void *)(udp + 1) > data_end)
      return TC_ACT_OK; // bounds check

    dst_port = bpf_ntohs(udp->dest);
  } else {
    return TC_ACT_OK; // dont worry about other protocols
  }

  // Lookup dst port against blocked port
  __u32 key = 0;
  __u16 *blocked = bpf_map_lookup_elem(&blocked_port, &key);
  if (!blocked || *blocked == 0)
    return TC_ACT_OK; // no port set

  if (dst_port == *blocked) {
    // match on blocked port, drop packet, ++ counter
    __u64 *count = bpf_map_lookup_elem(&drop_count, &key);
    if (count)
      __sync_fetch_and_add(count, 1);

    return TC_ACT_SHOT; // drop
  }

  return TC_ACT_OK;
}

char LICENSE[] SEC("license") = "GPL";
