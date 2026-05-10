### General
- this program is an example of using an eBPF program designed for the traffic
  control (tc) subsystem.
- using SEC("tc") is what makes this code apply to the traffic control
  submodule however eBPF is not limited to this, it can use XDP,
  Kprobes/Uprobes, Tracepoints, LSM as hooks to attack eBPF programs too, I will
  explore these later 
- it acts as a programmable and high performance module that lives inside of the
  linux kernel, enabling firewall like behaviour where packets can be filtered
  by port number before actually being passed on to user space.
- the program defines two Maps, Maps are the primary way eBPF programs store
  state or communicate with user-space applications 
- blocked_port is an array with one slot which specifies the port number of
  which packets should be dropped (filtered). by defining this as a map it makes
  it mutable without a recompile of the code 
- drop_count is a simple counter, each time a packet is dropped the value
  increments 
- the main fn port_filter is triggered everytime a packet hits the network
  interface
- this program essentially performs the following checks on every packet that it
  receives
    1. is it a IPv4 packet? OK -> process ELSE -> skip
    2. determine the protocol, TCP or UDP?
    3. extract the destination port, if port matches blocked port drop else pass 
- return types for this specific code is 
    - TC_ACT_OK = accept packet and pass up stack 
    - TC_ACT_SHOT = drop packet 
    - TC_ACT_UNSPEC = use default system behaviour

### eBPF programming 
- for eBPF, you cant grab data at random memory addresses, the BPF Verifier
  ensures code will never crash the kernel and will not successfully compile if
  bound checks are not performed
- network data is big endian while most CPUs are little endian, bpf_htons (host
  to network slot) ensures the numbers are read correctly
- `__sk_buf` is a specialized restricted struc used in eBPF to access network
  packet metadata safely. it mirrors the kernels internal sk_buff socket buffer
