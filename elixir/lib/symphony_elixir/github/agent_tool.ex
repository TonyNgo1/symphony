defmodule SymphonyElixir.GitHub.AgentTool do
  @moduledoc """
  Provider-native GitHub REST tool exposed to Codex app-server turns.
  """

  alias SymphonyElixir.GitHub.Client

  @github_api_tool "github_api"
  @set_project_status_tool "set_project_status"

  @allowed_methods ["GET"]

  @github_api_description """
  Read GitHub REST data using Symphony's configured auth. Use set_project_status
  for lifecycle changes and agent_workpad for the single persistent handoff.
  """

  @set_project_status_description """
  Change a GitHub issue's Project workflow status.
  Review approval and Done require evidence: validation {sha, command, result: passed}.
  Also supply acceptance [{id, sha, result: passed, details}] for EVERY criterion in the
  issue's symphony-acceptance JSON block. github_check criteria require check_run_id;
  Symphony verifies its name, app, successful conclusion and exact commit via GitHub.
  human_asset criteria require approval_comment_id from an authorized human's separate
  Asset Approval comment. The exact criterion, manifest and every declared file must
  match remote Git. If missing, pause at Human Review without evidence; ask the human
  to approve the package and return the card to In review. Never author that approval.
  Done requires fresh acceptance evidence at the integrated target SHA. Changed
  acceptance contracts require a new review. Missing contracts fail closed.
  Bug review also requires regression {test, command, before_sha, before: failed, after: passed}.
  Use full 40-character commit SHAs. Review: in the workpad is managed by Symphony.
  """

  @github_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "enum" => @allowed_methods,
        "description" => "GitHub REST method."
      },
      "path" => %{
        "type" => "string",
        "description" => "GitHub REST path such as /repos/owner/repo/issues/1/comments."
      },
      "params" => %{
        "type" => ["object", "null"],
        "description" => "Optional query parameters.",
        "additionalProperties" => true
      },
      "body" => %{
        "description" => "Optional JSON request body."
      }
    }
  }

  @set_project_status_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_identifier", "status"],
    "properties" => %{
      "issue_identifier" => %{
        "type" => "string",
        "description" => "Symphony issue identifier such as GH-123."
      },
      "status" => %{
        "type" => "string",
        "description" => "Exact GitHub Project status name."
      },
      "evidence" => %{
        "type" => "object",
        "description" => "Commit-bound validation and optional bug regression evidence. Required for approval and Done.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) do
    case tool do
      @github_api_tool -> execute_github_api(arguments, opts)
      @set_project_status_tool -> execute_set_project_status(arguments, opts)
      "agent_workpad" -> execute_workpad(arguments, opts)
      other -> unsupported_tool_response(other)
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @github_api_tool,
        "description" => @github_api_description,
        "inputSchema" => @github_api_input_schema
      },
      %{
        "name" => @set_project_status_tool,
        "description" => @set_project_status_description,
        "inputSchema" => @set_project_status_input_schema
      },
      %{
        "name" => "agent_workpad",
        "description" => "Read or replace this issue's single Agent Workpad comment. Omit body to read; at most 40 lines.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{"body" => %{"type" => "string"}}
        }
      }
    ]
  end

  defp execute_github_api(arguments, opts) do
    github_client = Keyword.get(opts, :github_client, &Client.request/5)
    client_opts = Keyword.take(opts, [:tracker_settings, :request_fun])

    with {:ok, method, path, params, body} <- normalize_arguments(arguments),
         {:ok, %{status: status, body: response_body}} <-
           github_client.(method, path, params, body, client_opts),
         true <- is_integer(status) do
      rest_response(status, response_body)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
      _ -> failure_response(tool_error_payload(:github_unknown_payload))
    end
  end

  defp execute_set_project_status(arguments, opts) do
    client_opts = Keyword.take(opts, [:tracker_settings, :request_fun, :issue])
    client_opts = if is_map(arguments) and Map.has_key?(arguments, "evidence"), do: Keyword.put(client_opts, :evidence, arguments["evidence"]), else: client_opts

    with {:ok, issue_identifier, status} <- normalize_project_status_arguments(arguments),
         {:ok, result} <- Client.update_project_status(issue_identifier, status, client_opts) do
      dynamic_tool_response(true, encode_payload(result))
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_workpad(arguments, opts) when is_map(arguments) do
    with %{identifier: identifier} <- Keyword.get(opts, :issue),
         {:ok, result} <- Client.workpad(identifier, Map.get(arguments, "body"), opts) do
      dynamic_tool_response(true, encode_payload(result))
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
      _ -> failure_response(tool_error_payload(:github_issue_context_required))
    end
  end

  defp execute_workpad(_arguments, _opts), do: failure_response(tool_error_payload(:invalid_arguments))

  defp normalize_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_method(Map.get(arguments, "method")),
         {:ok, path} <- normalize_path(Map.get(arguments, "path")),
         {:ok, params} <- normalize_params(Map.get(arguments, "params")) do
      {:ok, method, path, params, Map.get(arguments, "body")}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_project_status_arguments(arguments) when is_map(arguments) do
    issue_identifier = Map.get(arguments, "issue_identifier")
    status = Map.get(arguments, "status")

    if present_string?(issue_identifier) and present_string?(status) do
      {:ok, String.trim(issue_identifier), String.trim(status)}
    else
      {:error, :invalid_project_status_arguments}
    end
  end

  defp normalize_project_status_arguments(_arguments),
    do: {:error, :invalid_project_status_arguments}

  defp normalize_method(method) when is_binary(method) do
    normalized = method |> String.trim() |> String.upcase()
    if normalized in @allowed_methods, do: {:ok, normalized}, else: {:error, :invalid_method}
  end

  defp normalize_method(_method), do: {:error, :invalid_method}

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    if String.starts_with?(trimmed, "/") and not String.contains?(trimmed, ["://", "\n", "\r", <<0>>]) do
      {:ok, trimmed}
    else
      {:error, :invalid_path}
    end
  end

  defp normalize_path(_path), do: {:error, :invalid_path}

  defp normalize_params(nil), do: {:ok, %{}}
  defp normalize_params(params) when is_map(params), do: {:ok, params}
  defp normalize_params(_params), do: {:error, :invalid_params}

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp rest_response(status, body) do
    dynamic_tool_response(status in 200..299, encode_payload(%{"status" => status, "body" => body}))
  end

  defp failure_response(payload), do: dynamic_tool_response(false, encode_payload(payload))

  defp dynamic_tool_response(success, output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp encode_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, output} -> output
      {:error, _reason} -> inspect(payload)
    end
  end

  defp unsupported_tool_response(tool) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => supported_tool_names()
      }
    })
  end

  defp tool_error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "`github_api` expects an object with `method` and `path`."}}
  end

  defp tool_error_payload(:invalid_method) do
    %{"error" => %{"message" => "`github_api.method` must be GET. Use the scoped lifecycle and workpad tools for writes."}}
  end

  defp tool_error_payload(:invalid_path) do
    %{"error" => %{"message" => "`github_api.path` must be a relative GitHub REST path."}}
  end

  defp tool_error_payload(:invalid_params) do
    %{"error" => %{"message" => "`github_api.params` must be a JSON object when provided."}}
  end

  defp tool_error_payload(:invalid_project_status_arguments) do
    %{
      "error" => %{
        "message" => "`set_project_status` expects non-empty `issue_identifier` and `status`."
      }
    }
  end

  defp tool_error_payload(:missing_github_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing GitHub auth. Set `tracker.provider.token` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
      }
    }
  end

  defp tool_error_payload({:github_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitHub API request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{"error" => %{"message" => "GitHub API tool execution failed.", "reason" => inspect(reason)}}
  end

  defp supported_tool_names, do: Enum.map(tool_specs(), & &1["name"])
end
