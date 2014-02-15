dissem
======

DIStributed SEMaphore

Simple tool to allow synchronizitation of (e.g. test) scripts across multiple sessions/hosts.

Features
----------------

### Configuration
1. The central server where the server instance of the dissem runs
2. Port number
3. Rules for recycling the barriers

### Server

Server instance is started on one of the hosts with command:

    dissem --server

On other client hosts, the IP address/port of the server can be made known either via config file or an environment variable. For example, on all the participating :

    export DISSEM_FLAGS="--port=34567 --addr=<addr-of-the-dissem-server-host>"

See `dissem --help` output for more options. The `--port` option is read by both client and server, while the `--addr` is only by the clients.

### Semaphore

http://en.wikipedia.org/wiki/Semaphore_(programming)

#### Syntax

    dissem sem [semaphore_name] [delta]

#### Lifecycle
The semaphore is created first time it is accessed. Initial value is always 0. The semaphore exists until the server instance of dissem is not restarted.

#### Example1: Simple transaction
On server1:

    dissem sem SEM001 -1
 
On server2:

    dissem sem SEM001 1
 
As soon as the dissem on server2 returns, the dissem on server1 unblocks.

#### Example2: Many servers/sessions
On server1:

    dissem sem SEM001 -1
 
On server2:

    dissem sem SEM001 -1
 
On server3:

    dissem sem SEM001 -1
 
On server4:

    dissem sem SEM001 -1

On server5:

    dissem sem SEM001 4
 
Result: the dissems on server 1-4 block; the dissem on server5 returns without blocking; the dissems on server 1-4 unblock. Value of the semaphore after the transaction is 0.

#### Example3: Display current semaphore count

    dissem sem SEM001 0

### Barrier

http://en.wikipedia.org/wiki/Barrier_(computer_science)

#### Syntax

    dissem barrier [barrier_name] [count]

The `count` is the count of the servers which are going to wait the barrier.
    
#### Lifecycle

TBD.

Since barriers allow for inconsistent syntax (wrong count of the participants) some error handling is desired. To allow error handling on the barrier which was already fired, one has to keep it around in memory. That makes it hard to distinguish whether the new client is one-too-many from the previous transaction or the new client want to use the barrier again.

First practical experiences indicate that trying to catch all usage errors in the case is redunant. But one of the implementation ideas can be the 'tagged clients': every barrier client has a unique tag, barrier accepts only N first unique tagged clients - other clients, as well as untagged clients, are rejected.

#### Rationale

Implementing a barrier with the semaphores is PITA.

#### Example1: Sync on two servers
On server1, at any time:

    dissem barrier BR001 2
    
On server2, at any time:

    dissem barrier BR001 2

As soon as the dissem commands were fired on both servers, they would unblock on both servers simultaneously.

Implementation
--------------

The `dissem` is (was started?) as a testbed to see what tool is feasible to implement to help run distributed tests where applications are running across number of servers.

Current design is client-server. There should be one instance of `dissem` running as a server at address:port known to/reacheable by clients.

The server instance keep the track of the synchronization structures.

Client connects to the server using TCP/IP. The arguments passed by user to the client `dissem` are sent to the server. Blocking of a client (the waiting) is accomplished by not sending it the response. Similarly, unblocking of a client is done by sending is the response.

Status
------

Configuration via conf file or environment variable is now supported. The syntax is almost the same as on the command line: use of `=` in `--opt=value`, unlike the command line, is required. Example config file is included. Example env var is given above.

Verbosity now can be controlled by `--verbose` and `--quiet` options.


### TODO
- [x] Make the core functionality working to explore feasibility and test usability
- [ ] Figure out the problem with the barrier lifecycle vs. error handling, probably via options allow configurable behavior.
- [ ] Add perldoc help
- [x] Add command line options
- [x] Add passing options via environment variables (e.g. address:port of the dissem server)
- [x] Add config file?
- [ ] Remove the 'die's from the code.
- [ ] Add monitoring of the synchronization objects.
