defmodule SymphonyElixir.Codex.ModelSelection do
  @moduledoc "Resolves a worker's model once, independently of later issue/config changes."
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Acceptance

  @spec requested(map(), map()) :: map()
  def requested(issue, config \\ Config.settings!().codex) do
    {role, model, effort} =
      case Map.get(issue, :state) do
        "In review" -> review_selection(issue, config)
        "Integrating" -> {"integration", config.integration_model, config.integration_reasoning_effort}
        _ -> implementation_selection(issue)
      end

    %{role: role, model: value(model) || value(config.model), effort: value(effort) || value(config.reasoning_effort)}
  end

  @spec explicit?(map()) :: boolean()
  def explicit?(selection), do: not is_nil(selection.model) or not is_nil(selection.effort)

  @spec asset_generation?(map()) :: boolean()
  def asset_generation?(issue),
    do: "asset-generation" in (Map.get(issue, :labels) || []) or human_asset?(Map.get(issue, :description))

  @spec validate(map(), [map()]) :: {:ok, map()} | {:error, term()}
  def validate(selection, models) do
    model =
      if selection.model,
        do: Enum.find(models, &(&1["model"] == selection.model)),
        else: Enum.find(models, &(&1["isDefault"] == true))

    with %{} <- model,
         effort when is_binary(effort) <- selection.effort || model["defaultReasoningEffort"],
         true <- Enum.any?(model["supportedReasoningEfforts"] || [], &(&1["reasoningEffort"] == effort)) do
      {:ok, %{selection | model: model["model"], effort: effort}}
    else
      _ -> {:error, {:model_selection_invalid, "Unavailable model or unsupported reasoning effort: #{inspect(selection)}", selection}}
    end
  end

  @spec thread_params(map()) :: map()
  def thread_params(%{model: nil}), do: %{}
  def thread_params(selection), do: %{"model" => selection.model}

  @spec turn_params(map()) :: map()
  def turn_params(%{model: nil, effort: nil}), do: %{}
  def turn_params(selection), do: %{"model" => selection.model, "effort" => selection.effort}

  defp review_selection(issue, config) do
    if "type:feature" in (Map.get(issue, :labels) || []) do
      {"review", value(Map.get(config, :parent_review_model)) || config.review_model, value(Map.get(config, :parent_review_reasoning_effort)) || config.review_reasoning_effort}
    else
      {"review", config.review_model, config.review_reasoning_effort}
    end
  end

  # ArtCom's creative-production policy overrides Project fields and defaults.
  # A human_asset contract is a conservative fallback for issues missing the label.
  defp implementation_selection(issue) do
    if asset_generation?(issue) do
      {"implementation", "gpt-6-astra", "high"}
    else
      {"implementation", Map.get(issue, :model), Map.get(issue, :reasoning_effort)}
    end
  end

  defp human_asset?(description) do
    case Acceptance.parse(description) do
      {:ok, criteria} -> Enum.any?(criteria, &(&1["validation"]["kind"] == "human_asset"))
      {:error, _} -> false
    end
  end

  defp value(nil), do: nil
  defp value(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
end
