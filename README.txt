COM3026 SUMMATIVE ASSIGNMENT
CHRIS DIGBY, 6578971
STOCK MANAGEMENT SYSTEM


### OVERVIEW ###

The file "stock_management_server.ex" implements the application server of a basic distributed service
for keeping track of stock levels for items in the inventory of for example a shop, a restaurant, etc.

Clients can submit commands to any replica of the server, and all replicas of the server
will use Paxos to 1) agree on the order of execution of received commands and 2) replciate the
command history over all instances of the server.

Multiple clients may submit commands concurrently, however each client may only have one pending command
at a time.

The file "stock_management_client.ex" implements the client backend for the service. The functions of this backend are to:
  1) Provide a background process which uses the increasing timeout failure detector and monarchical leader election to 
     select which server commands should be submitted to. The aim is that eventually, all clients will have selected the same
     leader, solving the concurrent proposals problem.

  2) Provide an API which a client frontend (not implemented) can call to submit commands to the server. The API functions
     retrieve a leader from the client backend process, and then attempt to submit the command to server considered leader.
     the server then replies directly to the process that called the API. The API will attempt 5 retries if the
     server replies with :abort or if a leader could not be selected.


### API ###

StockManagementServer.start(name, paxos_proc)
    - Starts a new replica of the application server

    - Parameters:
        name - The symbolic name of this replica
        paxos_proc - The symbolic name of the process this replica will use
                    to communicate with the Paxos layer

    - Returns:
        pid: The pid of the new replica

StockManagementClient.start(name, servers)
    - Starts the application clietn background process

    - Parameters:
        name - The symbolic name of the background process
        servers - A list of the symbolic names of all replicas of the application server

    - Returns:
        pid: The pid of the client background process

StockManagementClient.create_item(backend, item)
    - Creates a new item record

    - Parameters:
        backend - The pid of the client background process
        item - The symbolic name of the new item e.g. :cheese

    - Returns:
        :ok - Creation of the item succeeded
        :err_duplicate_item - The item already exists
        :fail - The operation was attempted 5 times, and each time either the operation was aborted at the Paxos
                layer or the background process did not provide a leader
        :timeout - The operation timed out


StockManagementClient.delete_item(backend, item)
    - Deletes an item record

    - Parameters:
        backend - The pid of the client background process
        item - The symbolic name of the item to delete

    - Returns:
        :ok - Deletion of the item succeeded
        :err_no_such_item - The item does not exist
        :fail - The operation was attempted 5 times, and each time either the operation was aborted at the Paxos
                layer or the background process did not provide a leader
        :timeout - The operation timed out


StockManagementClient.add_stock(backend, item, quantity)
    - Adds stock to an item

    - Parameters:
        backend - The pid of the client background process
        item - The symbolic name of the item
        quantity - Quantity to increase the stock level by

    - Returns:
        qty - The new stock level on success
        :err_no_such_item - The item does not exist
        :fail - The operation was attempted 5 times, and each time either the operation was aborted at the Paxos
                layer or the background process did not provide a leader
        :timeout - The operation timed out


StockManagementClient.remove_stock(backend, item, quantity)
    - Removes stock from an item

    - Parameters:
        backend - The pid of the client background process
        item - The symbolic name of the item
        quantity - Quantity to decrease the stock level by

    - Returns:
        qty - The new stock level on success
        :err_no_such_item - The item does not exist
        :err_insufficient_stock - The current stock level is less than the quantity to remove
        :fail - The operation was attempted 5 times, and each time either the operation was aborted at the Paxos
                layer or the background process did not provide a leader
        :timeout - The operation timed out


StockManagementClient.query_stock(backend, item)
    - Queries the current stock level of an item

    - Parameters:
        backend - The pid of the client background process
        item - The symbolic name of the item to query

    - Returns:
        qty - The current stock level on success
        :err_no_such_item - The item does not exist
        :fail - The operation was attempted 5 times, and each time either the operation was aborted at the Paxos
                layer or the background process did not provide a leader
        :timeout - The operation timed out


### SAFETY PROPERTIES ###

- The total stock for any item is always equal to the total stock added minus the total
  stock removed.

- The total stock for any item is always greater than or equal to 0

- When adding or removing stock, the quantity must be greater than or equal to 1

- No two items may share the same symbolic name

- No operation (other than create) may be performed on an item for which there
  is no record on the server


### LIVENESS PROPERTIES ###

- Every client operation will terminate provided that:
    1) The system behaves synchronously for sufficiently long
    2) No more than a minority of replicas fail

- Eventually, all clients will trust the same server replica as leader, at which point every client
    operation will succeed (or return an application level error such as :err_no_such_item)


### USAGE ###

# Environment setup and compilation
1) Make sure that the Elixir package is installed on your system
2) Save paxos.ex, stock_management_server.ex and stock_management_client.ex to the same directory
3) Open a terminal in the directory that you saved the three source files to
4) Use the `iex` command to launch an interactive session
5) Compile Paxos using `c "paxos.ex"`
6) Compile the server using `c "stock_management_server.ex"`
7) Compile the client using `c "stock_management_client.ex"`

# Example usage
1) Define the names of your Paxos replicas: `paxos_procs = [:p1, :p2, :p3]`
2) Start the Paxos replicas: `paxos_pids = Enum.map(paxos_procs, fn p -> Paxos.start(p, paxos_procs) end)`
3) Define the names of your server replicas: `servers = [:s1, :s2, :s3]`
4) Start the server replicas: `server_pids = Enum.map(servers, fn s -> StockManagementServer.start(s, Enum.at(paxos_procs, Enum.find_index(servers, fn x -> x == s end))) end)`
    - Note the above command assumes an equal number of Paxos and server replicas
5) Start an instance of the client: `c1 = StockManagementClient.start(:client1, servers)`
4) Create an item record via client 1: `StockManagementClient.create_item(c1, :cheese)`
5) Add some stock to the item: `StockManagementClient.add_stock(c1, :cheese, 10)`
6) Kill one of the server replicas `Process.exit(Enum.at(server_pids, 0), :kill)`
    - This will be the leader since :s1 will be selected as leader first if it is alive
7) Query the stock of the item you created previously: `StockManagementClient.query_stock(c1, :cheese)`
8) Observe that after killing :s1, a new leader was selected (:s2), and since the server's state is replicated, the result of the command is as expected
9) Start another instance of the client: `c2 = StockManagementClient.start(:client2, servers)`
10) Execute two concurrent operations from different clients:
    `spawn(fn -> StockManagementClient.add_stock(c1, :cheese, 5) end); spawn(fn -> StockManagementClient.add_stock(c2, :cheese, 5) end)`
11) Query the stock again and observe that both operations were successful: `StockManagementClient.query_stock(c1, :cheese)`


### ASSUMPTIONS ###

- The system operates under partial synchrony

- No more than a minority of replicas fail

- Each distinct client may only have one pending command on the server at any one time.

### EXTRA FEATURES ###
    
    - An unlimited number of clients may concurrently execute commands on the same server, and the commands will be executed
        in the order the server receives them.

    - If the server proposes a command to Paxos and a different decision is returned, it will automatically retry the command
        until either it succeeds or :abort is returned.

    - A client backend implementing failure detection and leader election is provided, ensuring that eventually all clients submit their
        commands to the same server replica. This solves the problem of multiple replicas simultaneously competing for the same Paxos instance.

    - If a command is aborted or a leader could not be elected, the client will automatically retry up to 5 times before returning :fail.
