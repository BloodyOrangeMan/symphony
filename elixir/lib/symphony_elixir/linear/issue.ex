defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  @supported_agent_providers ["codex", "claude"]
  @agent_label_prefix "agent:"

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @spec selected_agent_provider(t(), String.t() | nil) :: String.t() | nil
  def selected_agent_provider(issue, default_provider \\ nil)

  def selected_agent_provider(%__MODULE__{labels: labels}, default_provider)
      when is_list(labels) do
    labels
    |> Enum.find_value(&agent_provider_from_label/1)
    |> case do
      nil -> default_provider
      provider -> provider
    end
  end

  def selected_agent_provider(_issue, default_provider), do: default_provider

  defp agent_provider_from_label(label) when is_binary(label) do
    normalized =
      label
      |> String.trim()
      |> String.downcase()

    case normalized do
      @agent_label_prefix <> provider when provider in @supported_agent_providers ->
        provider

      provider when provider in @supported_agent_providers ->
        provider

      _ ->
        nil
    end
  end

  defp agent_provider_from_label(_label), do: nil
end
