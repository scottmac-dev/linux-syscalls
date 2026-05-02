//! Primitive allocator abstraction using linux syscalls
//! Slab style allocator using below layout, allocated fixed size blocks
//!┌─────────────────────────────────────────────┐
//!│  RegionHeader  (one per mmap call)          │
//!│  - total size                               │
//!│  - free list head                           │
//!├─────────────────────────────────────────────┤
//!│  BlockHeader │ user data                    │
//!│  BlockHeader │ user data                    │
//!│  BlockHeader │ user data                    │
//!│  ...                                        │
//!├─────────────────────────────────────────────┤
//!│  Guard page (PROT_NONE via mprotect)        │
//!└─────────────────────────────────────────────┘
//!
const std = @import("std");
const linux = std.os.linux;

const PAGE_SIZE = 4096;

// block layout within a region:
// each free block's data area holds a ?*BlockHeader next pointer.
const BlockHeader = struct {
    size: usize, // bytes of user data (excludes header)
    free: bool,
    next: ?*BlockHeader, // intrusive linked list stored in header not data area
};

// region layout: [ RegionHeader | blocks... | guard page (PROT_NONE) ]
const RegionHeader = struct {
    total: usize, // total mmap'd size including guard page
    bump: [*]u8, // next free byte in the region
    bump_end: [*]u8, // one past last usable byte
    free_list: ?*BlockHeader,
};

fn align_up(n: usize, alignment: usize) usize {
    return (n + alignment - 1) & ~(alignment - 1);
}

// mmap a fresh region large enough for the header + one block of `min_size`,
// with a PROT_NONE guard page appended at the end.
fn new_region(min_size: usize) !*RegionHeader {
    const data_needed = @sizeOf(RegionHeader) + @sizeOf(BlockHeader) + min_size;
    const region_pages = align_up(data_needed, PAGE_SIZE);
    const total = region_pages + PAGE_SIZE; // +1 guard page

    const addr = linux.mmap(
        null,
        total,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    if (linux.errno(addr) != .SUCCESS) return error.MmapFailed;

    // mark the last page PROT_NONE, any overrun segfaults immediately
    const base: [*]u8 = @ptrFromInt(addr);
    const guard = base + region_pages;
    const rc = linux.mprotect(guard, PAGE_SIZE, .{}); // all false = PROT_NONE
    if (linux.errno(rc) != .SUCCESS) return error.MprotectFailed;

    // initialise region header at base of mapping
    const region: *RegionHeader = @ptrCast(@alignCast(base));
    region.total = total;
    region.free_list = null;

    // bump starts just after the region header
    region.bump = base + @sizeOf(RegionHeader);
    region.bump_end = guard;

    return region;
}

// allocate memory inside a reigon
fn alloc(region: *RegionHeader, size: usize) ![]u8 {
    const aligned = align_up(size, @alignOf(BlockHeader));

    // check free list first
    var current = region.free_list;
    var prev: ?*BlockHeader = null;
    while (current) |block| {
        if (block.size >= aligned) {

            // unlink from free list
            if (prev) |p| {
                p.next = block.next;
            } else {
                region.free_list = block.next;
            }
            block.free = false;
            block.next = null;
            const data: [*]u8 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(block)) + @sizeOf(BlockHeader)));
            return data[0..size];
        }
        prev = block;
        current = block.next;
    }

    // carve from bump region
    const header_size = @sizeOf(BlockHeader);
    const needed = header_size + aligned;
    const bump_addr = @intFromPtr(region.bump);
    const end_addr = @intFromPtr(region.bump_end);

    if (bump_addr + needed > end_addr) return error.OutOfMemory;

    const block: *BlockHeader = @ptrCast(@alignCast(region.bump));
    block.size = aligned;
    block.free = false;
    block.next = null;

    region.bump += needed;

    const data: [*]u8 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(block)) + header_size));
    return data[0..size];
}

// marks block as free but doesn't release to kernel with munmap
fn free(region: *RegionHeader, ptr: []u8) void {
    const raw: [*]u8 = @ptrCast(ptr.ptr);
    const block: *BlockHeader = @ptrCast(@alignCast(raw - @sizeOf(BlockHeader)));
    block.free = true;

    // prepend to free list
    block.next = region.free_list;
    region.free_list = block;
}

// uses munmap to release memory page back to kernel
fn release(region: *RegionHeader) !void {
    const base: [*]const u8 = @ptrCast(region);
    const rc = linux.munmap(base, region.total);
    if (linux.errno(rc) != .SUCCESS) return error.MunmapFailed;
}

