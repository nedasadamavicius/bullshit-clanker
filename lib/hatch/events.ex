defmodule Hatch.Events do
  @spec topic(String.t()) :: String.t()
  def topic(session_id) do
    "session:" <> session_id
  end

  @spec broadcast(String.t(), map()) :: :ok
  def broadcast(session_id, event) do
    event_with_session = Map.put(event, :session_id, session_id)
    Phoenix.PubSub.broadcast(Hatch.PubSub, topic(session_id), {:hatch_event, event_with_session})
  end

  @spec subscribe(String.t()) :: :ok
  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(Hatch.PubSub, topic(session_id))
  end
end
