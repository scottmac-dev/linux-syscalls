## Kernel notes
This folder is less about syscalls themselves and more about exploring linux kernel
specific concepts and development workflows.

As this aligns more with kernel rather than userspace development, all projects
in this directory will be in C not zig 

port-bpf-filter 
- uses eBPF program to run in kernel space and block inbound packets for a given
  port number
- user space filter.c logs packets received and dropped 
- binds to linux TC ingress

packetd 
- implements a virtual tun0 interface that can be assigned a ip address and will
  respond to icmp ping requests with icmp echo responses
- a TUN is a kernel abstraction letting userspace programs pretend to be a
  network interface, it short circuits the normal hand off to hardware drivers
  for packet processing.
- for a TUN the driver is a file descriptoe the userspace program uses.
- other than this the kernel processes packets the same as if it came from a
  reac NIC, so when TUN writes back to the fd the kernel is processing the icmp
  echo as if it came from real hardware.
