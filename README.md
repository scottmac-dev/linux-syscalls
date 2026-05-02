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
- dup2
- tee
- splice
- waitpid

### TODO
PROCESS
- clone: syscall behind fork

UNIX
- epoll_* 
- eventfd
- timerds
- signals -> kill, sigprocmask, singalfd, sigalstack

MEMORY
- mmap
- munmap
- mprotect

FILESYSTEM
- openat
- lseek
- ioctl
- mkdir / unlink / rename

NETWORKING
- socketpair: bidirectional pipe and IPC

MISC
- futex: lowest level mutex primitive
- seccomp: sandboxing primitive
- getrandom: /dev/urandom alternative
- nanosleep
- io_uring_setup
