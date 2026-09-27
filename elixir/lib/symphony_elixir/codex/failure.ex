defmodule SymphonyElixir.Codex.Failure do
  @moduledoc "Structured Codex usage-limit classification; never infer quota from assistant prose."

  @spec usage_limit?(term()) :: boolean()
  def usage_limit?(value) when value in [:usage_limit_exceeded, "usage_limit_exceeded", "usageLimitExceeded"], do: true

  def usage_limit?(value) when is_map(value) do
    Enum.any?(["code", "type", "error", "codexErrorInfo", "error_code", "params", "turn", "msg", "data"], fn key ->
      usage_limit?(Map.get(value, key))
    end)
  end

  def usage_limit?(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.any?(&usage_limit?/1)
  def usage_limit?(_value), do: false
end
