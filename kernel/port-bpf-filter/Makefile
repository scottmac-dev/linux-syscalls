CC = gcc
CLANG = clang 
BPF_CFLAGS = -O2 -g -target bpf -D__TARGET_ARCH_X86

all: filter.bpf.o filter 

filter.bpf.o: src/filter.bpf.c
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@

filter: src/filter.c filter.bpf.o 

clean:
	rm -f filter.bpf.o filter 

.PHONY: all clean 
