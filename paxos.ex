defmodule Paxos do
    # Spawn a new Paxos process and return its pid
    def start(name, participants) do
        pid = spawn(Paxos, :init, [name, participants])
        case :global.re_register_name(name, pid) do
            :yes -> pid  
            :no  -> :error
        end
        pid
    end

    # Initialise this Paxos process
    def init(name, participants) do 
        state = %{ 
            name: name,                                                         # Name of this process
            participants: participants,                                         # Names of all processes participating in Paxos
            p_count: length(participants),                                      # Number of processes participating in Paxos
            bal_offset: Enum.find_index(participants, fn x -> x == name end),   # Initial ballot for proposals from this process
            instances: %{}                                                      # Maps a Paxos instance identifier to its state
        }
        run(state)
    end

    # Paxos state machine
    def run(state) do
        # Receive event
        state = receive do
            {:propose, client, i, v} ->
                state = init_instance_state(state, i)
                instance = Map.get(state.instances, i)

                # If this instance has already decided, return the decision
                instance = if instance.decided == true do
                    send(client, {:decision, instance.decision})
                    instance
                else
                    # Setup for new proposal from this process
                    instance = %{instance | 
                        # Prepare phase
                        client: client,
                        proposal: v,
                        proposal_bal: instance.proposal_bal + state.p_count,    # All processes start from a different ballot so we get no collisions
                        prepared_responses: 0,
                        prepare_highest_bal: 0,
                        prepare_highest_val: nil,

                        # Accept phase
                        v: nil,
                        accepted_responses: 0,
                        accept_sent: false,
                    }

                    # Broadcast prepare
                    beb_broadcast({:prepare, self(), i, instance.proposal_bal}, state.participants)

                    instance
                end

                # Update instance state
                state = %{state | instances: Map.put(state.instances, i, instance)}
                state

            {:get_decision, client, i} ->
                state = init_instance_state(state, i)
                instance = Map.get(state.instances, i)
                
                # Return decision for this instance if decided
                if instance.decided == true do
                    send(client, {:decided, instance.decision})
                else
                    send(client, {:undecided})
                end

                state

            {:prepare, p, i, b} ->
                state = init_instance_state(state, i)
                instance = Map.get(state.instances, i)

                # Check if new ballot is higher than the highest we know about
                instance = if b > instance.bal do
                    # Update bal, send prepared, return new state
                    instance = %{instance | bal: b}
                    send(p, {:prepared, i, b, instance.a_bal, instance.a_val})
                    instance
                else
                    # Send nack
                    send(p, {:nack, i, b})
                    instance
                end

                # Update instance state
                state = %{state | instances: Map.put(state.instances, i, instance)}
                state

            {:prepared, i, b, a_bal, a_val} ->
                instance = Map.get(state.instances, i)

                # Check if we have already broadcasted accept
                instance = if instance.accept_sent == false do
                    # Update response count
                    instance = %{instance | prepared_responses: instance.prepared_responses + 1}

                    # Record the value of the highest ballot we learn about
                    instance = if a_bal > instance.prepare_highest_bal do
                        %{instance | prepare_highest_bal: a_bal, prepare_highest_val: a_val}
                    else
                        instance
                    end

                    # Check if we have majority responses yet
                    instance = if instance.prepared_responses > state.p_count / 2 do
                        # Select v
                        instance = if instance.prepare_highest_bal == 0 do
                            # Use our proposal if no other value was previously accepted 
                            %{instance | v: instance.proposal}
                        else
                            # Use the previously accepted value with the highest ballot
                            %{instance | v: instance.prepare_highest_val}
                        end

                        # Broadcast accept
                        beb_broadcast({:accept, self(), i, b, instance.v}, state.participants)
                        %{instance | accept_sent: true}
                    else
                        instance
                    end

                    instance
                
                else
                    instance
                end

                # Update instance state
                state = %{state | instances: Map.put(state.instances, i, instance)}
                state

            {:accept, p, i, b, v} ->
                # Check if this ballot is equal to or higher than the highest we know about
                instance = Map.get(state.instances, i)
                instance = if b >= instance.bal do
                    # Update bal, a_bal and a_val, send accepted, return new state
                    instance = %{instance | bal: b, a_bal: b, a_val: v}
                    send(p, {:accepted, i, b})
                    instance
                else
                    # Send nack
                    send(p, {:nack, i, b})
                    instance
                end

                # Update instance state
                state = %{state | instances: Map.put(state.instances, i, instance)}
                state

            {:accepted, i, _b} ->
                instance = Map.get(state.instances, i)

                # Check if we have already decided
                instance = if instance.decided == false do
                    # Update response count
                    instance = %{instance | accepted_responses: instance.accepted_responses + 1}

                    # Check if we have majority responses yet
                    instance = if instance.accepted_responses > state.p_count / 2 do
                        # Broadcast decision to all other processes
                        instance = %{instance | decided: true, decision: instance.v}
                        beb_broadcast({:decide, i, instance.decision}, state.participants)

                        # Return decision to client
                        send(instance.client, {:decision, instance.decision})
                        instance
                    else
                        instance
                    end

                    instance
                
                else
                    instance
                end

                # Update instance state
                state = %{state | instances: Map.put(state.instances, i, instance)}
                state

            {:nack, i, _b} ->
                instance = Map.get(state.instances, i)

                # Return abort
                send(instance.client, {:abort})
                state

            {:decide, i, v} ->
                instance = Map.get(state.instances, i)

                # Lock in final decision for this instance
                instance = if instance.decided == false do
                    %{instance | decided: true, decision: v}
                else
                    instance
                end
                
                state = %{state | instances: Map.put(state.instances, i, instance)}
                state
        end

        # Loop state machine
        run(state)
    end

    # Propose value for Paxos instance inst via process pid
    # Wait t ms for a response before timeout
    def propose(pid, inst, value, t) do
        # Send proposal to Paxos process
        send(pid, {:propose, self(), inst, value})

        # Return result
        receive do
            {:decision, v} ->
                {:decision, v}
            
            {:abort} ->
                {:abort}

        after
            t ->
                {:timeout}
        end
    end

    # Get the decision for Paxos instance inst via process pid
    # Wait t ms for a response before timeout
    def get_decision(pid, inst, t) do
        # Request decision value
        send(pid, {:get_decision, self(), inst})

        # Return result
        receive do
            {:decided, v} ->
                v
            
            {:undecided} ->
                nil

        after
            t ->
                nil
        end
    end

    # Initialise Paxos instance state
    defp init_instance_state(state, i) do
        if Map.has_key?(state.instances, i) == false do
            %{state | instances: Map.put(state.instances, i, %{
                # Prepare phase (leader)
                client: nil,                        # Client for propose/get_decision
                proposal: nil,                      # Value of propose call via this process
                proposal_bal: state.bal_offset,     # Next ballot number to use for this process
                prepared_responses: 0,              # Number of :prepared messages received after broadcasting :prepare
                prepare_highest_bal: 0,             # Highest ballot number received with a :prepared message
                prepare_highest_val: nil,           # Value associated with the highest :prepared ballot   

                # Accept phase (leader)
                v: nil,                             # Value to broadcast during accept phase
                accepted_responses: 0,              # Number of :accepted messages received after broadcasting :accept
                accept_sent: false,                 # true if :accept has been broadcasted for the current proposal
                
                # Used by all processes
                bal: 0,                             # Highest ballot number that this process has responded to
                a_bal: 0,                           # Highest ballot number that this process has accepted
                a_val: nil,                         # Value of the highest ballot accepted by this process
                decided: false,                     # true if a final value has been decided for this instance
                decision: nil,                      # Value of the decision for this instance
            })}
        else
            state
        end
    end

    # Unicast to another process by name
    defp unicast(m, p) do
        case :global.whereis_name(p) do
            pid when is_pid(pid) -> send(pid, m)
            :undefined -> :ok
        end
    end

    # Broadcast to all named processes in dest
    defp beb_broadcast(m, dest), do: for p <- dest, do: unicast(m, p)

end
