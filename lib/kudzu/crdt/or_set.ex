defmodule Kudzu.CRDT.ORSet do
  @moduledoc """
  Observed-Remove Set (OR-Set) CRDT implementation.

  An OR-Set allows concurrent add and remove operations with consistent
  convergence. Each add operation is tagged with a unique identifier,
  allowing removes to be precise about which add they're cancelling.

  This is essential for distributed memory systems where the same trace
  might be added/removed on different nodes concurrently.

  ## Semantics

  - Add-wins: If add and remove happen concurrently, add wins
  - Each add is uniquely tagged (can add same element multiple times)
  - Remove only affects adds that were observed (hence "observed-remove")

  ## Structure

  ```
  %{
    elements: %{
      element => MapSet.new([{unique_tag, node_id}, ...])
    },
    tombstones: %{
      element => MapSet.new([{unique_tag, node_id}, ...])
    }
  }
  ```
  """

  @type unique_tag :: String.t()
  @type node_id :: String.t()
  @type tagged_entry :: {unique_tag(), node_id()}

  @type t :: %__MODULE__{
          elements: %{any() => MapSet.t(tagged_entry())},
          tombstones: %{any() => MapSet.t(tagged_entry())},
          node_id: node_id()
        }

  defstruct elements: %{}, tombstones: %{}, node_id: nil

  @doc """
  Create a new empty OR-Set for a given node.
  """
  @spec new(node_id()) :: t()
  def new(node_id) when is_binary(node_id) do
    %__MODULE__{node_id: node_id}
  end

  @doc """
  Add an element to the set.
  """
  @spec add(t(), any()) :: t()
  def add(%__MODULE__{elements: elements, node_id: node_id} = set, element) do
    tag = generate_tag()
    entry = {tag, node_id}

    current_tags = Map.get(elements, element, MapSet.new())
    new_tags = MapSet.put(current_tags, entry)

    %{set | elements: Map.put(elements, element, new_tags)}
  end

  @doc """
  Remove an element from the set.
  Only removes tags that have been observed locally.
  """
  @spec remove(t(), any()) :: t()
  def remove(%__MODULE__{elements: elements, tombstones: tombstones} = set, element) do
    case Map.get(elements, element) do
      nil ->
        # Element not in set, nothing to remove
        set

      tags when map_size(tags) == 0 ->
        # No tags, nothing to remove
        set

      tags ->
        # Move all observed tags to tombstones
        current_tombstones = Map.get(tombstones, element, MapSet.new())
        new_tombstones = MapSet.union(current_tombstones, tags)

        %{set |
          elements: Map.put(elements, element, MapSet.new()),
          tombstones: Map.put(tombstones, element, new_tombstones)
        }
    end
  end

  @doc """
  Check if an element is in the set.
  """
  @spec member?(t(), any()) :: boolean()
  def member?(%__MODULE__{elements: elements, tombstones: tombstones}, element) do
    tags = Map.get(elements, element, MapSet.new())
    tombs = Map.get(tombstones, element, MapSet.new())

    # Element is present if it has tags that aren't tombstoned
    active_tags = MapSet.difference(tags, tombs)
    MapSet.size(active_tags) > 0
  end

  @doc """
  Get all elements currently in the set.
  """
  @spec to_list(t()) :: [any()]
  def to_list(%__MODULE__{} = set) do
    set.elements
    |> Enum.filter(fn {element, _tags} -> member?(set, element) end)
    |> Enum.map(fn {element, _tags} -> element end)
  end

  @doc """
  Get the count of elements in the set.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = set) do
    length(to_list(set))
  end

  @doc """
  Merge two OR-Sets.
  This is the key operation for CRDT convergence.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = set1, %__MODULE__{} = set2) do
    # Merge elements: union of all tags
    merged_elements = merge_tag_maps(set1.elements, set2.elements)

    # Merge tombstones: union of all tombstones
    merged_tombstones = merge_tag_maps(set1.tombstones, set2.tombstones)

    %__MODULE__{
      elements: merged_elements,
      tombstones: merged_tombstones,
      node_id: set1.node_id
    }
  end

  @doc """
  Check if two OR-Sets have the same observable state.
  """
  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{} = set1, %__MODULE__{} = set2) do
    list1 = to_list(set1) |> Enum.sort()
    list2 = to_list(set2) |> Enum.sort()
    list1 == list2
  end

  @doc """
  Get the delta (changes) between two states.
  Useful for efficient synchronization.
  """
  @spec delta(t(), t()) :: t()
  def delta(%__MODULE__{} = old_set, %__MODULE__{} = new_set) do
    # Delta contains only the new tags added since old_set
    delta_elements = diff_tag_maps(old_set.elements, new_set.elements)
    delta_tombstones = diff_tag_maps(old_set.tombstones, new_set.tombstones)

    %__MODULE__{
      elements: delta_elements,
      tombstones: delta_tombstones,
      node_id: new_set.node_id
    }
  end

  @doc """
  Apply a delta to a set.
  """
  @spec apply_delta(t(), t()) :: t()
  def apply_delta(%__MODULE__{} = set, %__MODULE__{} = delta) do
    merge(set, delta)
  end

  @doc """
  Serialize the OR-Set to a map for storage/transmission.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = set) do
    %{
      elements: serialize_tag_map(set.elements),
      tombstones: serialize_tag_map(set.tombstones),
      node_id: set.node_id
    }
  end

  @doc """
  Deserialize an OR-Set from a map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      elements: deserialize_tag_map(Map.get(map, :elements) || Map.get(map, "elements", %{})),
      tombstones: deserialize_tag_map(Map.get(map, :tombstones) || Map.get(map, "tombstones", %{})),
      node_id: Map.get(map, :node_id) || Map.get(map, "node_id")
    }
  end

  # Private helpers

  defp generate_tag do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp merge_tag_maps(map1, map2) do
    Map.merge(map1, map2, fn _key, tags1, tags2 ->
      MapSet.union(tags1, tags2)
    end)
  end

  defp diff_tag_maps(old_map, new_map) do
    new_map
    |> Enum.map(fn {key, new_tags} ->
      old_tags = Map.get(old_map, key, MapSet.new())
      diff_tags = MapSet.difference(new_tags, old_tags)
      {key, diff_tags}
    end)
    |> Enum.reject(fn {_key, tags} -> MapSet.size(tags) == 0 end)
    |> Map.new()
  end

  defp serialize_tag_map(tag_map) do
    tag_map
    |> Enum.map(fn {element, tags} ->
      serialized_element = serialize_element(element)
      serialized_tags = tags |> MapSet.to_list() |> Enum.map(&Tuple.to_list/1)
      {serialized_element, serialized_tags}
    end)
    |> Map.new()
  end

  defp deserialize_tag_map(serialized) when is_map(serialized) do
    serialized
    |> Enum.map(fn {element, tags} ->
      deserialized_tags = tags
      |> Enum.map(fn
        [tag, node_id] -> {tag, node_id}
        {tag, node_id} -> {tag, node_id}
      end)
      |> MapSet.new()
      {element, deserialized_tags}
    end)
    |> Map.new()
  end

  # Simple element serialization (extend as needed for complex elements)
  defp serialize_element(element) when is_binary(element), do: element
  defp serialize_element(element) when is_atom(element), do: Atom.to_string(element)
  defp serialize_element(element), do: inspect(element)
end
