defmodule StockManagementServer do
    ### INITIALISATION ###
    # Start the stock management server
    def start(name, paxos_proc) do
        pid = spawn(StockManagementServer, :init, [name, paxos_proc])
        pid = case :global.re_register_name(name, pid) do
            :yes -> pid  
            :no  -> nil
        end
        IO.puts(if pid, do: "registered #{name}", else: "failed to register #{name}")
        pid
    end

    # Initialise the stock management server
    def init(name, paxos_proc) do
        state = %{
            name: name,
            pax_pid: get_paxos_pid(paxos_proc),
            last_instance: 0,
            pending: [],
            items: %{}
        }

        # If the Paxos process we are communicating via dies, kill this replica too
        Process.link(state.pax_pid)
        run(state)
    end

    # Get pid of a Paxos instance to connect to
    defp get_paxos_pid(paxos_proc) do
        case :global.whereis_name(paxos_proc) do
                pid when is_pid(pid) -> pid
                :undefined -> raise(Atom.to_string(paxos_proc))
        end
    end

    # Submit a command to Paxos, return new state
    defp propose_command(state, cmd) do
        result = Paxos.propose(state.pax_pid, state.last_instance + 1, cmd, 5000)
        case result do
            # Our command was decided
            {:decision, ^cmd} ->
                state = execute_command_with_response(state, cmd)               # Execute command and respond to client
                # Move on to next instance and remove command from pending
                state = %{state | last_instance: state.last_instance + 1, pending: List.delete(state.pending, cmd)}
                state

            # There was a different decision for this instance
            {:decision, v} ->
                state = execute_command(state, v)                               # Execute command
                state = %{state | last_instance: state.last_instance + 1}       # Move on to next instance
                state = propose_command(state, cmd)                             # Try our command again
                state

            # Our proposal was interrupted
            {:abort} ->
                send(elem(cmd, 1), {:abort})                                    # Return :abort to client
                state = %{state | pending: List.delete(state.pending, cmd)}     # Remove the command from pending
                state


            # Timeout 
            {:timeout} ->
                send(elem(cmd, 1), {:timeout})                                  # Return :timeout to client
                state = %{state | pending: List.delete(state.pending, cmd)}     # Remove the command from pending
                state
        end
    end

    # Poll Paxos layer for new decisions
    defp poll_for_decisions(state) do
        result = Paxos.get_decision(state.pax_pid, state.last_instance + 1, 5000)
        case result do
            nil ->
                state

            v ->
                state = execute_command(state, v)                           # Execute new command
                state = %{state | last_instance: state.last_instance + 1}   # Update last instance
                state = poll_for_decisions(state)                           # Check for further decisions
                state
        end
    end

    # Execute a command on this replica, respond to client, return new state
    defp execute_command_with_response(state, cmd) do
        case cmd do
            {:create_item, client, item} ->
                if internal_item_exists?(state, item) == false do
                    state = internal_create_item(state, item)
                    send(client, {:create_item_ok})
                    state
                else
                    send(client, {:err_duplicate_item})
                    state
                end

            {:delete_item, client, item} ->
                if internal_item_exists?(state, item) == true do
                    state = internal_delete_item(state, item)
                    send(client, {:delete_item_ok})
                    state
                else
                    send(client, {:err_no_such_item})
                    state
                end

            {:add_stock, client, item, qty} ->
                if internal_item_exists?(state, item) == true do
                    state = internal_set_stock(state, item, internal_get_stock(state, item) + qty)
                    send(client, {:add_stock_ok, internal_get_stock(state, item)})
                    state
                else
                    send(client, {:err_no_such_item})
                    state
                end

            {:remove_stock, client, item, qty} ->
                if internal_item_exists?(state, item) == true do
                    if internal_get_stock(state, item) >= qty do
                        state = internal_set_stock(state, item, internal_get_stock(state, item) - qty)
                        send(client, {:remove_stock_ok, internal_get_stock(state, item)})
                        state
                    else
                        send(client, {:err_insufficient_stock})
                        state
                    end
                else
                    send(client, {:err_no_such_item})
                    state
                end

            {:query_stock, client, item} ->
                if internal_item_exists?(state, item) == true do
                    send(client, {:query_stock_ok, internal_get_stock(state, item)})
                    state
                else
                    send(client, {:err_no_such_item})
                    state
                end
            
            _ -> state
        end
    end

    # Execute a command on this replica without responding to client, return new state
    defp execute_command(state, cmd) do
        case cmd do
            {:create_item, _client, item} ->
                if internal_item_exists?(state, item) == false do
                    internal_create_item(state, item)
                else
                    state
                end

            {:delete_item, _client, item} ->
                if internal_item_exists?(state, item) == true do
                    internal_delete_item(state, item)
                else
                    state
                end

            {:add_stock, _client, item, qty} ->
                if internal_item_exists?(state, item) == true do
                    internal_set_stock(state, item, internal_get_stock(state, item) + qty)
                else
                    state
                end

            {:remove_stock, _client, item, qty} ->
                if internal_item_exists?(state, item) == true do
                    if internal_get_stock(state, item) >= qty do
                        internal_set_stock(state, item, internal_get_stock(state, item) - qty)
                    else
                        state
                    end
                else
                    state
                end
            
            _ -> state
        end
    end

    def run(state) do
        state = receive do
            {:process_commands} ->
                # Keep processing until pending is empty
                if Enum.empty?(state.pending) do
                    state
                else
                    cmd = List.last(state.pending)          # Get next command
                    state = poll_for_decisions(state)       # Make sure we have the most up to date state
                    state = propose_command(state, cmd)     # Propose our command (cmd is removed from pending by the time this returns)
                    send(self(), {:process_commands})       # Process further commands
                    state
                end

            {:submit_command, cmd} ->
                state = %{state | pending: [cmd | state.pending]}
                send(self(), {:process_commands})
                state

            {:heartbeat_request, client} ->
                send(client, {:heartbeat_reply, state.name})
                state

            _ -> state
            
        end

        # Loop
        run(state)
    end

    # Initialise new item, returning state
    defp internal_create_item(state, item) do
        %{state | items: Map.put(state.items, item, 0)}
    end

    # Delete an item, returning state
    defp internal_delete_item(state, item) do
        %{state | items: Map.delete(state.items, item)}
    end

    # Get item stock level
    defp internal_get_stock(state, item) do
        Map.get(state.items, item)
    end

    # Set item stock level, returning state
    defp internal_set_stock(state, item, quantity) do
        %{state | items: Map.put(state.items, item, quantity)}
    end

    # Return true if a record exists for the item, otherwise false
    defp internal_item_exists?(state, item) do
        Map.has_key?(state.items, item)
    end

end