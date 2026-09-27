defmodule SymphonyElixir.WorkspaceFingerprint do
  @moduledoc "Read-only Git/worktree progress snapshots, including staged and untracked content."
  alias SymphonyElixir.PathSafety

  @spec capture(Path.t()) :: map()
  def capture(workspace) do
    head = git!(workspace, ["rev-parse", "HEAD"]) |> String.trim()
    diff = git!(workspace, ["diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--"])
    staged = git!(workspace, ["diff", "--cached", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--"])
    paths = git!(workspace, ["ls-files", "--others", "--exclude-standard", "-z"]) |> String.split(<<0>>, trim: true) |> Enum.sort()
    untracked = Enum.map(paths, &{&1, content_hash!(workspace, &1)})
    hash = :crypto.hash(:sha256, :erlang.term_to_binary({head, diff, staged, untracked})) |> Base.encode16(case: :lower)
    %{"head" => head, "fingerprint" => hash, "dirty" => diff != "" or staged != "" or paths != []}
  end

  defp git!(workspace, args) do
    case System.cmd("git", ["-c", "core.fsmonitor=false", "-C", workspace | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {_output, code} -> raise "Recovery Git snapshot failed (exit #{code})"
    end
  end

  defp content_hash!(workspace, relative) do
    path = Path.join(workspace, relative)
    # Never follow an untracked link outside the workspace to read its contents.
    case link_target(workspace, relative) do
      {:link, target} ->
        :crypto.hash(:sha256, target)

      _ ->
        {:ok, root} = PathSafety.canonicalize(workspace)
        {:ok, resolved} = PathSafety.canonicalize(path)
        unless String.starts_with?(resolved, root <> "/"), do: raise("Untracked file escapes workspace")
        path |> File.stream!(65_536) |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1)) |> :crypto.hash_final()
    end
  end

  defp link_target(workspace, relative) do
    Enum.reduce_while(Path.split(relative), workspace, fn segment, parent ->
      path = Path.join(parent, segment)
      if File.lstat!(path).type == :symlink, do: {:halt, {:link, File.read_link!(path)}}, else: {:cont, path}
    end)
  end
end
