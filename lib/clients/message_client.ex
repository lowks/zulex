import Logger

defmodule Reader.MessageClient do
    use ExActor.Tolerant, export: :MessageClient


    definit do
        Logger.debug "Starting #{inspect __MODULE__}"
        {:ok, _} = GenEvent.start_link(name: :EventManager)
        :ok = GenEvent.add_handler(:EventManager, MessageHandler, "")
        request_new_messages
        initial_state nil
    end


    defcast request_new_messages, export: false do
        %StateManager.State{
            queue_id: queue_id,
            event_id: event_id,
            credentials: %ZulipAPICredentials{key: key, email: email}
        } = StateManager.get_state


        HTTPotion.start
        ibrowse = Dict.merge [basic_auth: {email, key}], Application.get_env(:zulex, :ibrowse, [])

        %HTTPotion.AsyncResponse{id: async_id} = MessageProcessor.get(
            URI.encode_query(%{
                "queue_id"      => queue_id,
                "last_event_id" => event_id
            }),
            [], # empty headers
            [
                stream_to: self,
                ibrowse:   ibrowse,
                timeout:   600_000
            ]
        )
        new_state async_id
    end


    definfo %HTTPotion.AsyncHeaders{id: id, status_code: status_code}, 
    state: async_id, export: false, when: id == async_id do

        unless status_code in 200..299 or status_code in [302, 304] do
            msg = "#{__MODULE__}: Request failed with HTTP status code #{status_code}."
            Logger.error(msg)
            raise RuntimeError, message: msg
        end
        noreply
    end


    definfo %HTTPotion.AsyncChunk{id: id, chunk: json}, 
    state: async_id, export: false, when: is_map(json) and id == async_id do

        if (json[:result] == "error"), do:
            Logger.warn json[:msg]

        events = Dict.get(json, :events)

        messages = Enum.filter_map(events, fn e -> e[:message] != nil end, fn e -> e[:message] end)
        unless Enum.empty?(messages), do:
            GenEvent.notify(:EventManager, messages)

        max_event_id = List.foldl(
            events,
            -1,
            fn e, acc -> max(e[:id], acc) end
        )
        StateManager.set_event_id(max_event_id)
        noreply
    end


    definfo %HTTPotion.AsyncEnd{id: id},
    state: async_id, export: false, when: id == async_id do
        __MODULE__.request_new_messages
        noreply
    end
end
