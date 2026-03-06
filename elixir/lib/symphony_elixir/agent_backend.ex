defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Provider-neutral agent backend selection and contract.
  """

  alias SymphonyElixir.Config

  @type session :: term()

  @callback provider_name() :: String.t()
  @callback start_session(Path.t()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @spec current_module() :: module()
  def current_module do
    case Config.agent_provider() do
      "claude" -> SymphonyElixir.AgentBackend.Claude
      _ -> SymphonyElixir.AgentBackend.Codex
    end
  end

  @spec provider_name() :: String.t()
  def provider_name do
    current_module().provider_name()
  end

  @spec start_session(Path.t()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace) do
    current_module().start_session(workspace)
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    current_module().run_turn(session, prompt, issue, opts)
  end

  @spec stop_session(session()) :: :ok
  def stop_session(session) do
    current_module().stop_session(session)
  end
end
