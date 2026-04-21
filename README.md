## Exploring, learning, documenting, implementing linux syscalls

### Syscalls 

### TODO
PROCESS
- fork: forks child process
- execve: executes child process
- wait4
- clone: syscall behind fork
- exit_group
- getpid / gettid: accessing process ids

UNIX
- pipe2
- dup 2/3
- epoll_* 
- poll 
- eventfd
- timerds
- signals -> kill, sigaction, sigprocmask, singalfd, sigalstack

MEMORY
- mmap
- munmap
- mprotect
- brk
- masvise
- memfd_create

FILE I/O
- open / openat
- read
- write
- close
- lseek
- stat / statx
- ioctl
- sendfile: alloc free file transfer

FILESYSTEM
- inotify: file system watching and notification
- mkdir / unlink / rename

NETWORKING
- socket
- bind 
- listen 
- connect
- accept4
- send / recv
- setsockopt
- getaddrinfo
- socketpair: bidirectional pipe and IPC

MISC
- futex: lowest level mutex primitive
- seccomp: sandboxing primitive
- getrandom: /dev/urandom alternative
- nanosleep
- io_uring_setup
