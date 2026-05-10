## Exploring, learning, documenting, implementing linux syscalls

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
- signals -> sigaction, kill

PROCESS 
- fork: forks child process
- execve: executes child process
- pipe2
- dup2
- tee
- splice
- waitpid
- getpid

MISC 
- getrandom: /dev/urandom alternative
- mmap
- munmap
- mprotect

IOURING
- io_uring_setup
- io_uring_enter
- mmap 
- munmap
