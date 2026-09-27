defmodule SymphonyElixir.GitHub.AssetReview do
  @moduledoc "Human approval of an immutable asset review package, checked against remote Git blobs."

  @approval ~r/\A## Asset Approval\r?\n```symphony-asset-approval\r?\n(.*?)\r?\n```\s*\z/s

  @spec policy?(term()) :: boolean()
  def policy?(%{"kind" => "human_asset", "manifest" => path, "reviewers" => reviewers, "instructions" => instructions} = policy) do
    map_size(policy) == 4 and path?(path) and is_binary(instructions) and String.trim(instructions) != "" and
      is_list(reviewers) and reviewers != [] and Enum.all?(reviewers, &login?/1) and
      length(reviewers) == length(Enum.uniq_by(reviewers, &String.downcase/1))
  end

  def policy?(_), do: false

  @spec verify(map(), map(), String.t(), function(), keyword()) :: :ok | {:error, term()}
  def verify(policy, entry, sha, get, opts) do
    with id when is_integer(id) and id > 0 <- entry["approval_comment_id"],
         issue when is_binary(issue) <- Keyword.get(opts, :issue_id),
         {:ok, comment} <- get.("/issues/comments/#{id}"),
         {:ok, approval} <- approval(comment, policy, Keyword.fetch!(opts, :criterion), issue),
         {:ok, %{"tree" => tree, "truncated" => false}} when is_list(tree) <- get.("/git/trees/#{sha}?recursive=1"),
         blob when is_binary(blob) <- regular_blob(tree, policy["manifest"]),
         true <- blob == approval["manifest_blob"],
         {:ok, %{"encoding" => "base64", "content" => encoded}} when is_binary(encoded) <- get.("/git/blobs/#{blob}"),
         {:ok, bytes} <- Base.decode64(encoded, ignore: :whitespace),
         true <- blob_hash(bytes) == blob,
         {:ok, manifest} <- Jason.decode(bytes),
         :ok <- manifest_matches(manifest, tree, policy["manifest"]) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :github_asset_approval_required_or_stale}
    end
  end

  defp approval(%{"user" => %{"type" => "User", "login" => login}, "issue_url" => url, "body" => body}, policy, criterion, issue)
       when is_binary(login) and is_binary(url) and is_binary(body) do
    with true <- String.downcase(login) in Enum.map(policy["reviewers"], &String.downcase/1),
         true <- String.ends_with?(url, "/issues/#{issue}"),
         [[_, json]] <- Regex.scan(@approval, body),
         {:ok, %{"version" => 1, "decision" => "approved", "criterion" => ^criterion, "manifest" => path, "manifest_blob" => blob} = value} <- Jason.decode(json),
         true <- map_size(value) == 5 and path == policy["manifest"] and sha?(blob) do
      {:ok, value}
    else
      _ -> {:error, :github_asset_approval_required_or_stale}
    end
  end

  defp approval(_, _, _, _), do: {:error, :github_asset_approval_required_or_stale}

  defp manifest_matches(%{"version" => 1, "asset_id" => asset, "files" => files}, tree, path)
       when is_binary(asset) and asset != "" and is_list(files) and files != [] do
    if valid_files?(files, tree, path), do: :ok, else: {:error, :github_asset_manifest_mismatch}
  end

  defp manifest_matches(_, _, _), do: {:error, :github_asset_manifest_mismatch}

  defp valid_files?(files, tree, manifest_path) do
    paths = Enum.map(files, fn file -> if is_map(file), do: file["path"] end)

    length(paths) == length(Enum.uniq(paths)) and manifest_path not in paths and
      Enum.all?(files, &file_matches?(&1, tree)) and
      sidecars_bound?(paths, tree) and
      MapSet.subset?(MapSet.new(["asset", "preview", "review_page"]), MapSet.new(files, & &1["role"]))
  end

  defp sidecars_bound?(paths, tree),
    do: Enum.all?(paths, fn path -> not Enum.any?(tree, &(&1["path"] == path <> ".import")) or (path <> ".import") in paths end)

  defp file_matches?(%{"path" => path, "blob" => blob, "role" => role}, tree) do
    path?(path) and sha?(blob) and role in ["asset", "source", "import", "preview", "review_page"] and
      regular_blob(tree, path) == blob
  end

  defp file_matches?(_, _), do: false

  defp regular_blob(tree, path) do
    case Enum.filter(tree, &(&1["path"] == path)) do
      [%{"type" => "blob", "mode" => mode, "sha" => sha}] when mode in ["100644", "100755"] -> sha
      _ -> nil
    end
  end

  defp blob_hash(bytes), do: :crypto.hash(:sha, "blob #{byte_size(bytes)}\0" <> bytes) |> Base.encode16(case: :lower)
  defp sha?(value), do: is_binary(value) and Regex.match?(~r/^[0-9a-f]{40}$/, value)
  defp login?(value), do: is_binary(value) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/, value)

  defp path?(value) when is_binary(value) do
    Regex.match?(~r/^[A-Za-z0-9_.\/-]+$/, value) and
      Enum.all?(String.split(value, "/"), &(&1 not in ["", ".", "..", ".git", ".godot"]))
  end

  defp path?(_), do: false
end
