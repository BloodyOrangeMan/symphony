defmodule SymphonyElixir.AgentBackend.Codex do
  @moduledoc """
  Provider adapter for the existing Codex app-server runtime.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.Codex.AppServer

  @impl true
  def provider_name, do: "codex"

  @impl true
  def start_session(workspace), do: AppServer.start_session(workspace)

  @impl true
  def run_turn(session, prompt, issue, opts \\ []) do
    AppServer.run_turn(session, prompt, issue, opts)
  end

  @impl true
  def stop_session(session), do: AppServer.stop_session(session)
end
