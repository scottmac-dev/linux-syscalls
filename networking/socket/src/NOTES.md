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
    


