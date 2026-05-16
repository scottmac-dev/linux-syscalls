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

xortun
- similar concept to packetd but combines some eBPF logic and uses two virtual
  tun interfaces 
- bpf program intercepts packets and XORs the payload simulating an encryption,
  COR key can be set dynamically with bpf tools by adjusting the maps 
- tun0 relays received ICMP packets to tun1 another virtual interface, eBPF XORS
  the playload so tun1 receives scrambled data. 
- handler manually XORS the received packet received on tun1 and writes it pack
  to tun0 

syscall-latency-probe 
- eBPF program attaches to kprobe sys_read to bucked syscall read operations
  into latency buckets to visualize system read behaviour
- use `grep -i "sys_read" /proc/kallsyms | head -20` to find your systems kprobe
  mount point and adjust lat-read.bpf.c accordingly
- use the following operations to test different cached and disk read ops and
  see output.
    - find / -name "*.c" 2>/dev/null | head -20
    - cat /var/log/syslog
    - dd if=/dev/sda of=/dev/null bs=4096 count=1000 2>/dev/null

