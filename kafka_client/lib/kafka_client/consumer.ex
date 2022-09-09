defmodule KafkaClient.Consumer do
  use Parent.GenServer
  require Logger
  alias KafkaClient.Consumer.Port

  def start_link(opts), do: Parent.GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    handler = Keyword.fetch!(opts, :handler)
    port = Port.open(opts)
    {:ok, %{handler: handler, port: port, end_offsets: nil}}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state),
    do: handle_port_message(:erlang.binary_to_term(data), state)

  def handle_info({:caught_up, partition}, state) do
    if state.end_offsets == nil do
      {:noreply, state}
    else
      state = update_in(state.end_offsets, &MapSet.delete(&1, partition))
      {:noreply, maybe_notify_caught_up(state)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("port exited with status #{status}")
    {:stop, :port_crash, %{state | port: nil}}
  end

  @impl GenServer
  def terminate(_reason, state),
    do: if(state.port != nil, do: Port.close(state.port))

  @impl Parent.GenServer
  def handle_stopped_children(children, state) do
    if Enum.any?(Map.keys(children), &match?({:processor, {_topic, _partition}}, &1)),
      do: {:stop, :processor_crashed, state},
      else: {:noreply, state}
  end

  defp handle_port_message({:assigned, partitions} = event, state) do
    Enum.each(partitions, &start_processor!(state, &1))
    state.handler.(event)
    {:noreply, state}
  end

  defp handle_port_message({:unassigned, partitions} = event, state) do
    Enum.each(partitions, &Parent.shutdown_child({:processor, &1}))
    state.handler.(event)
    {:noreply, state}
  end

  defp handle_port_message({:end_offsets, end_offsets}, state) do
    end_offsets =
      for {topic, partition, offset} <- end_offsets,
          start_processor!(state, {topic, partition}, offset),
          offset > 0,
          into: MapSet.new(),
          do: {topic, partition}

    {:noreply, maybe_notify_caught_up(%{state | end_offsets: end_offsets})}
  end

  defp handle_port_message(
         {:record, topic, partition, offset, timestamp, payload},
         state
       ) do
    now = System.monotonic_time()

    :telemetry.execute(
      [:kafka_client, :consumer, :record, :queue, :start],
      %{system_time: System.system_time(), monotonic_time: now},
      %{topic: topic, partition: partition, offset: offset, timestamp: timestamp}
    )

    {:ok, pid} = Parent.child_pid({:processor, {topic, partition}})
    KafkaClient.Consumer.Processor.handle_record(pid, offset, timestamp, payload, now)

    {:noreply, state}
  end

  defp handle_port_message({:metrics, transfer_time, duration}, state) do
    transfer_time = System.convert_time_unit(transfer_time, :nanosecond, :native)
    duration = System.convert_time_unit(duration, :nanosecond, :native)

    :telemetry.execute(
      [:kafka_client, :consumer, :port, :stop],
      %{
        system_time: System.system_time(),
        transfer_time: transfer_time,
        duration: duration
      },
      %{}
    )

    {:noreply, state}
  end

  defp handle_port_message({:committed, _offsets} = event, state) do
    state.handler.(event)
    {:noreply, state}
  end

  defp maybe_notify_caught_up(state) do
    if MapSet.size(state.end_offsets) == 0 do
      state.handler.(:caught_up)
      %{state | end_offsets: nil}
    else
      state
    end
  end

  defp start_processor!(state, {topic, partition}, end_offset \\ nil) do
    {:ok, pid} =
      Parent.start_child(
        {KafkaClient.Consumer.Processor,
         {self(), topic, partition, end_offset, state.handler, state.port}},
        id: {:processor, {topic, partition}},
        restart: :temporary,
        ephemeral?: true,
        shutdown: :brutal_kill
      )

    pid
  end
end
