CC = gcc
CLANG = clang 
BPF_CFLAGS = -O2 -g -target bpf -D__TARGET_ARCH_X86 -I include/
CFLAGS = -O2 -Wall

all: xortun.bpf.o xortun 

xortun.bpf.o: src/xortun.bpf.c
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@

xortun: src/xortun.c xortun.bpf.o
	$(CC) $(CFLAGS) -o $@ src/xortun.c -lbpf -lelf -lz

clean:
	rm -f xortun.bpf.o xortun 

.PHONY: all clean 
