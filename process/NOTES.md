## Process syscalls examples notes

### Shell
- uses fork(), execve(), waitpid(), pipe2(), dup2() syscalls to demonstrate
  primitive shell pipeline 
- assumes a bunch of commands seperated by pipes '|' are external executable
  processes and pipes them together linking stdout and stdin
- usage:
    - `zig run shell.zig -- cmd1 arg1 arg2 | cmd2 | cmd3 arg1...`


