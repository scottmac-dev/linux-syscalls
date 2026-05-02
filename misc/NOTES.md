## Misc syscalls examples notes

### UUID
- uses getrandom syscall in a uuid v4 generator 
- getrandom syscall fills provided buffer with random bytes and can be used for
  seeding random generators or in cryptography 
- more efficient to use getrandom than /dev/urandom as it is a single syscall
  with no fd to manage

