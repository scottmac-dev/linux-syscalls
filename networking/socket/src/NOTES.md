## Socket examples notes

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
    1. zig build-exe ping.zig
        1.1 do network priveleges on executable if failing 
    2. sudo ./ping <address>
    3. ctrl + C to exit, print stats on exit
- example: sudo ./ping google.com
