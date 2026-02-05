defmodule Kudzu.Beamlet.Base do
  @moduledoc """
  Base implementation for beam-lets.

  Provides common functionality:
  - Registration with capability registry
  - Load tracking and reporting
  - Health monitoring
  - Request queuing and rate limiting
  """

  defmacro __using__(opts) do
    capabilities = Keyword.get(opts, :capabilities, [])

    quote do
      use GenServer
      @behaviour Kudzu.Beamlet.Behaviour

      require Logger

      @capabilities unquote(capabilities)
      @max_queue_size 1000
      @health_check_interval 10_000

      # Default implementations

      @impl Kudzu.Beamlet.Behaviour
      def capabilities, do: @capabilities

      @impl Kudzu.Beamlet.Behaviour
      def current_load do
        GenServer.call(__MODULE__, :get_load)
      end

      @impl Kudzu.Beamlet.Behaviour
      def healthy? do
        GenServer.call(__MODULE__, :healthy?)
      catch
        :exit, _ -> false
      end

      defoverridable [capabilities: 0, current_load: 0, healthy?: 0]

      # Client API

      def start_link(opts \\ []) do
        name = Keyword.get(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, name: name)
      end

      def request(beamlet \\ __MODULE__, req, from_id) do
        GenServer.call(beamlet, {:request, req, from_id}, 30_000)
      end

      def request_async(beamlet \\ __MODULE__, req, from_id, reply_to) do
        GenServer.cast(beamlet, {:request_async, req, from_id, reply_to})
      end

      def get_id(beamlet \\ __MODULE__) do
        GenServer.call(beamlet, :get_id)
      end

      def info(beamlet \\ __MODULE__) do
        GenServer.call(beamlet, :info)
      end

      # Server implementation

      @impl GenServer
      def init(opts) do
        id = Keyword.get(opts, :id, generate_id())

        state = %{
          id: id,
          capabilities: @capabilities,
          request_count: 0,
          active_requests: 0,
          error_count: 0,
          last_error: nil,
          started_at: System.system_time(:millisecond),
          queue: :queue.new(),
          max_concurrent: Keyword.get(opts, :max_concurrent, 100)
        }

        # Register capabilities
        Enum.each(@capabilities, fn cap ->
          Registry.register(Kudzu.BeamletRegistry, {:capability, cap}, id)
        end)
        Registry.register(Kudzu.BeamletRegistry, {:id, id}, @capabilities)

        # Schedule health checks
        Process.send_after(self(), :health_check, @health_check_interval)

        :telemetry.execute(
          [:kudzu, :beamlet, :start],
          %{system_time: System.system_time()},
          %{id: id, capabilities: @capabilities}
        )

        {:ok, init_beamlet(state, opts)}
      end

      @impl GenServer
      def handle_call({:request, req, from_id}, _from, state) do
        state = %{state | request_count: state.request_count + 1, active_requests: state.active_requests + 1}

        {result, new_state} = try do
          case handle_request(req, from_id) do
            {:ok, result} ->
              {{:ok, result}, %{state | active_requests: state.active_requests - 1}}

            {:error, reason} = err ->
              {err, %{state |
                active_requests: state.active_requests - 1,
                error_count: state.error_count + 1,
                last_error: reason
              }}

            {:async, request_id} ->
              {{:async, request_id}, state}
          end
        rescue
          e ->
            Logger.error("Beamlet #{state.id} request failed: #{inspect(e)}")
            {{:error, {:exception, e}}, %{state |
              active_requests: state.active_requests - 1,
              error_count: state.error_count + 1,
              last_error: e
            }}
        end

        {:reply, result, new_state}
      end

      @impl GenServer
      def handle_call(:get_load, _from, state) do
        load = state.active_requests / max(state.max_concurrent, 1)
        {:reply, min(load, 1.0), state}
      end

      @impl GenServer
      def handle_call(:healthy?, _from, state) do
        # Consider unhealthy if error rate > 50% in recent requests
        recent_error_rate = if state.request_count > 10 do
          state.error_count / state.request_count
        else
          0.0
        end

        healthy = recent_error_rate < 0.5
        {:reply, healthy, state}
      end

      @impl GenServer
      def handle_call(:get_id, _from, state) do
        {:reply, state.id, state}
      end

      @impl GenServer
      def handle_call(:info, _from, state) do
        info = %{
          id: state.id,
          capabilities: state.capabilities,
          request_count: state.request_count,
          active_requests: state.active_requests,
          error_count: state.error_count,
          uptime_ms: System.system_time(:millisecond) - state.started_at,
          load: state.active_requests / max(state.max_concurrent, 1)
        }
        {:reply, info, state}
      end

      @impl GenServer
      def handle_cast({:request_async, req, from_id, reply_to}, state) do
        state = %{state | request_count: state.request_count + 1, active_requests: state.active_requests + 1}

        # Execute in separate process
        parent = self()
        Task.start(fn ->
          result = try do
            handle_request(req, from_id)
          rescue
            e -> {:error, {:exception, e}}
          end

          send(parent, {:async_complete})

          case reply_to do
            pid when is_pid(pid) -> send(pid, {:beamlet_response, state.id, result})
            {pid, ref} -> send(pid, {ref, result})
            _ -> :ok
          end
        end)

        {:noreply, state}
      end

      @impl GenServer
      def handle_info({:async_complete}, state) do
        {:noreply, %{state | active_requests: max(0, state.active_requests - 1)}}
      end

      @impl GenServer
      def handle_info(:health_check, state) do
        # Emit health telemetry
        :telemetry.execute(
          [:kudzu, :beamlet, :health],
          %{
            load: state.active_requests / max(state.max_concurrent, 1),
            error_rate: if(state.request_count > 0, do: state.error_count / state.request_count, else: 0.0)
          },
          %{id: state.id, capabilities: state.capabilities}
        )

        Process.send_after(self(), :health_check, @health_check_interval)
        {:noreply, state}
      end

      @impl GenServer
      def terminate(reason, state) do
        :telemetry.execute(
          [:kudzu, :beamlet, :stop],
          %{system_time: System.system_time()},
          %{id: state.id, reason: reason}
        )
        :ok
      end

      # Override these in implementations

      def init_beamlet(state, _opts), do: state

      defoverridable [init_beamlet: 2]

      defp generate_id do
        "beamlet-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
      end
    end
  end
end
