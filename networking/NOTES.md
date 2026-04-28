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
