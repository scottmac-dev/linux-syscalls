## Filesystem syscalls examples notes

### Sendfile
- creates a basic client server connection over TCP
- sendfile server uses the sendfile syscall to write to the client socket the
  full contents of a text file with zero alloc in userspace
- client connects to sendfile server and prints the received file data 
- usage:
    - server: `zig run sendfile-server.zig`
    - client: `zig run sendfile-client.zig`

### Inotify
- inotify is linux syscall for watching directories or files for access/modification, which can then notify/log/signal when accessed or modified 
eg. when test.txt accesses log meta data about the access event
- fd = file descriptor, which is a int handler representing a file or resource for reading or writing. Can be provided to the kernel via syscall to indicate 
the resource to be accessed. contains/reads inotify struct events as byte array
- event queue = returned by the inotify syscall is a event queue that holds file system events for the provided file descriptor, to read them in order
the user program can read from the event queue for a logical order of file access/modifications
- you get a fd to the event queue, also known as a inotify instance with the inotify_init() method 
  * inotify_init() basic call will track any inotify event 
  * inotify_init1(flags) allows you to specify specific flags as a bitmask to only track specific behaviour, flags=0 is exact same behavior as default
    bsically just a more controlled and extended version of the above
    allows you to set IN_NOBBLOCK to specify non blocking behvaiour
- wd = watch descriptor a inotify construct to represent a id associated with a fd being watched, different to normal fd, no I/O, more to just track file 
being watched with a unique ID, has no reference to file name or fd
- inotify_add_watch(event_q, abs_file, watch flags) = to add a watch on a file 
- inotify_event = the main event struct retuned when watching a fd via wd and event_q 
  * wd = unique watch descriptor 
  * mask = bitmask flags indicating type of event (can be multiple but normally one)
  * cookie = tracks for similar events, eg MOVE_FROM and MOVE_TO will have same cookie despite being different events 
  * len = size of optional name field 
  * name = only populated when watching a directory, will contain the name of the file modified in the dir
- inotify_rm_watch(fd, wd) used to remove the watch to stop tracking fs resource 
- poll() also used in this example to make the main watch loop non-blocking, the
  daemon polls the event queue and only enter the main logic when a new event
  occurs, saving the CPU from spinning on useless cycles
- usage:
    - `zig run inotify-daemon.zig -- [./your/file.txt, ./your/diectory..]`
    - This will start the daemon, fs events will be tracked on the resources
    provided as args. 
    - Events will be logged to stdout and also appended to a log file at /tmp/inotify-log
- NOTE: currently the example is pretty buggy, it works but detects odd events
  which dont always match the specified resource or type
