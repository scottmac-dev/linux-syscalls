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
