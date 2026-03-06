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

  @spec current_module(String.t() | nil) :: module()
  def current_module(provider \\ nil) do
    case provider || Config.agent_provider() do
      "claude" -> SymphonyElixir.AgentBackend.Claude
      _ -> SymphonyElixir.AgentBackend.Codex
    end
  end

  @spec provider_name(String.t() | nil) :: String.t()
  def provider_name(provider \\ nil) do
    current_module(provider).provider_name()
  end

  @spec start_session(Path.t(), String.t() | nil) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, provider \\ nil) do
    current_module(provider).start_session(workspace)
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    provider = Keyword.get(opts, :provider)
    current_module(provider).run_turn(session, prompt, issue, opts)
  end

  @spec stop_session(session()) :: :ok
  def stop_session(session, provider \\ nil) do
    current_module(provider).stop_session(session)
  end
end
