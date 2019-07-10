defmodule TwoPhaseCommit do
  @moduledoc """
  As per Nancy A. Lynch, "Distributed Algorithms":
  TwoPhaseCommit solves the commit problem with the weak termination condition
  """
  defmodule Decider do
    use GenServer
    require Logger

    defstruct [:participant_decisions, :decision]

    @impl true
    def init({participant_pids, decision}) do
      :timer.send_after(3000, :broadcast_decision)

      participant_pids
      |> Enum.each(fn participant -> GenServer.cast(participant, {:decide, self()}) end)

      {:ok,
       %Decider{participant_decisions: Map.new(participant_pids, &{&1, nil}), decision: decision}}
    end

    @impl true
    def handle_cast(
          {:decision, participant_pid, decision},
          %Decider{participant_decisions: participant_decisions} = state
        ) do
      if not Map.has_key?(participant_decisions, participant_pid) do
        throw(:not_a_participant)
      end

      case participant_decisions do
        %{^participant_pid => nil} ->
          new_state = put_in(state.participant_decisions[participant_pid], decision)
          current = self()

          if all_decided?(new_state),
            do: spawn(fn -> send(current, :broadcast_decision) end)

          {:noreply, new_state}

        _ ->
          {:stop, :participant_decided_twice, state}
      end
    end

    @impl true
    def handle_info(:broadcast_decision, state) do
      commit? =
        state.decision === :commit &&
          Map.values(state.participant_decisions)
          |> Enum.all?(fn x -> x === :commit end)

      decision =
        case commit? do
          true -> :commit
          false -> :abort
        end

      Logger.info("Decider's decision is #{decision}")

      Map.keys(state.participant_decisions)
      |> Enum.each(fn pid -> GenServer.cast(pid, {:final_decision, decision}) end)

      {:stop, :normal, state}
    end

    defp all_decided?(%Decider{participant_decisions: decisions}) do
      Map.values(decisions)
      |> Enum.all?(fn
        nil -> false
        _ -> true
      end)
    end
  end

  defmodule Participant do
    use GenServer
    require Logger

    @impl true
    def init({participant_id, decision}) do
      {:ok, {participant_id, decision}}
    end

    @impl true
    def handle_cast({:decide, decider}, {_participant_id, decision} = state) do
      case decision do
        :abort -> GenServer.cast(decider, {:decision, self(), :abort})
        :commit -> GenServer.cast(decider, {:decision, self(), :commit})
        :noreply -> nil
      end

      {:noreply, state}
    end

    @impl true
    def handle_cast({:final_decision, decision}, {participant_id, _decider} = state) do
      Logger.info("#{participant_id} => #{decision}")
      {:stop, :normal, state}
    end
  end

  def decide(decider_decision, participants_decisions)
      when is_list(participants_decisions) and is_atom(decider_decision) do
    participants =
      node_ids()
      |> Enum.zip(participants_decisions)
      |> Enum.map(fn {id, decision} ->
        {:ok, pid} = GenServer.start_link(TwoPhaseCommit.Participant, {id, decision})
        pid
      end)

    {:ok, _decider} =
      GenServer.start_link(TwoPhaseCommit.Decider, {participants, decider_decision})
  end

  defp node_ids() do
    Stream.iterate(1, &(&1 + 1))
  end
end