fn demo_stress() !void {
    std.debug.print("\n=== stress test ===\n", .{});

    const region = try new_region(PAGE_SIZE * 4);
    defer release(region) catch {};

    const ITERS = 1000;
    const MAX_ALLOCS = 16;
    var live: [MAX_ALLOCS]?[]u8 = [_]?[]u8{null} ** MAX_ALLOCS;
    var prng = std.Random.DefaultPrng.init(12345);
    const rand = prng.random();

    var total_allocs: usize = 0;
    var total_frees: usize = 0;

    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        // pick a random slot
        const slot = rand.uintLessThan(usize, MAX_ALLOCS);

        if (live[slot]) |existing| {
            // verify the canary written at alloc time is intact
            // corruption means a previous alloc/free scribbled over it
            const expected: u8 = @truncate(slot * 7 + 1); // deterministic per slot
            for (existing) |byte| {
                if (byte != expected) {
                    std.debug.print("CORRUPTION at slot {d}: expected 0x{x:0>2} got 0x{x:0>2}\n", .{ slot, expected, byte });
                    return error.CorruptionDetected;
                }
            }
            free(region, existing);
            live[slot] = null;
            total_frees += 1;
        } else {
            // vary sizes to exercise different free list buckets
            const size = (slot + 1) * 16; // 16, 32, 48 ... 256
            const mem = alloc(region, size) catch continue; // skip if OOM
            const canary: u8 = @truncate(slot * 7 + 1);
            @memset(mem, canary);
            live[slot] = mem;
            total_allocs += 1;
        }
    }

    // free anything still live
    for (live) |maybe| {
        if (maybe) |m| free(region, m);
    }

    std.debug.print("[stress] {d} allocs, {d} frees — no corruption detected\n", .{ total_allocs, total_frees });
}

// sigaction handler, prove segfault caught and exit cleanly
fn segfault_handler(_: linux.SIG) callconv(.c) void {
    const msg = "[guard] SIGSEGV caught — overrun hit the PROT_NONE guard page\n";
    _ = linux.write(2, msg, msg.len);
    // restore default and re-raise so the process exits with SIGSEGV status
    // rather than looping forever
    var sa = linux.Sigaction{
        .handler = .{ .handler = linux.SIG.DFL },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.SEGV, &sa, null);
    _ = linux.kill(linux.getpid(), linux.SIG.SEGV);
}

// demo segfault when writing to guard page
fn demo_guard_page() !void {
    std.debug.print("\n=== guard page demo ===\n", .{});

    // install SIGSEGV handler
    var sa = linux.Sigaction{
        .handler = .{ .handler = segfault_handler },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.SEGV, &sa, null);

    const region = try new_region(64);

    // allocate right up near the end of usable space
    const slice = try alloc(region, 64);
    std.debug.print("[guard] allocated 64 bytes at 0x{x}\n", .{@intFromPtr(slice.ptr)});
    std.debug.print("[guard] guard page at 0x{x}\n", .{@intFromPtr(region.bump_end)});
    std.debug.print("[guard] writing past end of allocation into guard page...\n", .{});

    // deliberately walk off the end — this should segfault into our handler
    const raw: [*]u8 = slice.ptr;
    var i: usize = 0;
    while (true) : (i += 1) {
        raw[i] = 0xFF; // will hit PROT_NONE page and raise SIGSEGV
    }
}

// main demo tests out allocator behaviour
pub fn main() !void {
    const region = try new_region(1024);
    defer release(region) catch {}; // return reigon memory

    // allocate three blocks
    const a = try alloc(region, 64); // alloc block A into bump
    const b = try alloc(region, 128); // alloc block B into bump
    const c = try alloc(region, 32); // alloc block C into bump

    // make all values in blocks equal the same value value
    @memset(a, 0xAA);
    @memset(b, 0xBB);
    @memset(c, 0xCC);

    // demonstrate allocated memory
    // expected = a[0]=0xaa b[0]=0xbb c[0]=0xcc
    std.debug.print("=== demo usage ===\n", .{});
    std.debug.print("a[0]=0x{x:0>2} b[0]=0x{x:0>2} c[0]=0x{x:0>2}\n", .{ a[0], b[0], c[0] });

    // free b and reallocate should reuse the same block from free_list
    const b_ptr = b.ptr;
    free(region, b);
    std.debug.print("b freed\n", .{});

    // checks free_list, finds B size 128 to fit, unlinks it and is returned
    const b2 = try alloc(region, 128);
    std.debug.print("b reallocated as b2\n", .{});

    // memory wasnot zeroed or touched between free and alloc is it should contain 0xBB
    // free doesn't destroy the prev memory, just makes it available again
    std.debug.print("b2[0]=0x{x:0>2}\n", .{b2[0]});
    std.debug.print("b reused: {}\n", .{b2.ptr == b_ptr});

    // free all reigons
    free(region, a);
    free(region, b2);
    free(region, c);

    // do stress test
    try demo_stress();

    // guard page last — process exits via SIGSEGV after catching it
    try demo_guard_page();
}
