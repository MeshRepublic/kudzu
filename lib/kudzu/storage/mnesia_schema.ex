defmodule Kudzu.Storage.MnesiaSchema do
  @moduledoc """
  Mnesia schema for distributed cold storage.

  Enables SETI-style distribution where traces are fragmented across
  mesh nodes. Each node stores a subset, queries span the entire mesh.

  ## Distribution Strategy

  Uses Mnesia's native fragmentation to spread traces across nodes:
  - Fragments based on trace_id hash
  - Each node holds ~1/N of total traces
  - Queries automatically span all fragments
  - Nodes can join/leave dynamically

  ## Replication

  Critical traces replicated to multiple nodes for durability.
  Non-critical traces stored on single node (can be reconstructed).

  ## Setup

  1. Start Mnesia on all nodes: Kudzu.Storage.MnesiaSchema.init_node()
  2. Create schema on first node: Kudzu.Storage.MnesiaSchema.create_schema([nodes])
  3. Join additional nodes: Kudzu.Storage.MnesiaSchema.join_mesh(existing_node)
  """

  require Logger

  @trace_table :kudzu_cold_traces
  @hologram_index :kudzu_cold_hologram_idx
  @purpose_index :kudzu_cold_purpose_idx

  # Trace record attributes
  @trace_attributes [
    :id,
    :hologram_id,
    :purpose,
    :reconstruction_hint,
    :origin,
    :path,
    :clock,
    :created_at,
    :last_accessed,
    :access_count,
    :importance
  ]

  @doc """
  Initialize Mnesia on this node (run on each node).
  """
  def init_node do
    # Set Mnesia directory (user-accessible)
    mnesia_dir = ~c"/home/eel/kudzu_data/mnesia/#{node()}"
    File.mkdir_p!(to_string(mnesia_dir))
    Application.put_env(:mnesia, :dir, mnesia_dir)

    # Start Mnesia
    case :mnesia.start() do
      :ok ->
        Logger.info("Mnesia started on #{node()}")
        :ok
      {:error, reason} ->
        Logger.error("Failed to start Mnesia: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Create the distributed schema (run once on first node).
  """
  def create_schema(nodes) when is_list(nodes) do
    # Stop Mnesia on all nodes first
    :rpc.multicall(nodes, :mnesia, :stop, [])

    # Create schema across all nodes
    case :mnesia.create_schema(nodes) do
      :ok ->
        Logger.info("Schema created across nodes: #{inspect(nodes)}")
      {:error, {_, {:already_exists, _}}} ->
        Logger.info("Schema already exists")
      {:error, reason} ->
        Logger.error("Schema creation failed: #{inspect(reason)}")
        {:error, reason}
    end

    # Start Mnesia on all nodes
    :rpc.multicall(nodes, :mnesia, :start, [])

    # Create the traces table with fragmentation
    create_tables(nodes)
  end

  @doc """
  Join an existing mesh (run on new nodes).
  """
  def join_mesh(existing_node) do
    # Start Mnesia locally
    init_node()

    # Connect to existing node
    case Node.connect(existing_node) do
      true ->
        Logger.info("Connected to #{existing_node}")
      false ->
        Logger.error("Failed to connect to #{existing_node}")
        {:error, :connection_failed}
    end

    # Add this node to the schema
    case :mnesia.change_config(:extra_db_nodes, [existing_node]) do
      {:ok, _} ->
        Logger.info("Added to Mnesia cluster")
      {:error, reason} ->
        Logger.error("Failed to join cluster: #{inspect(reason)}")
        {:error, reason}
    end

    # Copy tables to this node
    :mnesia.add_table_copy(@trace_table, node(), :disc_only_copies)

    # Add as fragment node
    add_fragment_node()
  end

  @doc """
  Store a trace in cold storage.
  """
  def store(trace_record) do
    :mnesia.transaction(fn ->
      :mnesia.write({@trace_table,
        trace_record.id,
        trace_record.hologram_id,
        trace_record.purpose,
        trace_record.reconstruction_hint,
        trace_record.origin,
        trace_record.path,
        trace_record.clock,
        trace_record.created_at,
        trace_record.last_accessed,
        trace_record.access_count,
        trace_record.importance
      })
    end)
  end

  @doc """
  Retrieve a trace by ID.
  """
  def retrieve(trace_id) do
    case :mnesia.transaction(fn ->
      :mnesia.read({@trace_table, trace_id})
    end) do
      {:atomic, [record]} -> {:ok, tuple_to_record(record)}
      {:atomic, []} -> :not_found
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Query traces by purpose across all fragments.
  """
  def query_by_purpose(purpose, limit \\ 100) do
    purpose_atom = if is_atom(purpose), do: purpose, else: String.to_atom(purpose)

    match_spec = [
      {
        {@trace_table, :_, :_, :"$1", :_, :_, :_, :_, :_, :_, :_, :_},
        [{:==, :"$1", purpose_atom}],
        [:"$_"]
      }
    ]

    case :mnesia.transaction(fn ->
      :mnesia.select(@trace_table, match_spec, limit, :read)
    end) do
      {:atomic, {records, _cont}} ->
        Enum.map(records, &tuple_to_record/1)
      {:atomic, :"$end_of_table"} ->
        []
      {:aborted, reason} ->
        Logger.error("Query failed: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Query traces by hologram ID.
  """
  def query_by_hologram(hologram_id, limit \\ 100) do
    match_spec = [
      {
        {@trace_table, :_, :"$1", :_, :_, :_, :_, :_, :_, :_, :_, :_},
        [{:==, :"$1", hologram_id}],
        [:"$_"]
      }
    ]

    case :mnesia.transaction(fn ->
      :mnesia.select(@trace_table, match_spec, limit, :read)
    end) do
      {:atomic, {records, _cont}} ->
        Enum.map(records, &tuple_to_record/1)
      {:atomic, :"$end_of_table"} ->
        []
      {:aborted, reason} ->
        Logger.error("Query failed: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Get statistics about cold storage.
  """
  def stats do
    %{
      size: :mnesia.table_info(@trace_table, :size),
      nodes: :mnesia.table_info(@trace_table, :active_replicas),
      fragments: get_fragment_count(),
      memory: :mnesia.table_info(@trace_table, :memory)
    }
  rescue
    _ -> %{size: 0, nodes: [], fragments: 0, memory: 0}
  end

  # Private functions

  defp create_tables(nodes) do
    # Calculate fragments based on node count
    n_fragments = max(length(nodes) * 2, 4)

    table_def = [
      attributes: @trace_attributes,
      disc_only_copies: nodes,
      frag_properties: [
        n_fragments: n_fragments,
        node_pool: nodes,
        n_disc_only_copies: 1
      ]
    ]

    case :mnesia.create_table(@trace_table, table_def) do
      {:atomic, :ok} ->
        Logger.info("Created cold storage table with #{n_fragments} fragments")
        :ok
      {:aborted, {:already_exists, @trace_table}} ->
        Logger.info("Cold storage table already exists")
        :ok
      {:aborted, reason} ->
        Logger.error("Failed to create table: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp add_fragment_node do
    # Add this node as a fragment host
    case :mnesia.change_table_frag(@trace_table, {:add_node, node()}) do
      {:atomic, :ok} ->
        Logger.info("Added #{node()} as fragment host")
        :ok
      {:aborted, reason} ->
        Logger.warning("Could not add as fragment host: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_fragment_count do
    case :mnesia.table_info(@trace_table, :frag_properties) do
      props when is_list(props) -> Keyword.get(props, :n_fragments, 1)
      _ -> 1
    end
  rescue
    _ -> 1
  end

  defp tuple_to_record({@trace_table, id, hologram_id, purpose, hint, origin, path, clock, created, accessed, count, importance}) do
    %Kudzu.Storage.TraceRecord{
      id: id,
      hologram_id: hologram_id,
      purpose: purpose,
      reconstruction_hint: hint,
      origin: origin,
      path: path,
      clock: clock,
      created_at: created,
      last_accessed: accessed,
      access_count: count,
      importance: importance
    }
  end
end
