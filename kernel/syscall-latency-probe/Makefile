CC = gcc
CLANG = clang
BPF_CFLAGS = -O2 -g -target bpf -D__TARGET_ARCH_x86 -I include/
CFLAGS = -O2 -Wall

all: lat-read.bpf.o lat-read

lat-read.bpf.o: src/lat-read.bpf.c
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@

lat-read: src/lat-read.c lat-read.bpf.o
	$(CC) $(CFLAGS) -o $@ src/lat-read.c -lbpf -lelf -lz

clean:
	rm -f lat-read.bpf.o lat-read

.PHONY: all clean
