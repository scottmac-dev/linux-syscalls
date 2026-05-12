CC = gcc
CFLAGS = -O2 -Wall

all: tun 

tun: src/tun.c 
	$(CC) $(CFLAGS) -o $@ src/tun.c 

clean:
	rm -f tun 

.PHONY: all clean 
