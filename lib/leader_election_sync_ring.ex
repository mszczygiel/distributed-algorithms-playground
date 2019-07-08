defmodule LeaderElectionSyncRing do
  require Logger

  defmodule Node do
    use GenServer
    alias LeaderElectionSyncRing.Node

    defstruct [:self_id, :neighbour_pid, :arbiter_pid, :leader_announced]

    @impl true
    def init({self_id, arbiter}) do
      {:ok,
       %Node{self_id: self_id, neighbour_pid: nil, arbiter_pid: arbiter, leader_announced: false}}
    end

    @impl true
    def handle_cast({:neighbour_pid, pid}, %Node{neighbour_pid: nil} = state) do
      GenServer.cast(pid, {:msg, state.self_id})
      {:noreply, %Node{state | neighbour_pid: pid}}
    end

    def handle_cast({:msg, msg}, %Node{} = state)
        when is_number(msg) do
      new_state =
        cond do
          msg == state.self_id ->
            if not state.leader_announced do
              send(state.arbiter_pid, {:leader_announced, state.self_id})
              %Node{state | leader_announced: true}
            else
              state
            end

          msg > state.self_id ->
            GenServer.cast(state.neighbour_pid, {:msg, msg})
            state

          true ->
            state
        end

      {:noreply, new_state}
    end
  end

  def run_election(node_count) when is_number(node_count) and node_count > 1 do
    node_ids = 1..node_count
    arbiter = spawn_arbiter()

    nodes =
      Enum.map(node_ids, fn id ->
        {:ok, pid} = GenServer.start_link(Node, {id, arbiter})
        pid
      end)

    [h | t] = nodes
    shifted_nodes = t ++ [h]

    Enum.zip(nodes, shifted_nodes)
    |> Enum.each(fn {n1, n2} ->
      GenServer.cast(n1, {:neighbour_pid, n2})
    end)
  end

  defp spawn_arbiter() do
    spawn(&arbiter_loop/0)
  end

  defp arbiter_loop() do
    receive do
      {:leader_announced, leader_id} -> Logger.info("leader is #{leader_id}")
    end

    arbiter_loop()
  end
end
