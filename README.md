## Exploring, learning, documenting, implementing linux syscalls

### Syscalls Done
NETWORKING
- socket
- bind 
- listen 
- connect
- accept
- send / recv
- setsockopt
- getaddrinfo (via zig interfaces, kind of)

FILESYSTEM
- sendfile: alloc free file transfer
- open
- close
- stat / statx
- read
- write
- inotify: file system watching and notification
- poll 
- signals -> sigaction

PROCESS 
- fork: forks child process
- execve: executes child process
- pipe2

### TODO
PROCESS
- wait4
- clone: syscall behind fork
- exit_group
- getpid / gettid: accessing process ids

UNIX
- dup 2/3
- epoll_* 
- eventfd
- timerds
- signals -> kill, sigprocmask, singalfd, sigalstack

MEMORY
- mmap
- munmap
- mprotect
- brk
- masvise
- memfd_create

FILESYSTEM
- openat
- lseek
- ioctl
- mkdir / unlink / rename

NETWORKING
- accept4
- socketpair: bidirectional pipe and IPC

MISC
- futex: lowest level mutex primitive
- seccomp: sandboxing primitive
- getrandom: /dev/urandom alternative
- nanosleep
- io_uring_setup
