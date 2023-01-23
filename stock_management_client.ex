defmodule StockManagementClient do
    # Start the stock management client backend, with a list of servers that can be used to execute commands
    def start(name, servers) do
        pid = spawn(StockManagementClient, :init, [name, servers])
        pid = case :global.re_register_name(name, pid) do
            :yes -> pid  
            :no  -> nil
        end
        IO.puts(if pid, do: "registered #{name}", else: "failed to register #{name}")
        pid
    end

    # Initialise the stock management client
    def init(name, servers) do
        state = %{
            name: name,
            servers: MapSet.new(servers),

            # Leader election using increasing timeout for failure detection
            delta: 2000,   # value to increase timeout by 
            delay: 2000,   # timeout
            alive: MapSet.new(servers),
            suspected: %MapSet{},
            leader: get_pid(maxrank(servers))
        }

        # Schedule first timeout
        Process.send_after(self(), {:timeout}, state.delay)
        run(state)
    end

    # Leader election state machine
    def run(state) do
        state = receive do
            {:get_leader, client} ->
                # Select a leader out of all the processes we don't suspect
                state = %{state | leader: get_pid(maxrank(MapSet.to_list(MapSet.difference(state.servers, state.suspected))))}
                # Send the new leader to the frontend
                send(client, {:leader, state.leader})
                state

            {:timeout} ->
                #Increase timeout if we have false positives
                state = if MapSet.disjoint?(state.alive, state.suspected) == false do
                    %{state | delay: state.delay + state.delta}
                else
                    state
                end

                state = check_and_probe(state, MapSet.to_list(state.servers))  # Update suspected, send heartbeats
                state = %{state | alive: %MapSet{}}                            # Reset alive
                Process.send_after(self(), {:timeout}, state.delay)            # Schedule next timeout
                state

            {:heartbeat_reply, name} ->
                %{state | alive: MapSet.put(state.alive, name)}

            _ -> state
        end

        run(state)
    end
    
    # Return the pid of a named process, or nil if it does not exist
    defp get_pid(name) do
        case :global.whereis_name(name) do
                pid when is_pid(pid) -> pid
                :undefined -> nil
        end
    end

    # Update suspected sets and send heartbeats
    defp check_and_probe(state, []), do: state
    defp check_and_probe(state, [p | p_tail]) do
        state = cond do
            # Process is not alive and needs to be suspected
            p not in state.alive and p not in state.suspected ->
                state = %{state | suspected: MapSet.put(state.suspected, p)}
                state

            # Process was suspected but is now alive again
            p in state.alive and p in state.suspected ->
                state = %{state | suspected: MapSet.delete(state.suspected, p)}
                state

            true ->
                state

        end
        
        # Send another heartbeat to this process
        case :global.whereis_name(p) do
            pid when is_pid(pid) -> send(pid, {:heartbeat_request, self()})
            :undefined -> :ok
        end

        # Continue until we run out of processes
        check_and_probe(state, p_tail)
    end

    # Select a server to use as leader
    # We will use Elixir's built in sort so that all clients will select the same leader given
    # the same set of alive servers
    defp maxrank(servers) do
        List.first(Enum.sort(servers))
    end

    # Get the app server that we consider a leader, or nil if no process is considered leader
    defp get_leader(backend) do
        send(backend, {:get_leader, self()})
        receive do
            {:leader, leader} -> leader
        after
            1000 -> nil
        end
    end
    
    # Submit a command to the server
    # `backend` is the symbolic name of the client backend process
    # Retry up to `retries` times if the server aborts or no leader could be selected
    # Return the command result if successful
    # Return :timeout if the server timed out
    # Return :fail if :abort was received `retries` times or a leader could not be selected after `retries` tries
    defp submit_server_command(_, _, 0), do: :fail
    defp submit_server_command(backend, cmd, retries) do
        leader = get_leader(backend)
        if leader == nil do
            Process.sleep(1000) # Give the backend some time to try and find a new leader
            submit_server_command(backend, cmd, retries - 1)
        else
            send(leader, {:submit_command, cmd})
            receive do
                {:abort} -> submit_server_command(backend, cmd, retries - 1)
                {:timeout} -> :timeout
                result -> result

            after
                6000 -> :timeout
            end
        end
    end

    ### PUBLIC API ###

    # Create a new item record
    def create_item(backend, item) do
        if item == nil, do: raise("item cannot be nil")

        case submit_server_command(backend, {:create_item, self(), item}, 5) do
            {:create_item_ok} -> :ok
            {:err_duplicate_item} -> :err_duplicate_item
            other -> other
        end
    end

    # Delete an item record
    def delete_item(backend, item) do
        if item == nil, do: raise("item cannot be nil")

        case submit_server_command(backend, {:delete_item, self(), item}, 5) do
            {:delete_item_ok} -> :ok
            {:err_no_such_item} -> :err_no_such_item
            other -> other
        end
    end

    # Add stock for an item and return the new stock level
    def add_stock(backend, item, quantity) do
        if item == nil, do: raise("item cannot be nil")
        if quantity < 1, do: raise("quantity must be at least 1")

        case submit_server_command(backend, {:add_stock, self(), item, quantity}, 5) do
            {:add_stock_ok, qty} -> qty
            {:err_no_such_item} -> :err_no_such_item
            other -> other
        end
    end

    # Remove stock for an item and return the new stock level
    def remove_stock(backend, item, quantity) do
        if item == nil, do: raise("item cannot be nil")
        if quantity < 1, do: raise("quantity must be at least 1")

        case submit_server_command(backend, {:remove_stock, self(), item, quantity}, 5) do
            {:remove_stock_ok, qty} -> qty
            {:err_no_such_item} -> :err_no_such_item
            {:err_insufficient_stock} -> :err_insufficient_stock
            other -> other
        end
    end

    # Return the current stock level for an item
    def query_stock(backend, item) do
        if item == nil, do: raise("item cannot be nil")

        case submit_server_command(backend, {:query_stock, self(), item}, 5) do
            {:query_stock_ok, qty} -> qty
            {:err_no_such_item} -> :err_no_such_item
            other -> other
        end
    end
end