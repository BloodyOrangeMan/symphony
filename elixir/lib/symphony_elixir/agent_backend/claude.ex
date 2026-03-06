defmodule SymphonyElixir.AgentBackend.Claude do
  @moduledoc """
  Thin Claude Code CLI backend for Symphony turns.
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger

  alias SymphonyElixir.Config

  @port_line_bytes 1_048_576
  @session_dir ".symphony"
  @session_file "claude_session_id"
  @max_summary_bytes 500

  @type session :: %{
          workspace: Path.t(),
          executable: String.t(),
          persisted_session_id: String.t() | nil,
          settings: map()
        }

  @impl true
  def provider_name, do: "claude"

  @impl true
  def start_session(workspace) do
    with :ok <- validate_workspace_cwd(workspace),
         {:ok, settings} <- Config.claude_runtime_settings(),
         {:ok, executable} <- find_executable(settings.command) do
      expanded_workspace = Path.expand(workspace)

      {:ok,
       %{
         workspace: expanded_workspace,
         executable: executable,
         persisted_session_id: read_persisted_session_id(expanded_workspace),
         settings: settings
       }}
    end
  end

  @impl true
  def run_turn(%{} = session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _message -> :ok end)

    with {:ok, port} <- start_port(session, prompt) do
      try do
        with {:ok, result} <- receive_stream(port, on_message, issue, session, "", %{session_id: nil}) do
          maybe_persist_session_id(session.workspace, result[:session_id])

          {:ok,
           %{
             result: result[:result],
             session_id: result[:session_id]
           }}
        end
      after
        stop_port(port)
      end
    end
  end

  @impl true
  def stop_session(_session), do: :ok

  defp start_port(%{workspace: workspace, executable: executable, settings: settings, persisted_session_id: persisted_session_id}, prompt) do
    args =
      build_args(prompt, settings, persisted_session_id)
      |> Enum.map(&String.to_charlist/1)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args,
          cd: String.to_charlist(workspace),
          line: @port_line_bytes
        ]
      )

    {:ok, port}
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, {:claude_start_failed, Exception.message(error)}}
  end

  defp build_args(prompt, settings, persisted_session_id) do
    base_args = [
      "-p",
      prompt,
      "--output-format",
      "stream-json",
      "--verbose",
      "--permission-mode",
      settings.permission_mode
    ]

    base_args
    |> maybe_add_resume_arg(persisted_session_id)
    |> maybe_add_tool_args("--allowedTools", settings.allowed_tools)
    |> maybe_add_tool_args("--disallowedTools", settings.disallowed_tools)
  end

  defp maybe_add_resume_arg(args, session_id) when is_binary(session_id) and session_id != "" do
    args ++ ["--resume", session_id]
  end

  defp maybe_add_resume_arg(args, _session_id), do: args

  defp maybe_add_tool_args(args, _flag, nil), do: args

  defp maybe_add_tool_args(args, flag, tools) when is_list(tools) and tools != [] do
    args ++ [flag, Enum.join(tools, ",")]
  end

  defp maybe_add_tool_args(args, _flag, _tools), do: args

  defp receive_stream(port, on_message, issue, session, pending_line, acc) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_line(
          port,
          on_message,
          issue,
          session,
          pending_line <> to_string(chunk),
          acc
        )

      {^port, {:data, {:noeol, chunk}}} ->
        receive_stream(port, on_message, issue, session, pending_line <> to_string(chunk), acc)

      {^port, {:exit_status, 0}} ->
        finalize_result(acc)

      {^port, {:exit_status, status}} ->
        {:error, {:claude_exit_status, status}}
    after
      Config.claude_turn_timeout_ms() ->
        {:error, :turn_timeout}
    end
  end

  defp handle_line(port, on_message, issue, session, line, acc) do
    case Jason.decode(line) do
      {:ok, %{"type" => "system", "subtype" => "init"} = payload} ->
        session_id = payload["session_id"] || acc.session_id || session.persisted_session_id

        emit_message(on_message, :session_started, %{
          provider: provider_name(),
          session_id: session_id,
          payload: summarize_init(payload)
        })

        receive_stream(port, on_message, issue, session, "", %{acc | session_id: session_id})

      {:ok, %{"type" => "assistant"} = payload} ->
        emit_message(on_message, :notification, %{
          provider: provider_name(),
          session_id: acc.session_id,
          payload: summarize_assistant(payload)
        })

        receive_stream(port, on_message, issue, session, "", acc)

      {:ok, %{"type" => "result", "subtype" => "success"} = payload} ->
        session_id = payload["session_id"] || acc.session_id || session.persisted_session_id
        usage = normalize_usage(payload)

        emit_message(on_message, :turn_completed, %{
          provider: provider_name(),
          session_id: session_id,
          usage: usage,
          payload: summarize_result(payload, usage)
        })

        receive_stream(
          port,
          on_message,
          issue,
          session,
          "",
          %{acc | session_id: session_id, result: payload["result"], usage: usage}
        )

      {:ok, %{"type" => "result"} = payload} ->
        session_id = payload["session_id"] || acc.session_id || session.persisted_session_id
        reason = payload["result"] || payload["subtype"] || "unknown_result"

        emit_message(on_message, :turn_ended_with_error, %{
          provider: provider_name(),
          session_id: session_id,
          reason: reason,
          payload: summarize_result(payload, normalize_usage(payload))
        })

        {:error, {:claude_result_error, payload}}

      {:ok, payload} ->
        emit_message(on_message, :notification, %{
          provider: provider_name(),
          session_id: acc.session_id,
          payload: summarize_generic(payload)
        })

        receive_stream(port, on_message, issue, session, "", acc)

      {:error, _reason} ->
        Logger.debug("Claude stream non-JSON for #{issue_context(issue)}: #{truncate(line)}")

        emit_message(on_message, :malformed, %{
          provider: provider_name(),
          session_id: acc.session_id,
          raw: truncate(line)
        })

        receive_stream(port, on_message, issue, session, "", acc)
    end
  end

  defp finalize_result(%{session_id: session_id, result: result} = acc)
       when is_binary(session_id) and is_binary(result) do
    {:ok, acc}
  end

  defp finalize_result(%{result: result} = acc) when is_binary(result), do: {:ok, acc}
  defp finalize_result(_acc), do: {:error, :claude_result_missing}

  defp emit_message(on_message, event, payload) when is_function(on_message, 1) do
    on_message.(Map.put(payload, :event, event) |> Map.put(:timestamp, DateTime.utc_now()))
  end

  defp normalize_usage(payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || %{}
    input = integer_value(usage["input_tokens"]) || 0
    output = integer_value(usage["output_tokens"]) || 0
    cache_read = integer_value(usage["cache_read_input_tokens"]) || 0
    cache_create = integer_value(usage["cache_creation_input_tokens"]) || 0

    %{
      input_tokens: input + cache_read + cache_create,
      output_tokens: output,
      total_tokens: input + cache_read + cache_create + output
    }
  end

  defp normalize_usage(_payload), do: %{}

  defp summarize_init(payload) do
    %{
      method: "claude/init",
      session_id: payload["session_id"],
      model: payload["model"],
      permission_mode: payload["permissionMode"]
    }
  end

  defp summarize_assistant(payload) do
    %{
      method: "claude/assistant",
      content: summarize_assistant_content(payload)
    }
  end

  defp summarize_result(payload, usage) do
    %{
      method: "claude/result",
      result: truncate(payload["result"]),
      stop_reason: payload["stop_reason"],
      usage: usage
    }
  end

  defp summarize_generic(payload) when is_map(payload) do
    %{
      method: Map.get(payload, "type") || "claude/event",
      payload: truncate(Jason.encode!(payload))
    }
  end

  defp summarize_assistant_content(%{"message" => %{"content" => content}}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> truncate(text)
      %{"type" => "thinking"} -> "[thinking]"
      %{"type" => type} -> "[#{type}]"
      other -> truncate(inspect(other))
    end)
    |> Enum.join(" ")
    |> String.trim()
  end

  defp summarize_assistant_content(_payload), do: ""

  defp maybe_persist_session_id(_workspace, nil), do: :ok

  defp maybe_persist_session_id(workspace, session_id) when is_binary(session_id) do
    state_dir = Path.join(workspace, @session_dir)
    File.mkdir_p!(state_dir)
    File.write!(Path.join(state_dir, @session_file), session_id <> "\n")
    :ok
  end

  defp read_persisted_session_id(workspace) when is_binary(workspace) do
    session_path = Path.join([workspace, @session_dir, @session_file])

    case File.read(session_path) do
      {:ok, session_id} ->
        case String.trim(session_id) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp find_executable(command) when is_binary(command) do
    case String.split(String.trim(command), ~r/\s+/, parts: 2) do
      [single] ->
        if path = System.find_executable(single) do
          {:ok, path}
        else
          {:error, :claude_not_found}
        end

      _ ->
        {:error, {:unsupported_claude_command, command}}
    end
  end

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    workspace_path = Path.expand(workspace)
    workspace_root = Path.expand(Config.workspace_root())
    root_prefix = workspace_root <> "/"

    cond do
      workspace_path == workspace_root ->
        {:error, {:invalid_workspace_cwd, :workspace_root, workspace_path}}

      not String.starts_with?(workspace_path <> "/", root_prefix) ->
        {:error, {:invalid_workspace_cwd, :outside_workspace_root, workspace_path, workspace_root}}

      true ->
        :ok
    end
  end

  defp stop_port(port) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp stop_port(_port), do: :ok

  defp truncate(text) when is_binary(text) and byte_size(text) > @max_summary_bytes do
    binary_part(text, 0, @max_summary_bytes) <> "... (truncated)"
  end

  defp truncate(text) when is_binary(text), do: text
  defp truncate(text), do: truncate(inspect(text))

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
