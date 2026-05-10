## Networking syscalls examples notes

### TCP
- creates a basic client server connection over TCP
- client sends cli args one by one to the server address, server echos them back
  to the client which prints to the terminal
- listen() syscall used to queue incoming connections 
- accept() syscall used to establish two way connection 
- will only accept packets from one client at a time
- linux.SOCK.STREAM used as socket type
- usage:
    - server: `zig run tcp-server.zig`
    - client: `zig run tcp-client.zig -- <all of your messages...> `

### UDP
- demonstrates connectionless UDP message sending between client -> server
- server just receives packets and prints out the message to terminal
- no use of listen() or accept() as no two way connection 
- no backlog or queue as no connection handshake
- no per-client socket
- received packets from anyone
- linux.SOCK.DGRAM used as socket type
- usage:
    - server: `zig run udp-server.zig`
    - client: `zig run udp-client.zig -- <all of your messages...> `
    
### Ping
- recreates the ping command in zig but only using minimal 8 byte ICMP header 
- transmits and receives pings using ICMP protocol
- uses zig stdlib hostname resolve interfaces
- note: will probably require you to run `sudo sysctl -w net.ipv4.ping_group_range="0 2147483647"` to override network permissions
- usage: 
    - zig build-exe ping.zig
    - do network priveleges on produced executable if failing due to permissions
    - sudo ./ping <address>
    - ctrl + C to exit, will print stats on exit
- example: `sudo ./ping google.com`

### Websocket
- creates a very primitive chat server using the web socket protocol 
- connects over http 1.1, does not support full http, only the http handshake
- spawns client connections as threads allowing them to send messages to a
  shared chat feed 
- note: this is a very basic and not thoroughly tested impl, more a proof of
  concept of the websocket than a fully supported version. currently mutex
  errors are disregarded and does not guarantee thread safety. does work though 
- index.html acts as the client you can run in the browser to connect and send
  messages which are broadcasted across client connections. open multiple
  versions of this to demonstrate the multi client connect, spawn and broadcast
- usage:
    - `zig run ws-server.zig` - runs on port 5001
    - open `index.html` client in your web browser and use the very basic inputs
      to connect and send messages reflected in the server stdout and client
      page.

### Proxy 
- zero copy TCP fan out proxy using splice and tee syscalls 
- listens on port 5001 on TCP port and forwards all received bytes to downstream
  sub sockets on ports 5002 and 5003
- zero copies/alloc in user space, all handled by kernel buffers and pipes 
- splice = moves data between two fds in kernel space 
- tee = duplicated bytes of data from one pipe fd to another pipe fd. does not
  consume data duplicated and can therefore be copied by subsequent splice calls 
- rather than reading data into user space and writing out to each sub, tee
  duplicated kernel buffer references so same pages are visible in both kernel
  pipes. neither copy touches the process memory 
- similar concep to a traffic mirror which can receive traffic and shadow it
  downstream. also similar to pub/sub models at a low level
- usage:
    - Terminal 1: `zig run proxy.zig` - start listener proxy on port 5001 
    - Terminal 2: `nc -lk 127.0.0.1 5002` - start listener on port 5002 (sub0)
    - Terminal 3: `nc -lk 127.0.0.1 50033` - start listener on port 5003 (sub1)
    - Terminal 4: `echo "<message>" | nc 127.0.0.1 5001` - send message bytes to
      listener proxy
- what ever is sent in <message> should be simultaneously forwarded and output
  to terminal 2 & 3 subscriber ports

### Traceroute
- primitive reimplementation of the traceroute networking tool 
- sends icmp packets varying over different ttl ranges to map network hops at
  each stage 
- uses raw sockets instead of datagrams for full control and accessibility to
  packet structure and headers 
- usage: 
    - zig build-exe ping.zig
    - do network priveleges on produced executable if failing due to permissions
    - sudo ./traceroute <address>
    - ctrl + C to exit, will print stats on exit
- example: `sudo ./traceroute google.com`

### Arp/netscan
- sends broadcast arp request to discover ip addresses on the local network 
- prints out list of ip addresses than responded to arp 
- defaults to interface `eth0` unless specified via args, this will return a
  error if this is not your network interface 
- to find your interface use `ip link` to find your connected interface 
- usage:
    - zig build-exe netscan.zig
    - sudo ./netscan <interface>
- example: `sudo ./netscan eno0`
