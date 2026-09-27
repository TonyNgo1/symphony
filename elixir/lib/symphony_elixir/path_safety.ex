defmodule SymphonyElixir.PathSafety do
  @moduledoc false

  @spec canonicalize(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonicalize(path) when is_binary(path) do
    expanded_path = Path.expand(path)
    {root, segments} = split_absolute_path(expanded_path)

    case resolve_segments(root, [], segments) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, reason} ->
        {:error, {:path_canonicalize_failed, expanded_path, reason}}
    end
  end

  defp split_absolute_path(path) when is_binary(path) do
    [root | segments] = Path.split(path)
    {root, segments}
  end

  defp resolve_segments(root, resolved_segments, []), do: {:ok, join_path(root, resolved_segments)}

  defp resolve_segments(root, resolved_segments, [segment | rest]) do
    candidate_path = join_path(root, resolved_segments ++ [segment])

    case segment_stat(candidate_path, segment) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- :file.read_link_all(String.to_charlist(candidate_path)) do
          resolved_target = Path.expand(IO.chardata_to_string(target), join_path(root, resolved_segments))
          {target_root, target_segments} = split_absolute_path(resolved_target)
          resolve_segments(target_root, [], target_segments ++ rest)
        end

      {:ok, _stat} ->
        resolve_segments(root, resolved_segments ++ [segment], rest)

      {:error, :enoent} ->
        {:ok, join_path(root, resolved_segments ++ [segment | rest])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp segment_stat(path, segment) do
    # Windows reports ENOENT for overlong components, which must not be treated
    # as an ordinary not-yet-created workspace path.
    if match?({:win32, _}, :os.type()) and byte_size(:unicode.characters_to_binary(segment, :utf8, {:utf16, :little})) > 510,
      do: {:error, :enametoolong},
      else: File.lstat(path)
  end

  defp join_path(root, segments) when is_list(segments) do
    Enum.reduce(segments, root, fn segment, acc -> Path.join(acc, segment) end)
  end
end
