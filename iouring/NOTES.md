## Notes from learning / using io_uring

### General
- io_uring linux syscall successor to epoll, it provides a unified
  high-performance interface for many syscalls, but often used for networking 
  due to its async nature
- in traditional I/O every operation requires a context switch from user space
  to kernel space, these become significantly expensive due to page table
  isolations.
- io_uring attempts to solve this via batching (submitting many requests SQEs,
  in a single io_uring_enter call) and polling (SQPOLL which if enabled the
  kernel starts a dedicated thread to poll SQ). Once the rings are set up you
  can perform many variations of I/O without making syscalls, you write to the
  ring buffer memory and the kernel can see it.
- generally the choice for when simple and functional is not enough and you need
  high performance and are willing to handle increased complexity.
- if using io_uring you generally want linux kernel 5.10+ for stability but 5.15
  -> 6+ is where advanced feature sets mature 
- when using this interface, you are responsible for handling state and tracking
  which requests belong to completions via user_data field it the SQE
- common use cases include high concurrency servers or data base engines

### io_uring architecture 
- uses two circular ring buffers shared between kernel and user space. this
  shared meory allows you to pass data to the kernel without repeated syscalls.
- Submission Queue (SQ): this is there the userspace tells the kernel what you
  want to do, eg read a file, accept a socket connection. these entries are
  pushed to the SQ and are called SQ entries (SQE). known as pushing onto the
  SQE ring.
- Completion Queue (CQ): this is where the kernel puts the results, it pushes
  CQEs onto the ring once the task is finished
- fixed buffers: these are pre registered memory buffers in the kernel that
  avoids the overhead of mapping/unmapping memory each I/O operation 
- fixed files: pre registered file descriptors (fd) that reduces the kernel
  overhead of looking up file pointers 
- linked SQEs: allow you to chain operations together and ensure operations
  happen in specific order without user space interventions


### notable benchmarks 
supposedly the following is acheived by various production servers for bare
metal linux 
- Nginx static files: ~100-200k req/sec single core, scales linearly with cores
- H2O: ~300-400k req/sec single core, one of the fastest production servers
- Caddy: ~80-120k req/sec, slower due to Go GC
- Actix-web (Rust): ~300-500k req/sec single core

