## Misc syscalls examples notes

### UUID
- uses getrandom syscall in a uuid v4 generator 
- getrandom syscall fills provided buffer with random bytes and can be used for
  seeding random generators or in cryptography 
- more efficient to use getrandom than /dev/urandom as it is a single syscall
  with no fd to manage
- usage: `zig run uuid_v4.zig`

### Allocator 
- demonstrates a basic allocator abstraction using syscall primitives 
- mmap = requests fresh mem pages from the kernel
- munmap = returns page to the kernel after freed, libc free just marks memory
  as available, this will actually return the mem space to the kernel. it
  therefore can only be called when entire reigon is free 
- mprotect = changes permission on page ranges, can be used to guard pages and
  detect segfaults instead of allowing memory corruption. useful for read only
  patterns and catching use after free

Understanding the allocator abstraction 
- new_reigon will ask the kernel for a contiguous chunk of cirtual address space
  via the mmap syscall. in this exampl the flags PRIVATE and ANONYMOUS mean
  there is no file backing, just zeroed out pages mapped into the process. at
  this point there is no physical RAM allocated, it is just reserves virtual
  adress range and marks it as r/w in the process page table 
- mprotect syscall marks the last page PROT_NONE aka. no read, no write, no
  execute. this is the guard, if any pointer arithmetic goes wrong by writing
  pase the end of reiogon (overflow), the CPU will raise a segfault immediately
  instead of corrupting memory.
- visualized will look something like this
[RegionHeader][block][block][block]...[free space]  [PROT_NONE]
 ◄──────────────── region_pages ──────────────────►◄─ PAGE_SIZE ─►
 - inside the mmaped space, reigon header sits at the base and holds two
   pointers to `bump` and `bump_end`.
- bump = starts just after header and advances forward for every allocation,
  this is very simplistic and does not include advanced techniques like
  searching. the result is that you cannot reclaim individual blocks back to the
  bump, once allocated they remain unles the entire bump is reset to the start 
- bump_end = points to the guard page boundary, before every alloc it checks
  that bump + n bytes needed <= bump_end, otherwise you would overflow 
- each allocated block would look something like the following in memory 
[BlockHeader][......user data......]
- BlockHeader = stores the size of the user data reigon and a next pointer for
  the free list. next is what makes it a linked list, the list metadata lives
  inside the blocks themselves 
- when calling free(reigon, slice) it walks back from the slice pointer by the
  size of the BlockHeader to recover the header and marks it as free. it is then
  added onto the reigon.free_list, this reigon now can be reused. the next time
  alloc is called, it checks the free_list before extending the bump by walking
  the chain to look for a block smaller than the requested size. if found it
  unlinks it and returns it for reuse, else it will attempt to append to the
  bump.
- alloc = if freelist has a fitting block, unlink and return it for reuse, else
  carve out from bump space 
- free = prepend block into free_list for reuse 

