defmodule RabbitMQ.Producer.Worker do
  @moduledoc """
  The single Producer worker used to publish messages onto an exchange.
  """

  use AMQP
  use GenServer

  require Logger

  @opts ~w(
    confirm_type
    connection
    exchange
    handle_publisher_ack_confirms
    handle_publisher_nack_confirms
  )a

  @this_module __MODULE__

  defmodule State do
    @moduledoc """
    The internal state held in the `RabbitMQ.Producer.Worker` server.

    * `:channel` - holds the dedicated `AMQP.Channel`
    * `:exchange` - the exchange to publish to
    * `:handle_publisher_ack_confirms` - callback to invoke on Publisher `ack`
    * `:handle_publisher_nack_confirms` - callback to invoke on Publisher `nack`
    * `:outstanding_confirms` - tracks outstanding Publisher `ack` or `nack` confirms
    """

    @enforce_keys ~w(
      channel
      exchange
      handle_publisher_ack_confirms
      handle_publisher_nack_confirms
      outstanding_confirms
    )a
    defstruct @enforce_keys
  end

  ##############
  # Public API #
  ##############

  @doc """
  Starts this module as a process via `GenServer.start_link/2`.

  Should always be started via `Supervisor`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.take(opts, @opts)
    GenServer.start_link(@this_module, opts)
  end

  ######################
  # Callback Functions #
  ######################

  @impl true
  def init(opts) do
    # This is needed to invoke `terminate/2` when the parent process,
    # ideally a `Supervisor`, sends an exit signal.
    #
    # Read more @ https://hexdocs.pm/elixir/GenServer.html#c:terminate/2.
    Process.flag(:trap_exit, true)

    connection = Keyword.fetch!(opts, :connection)
    exchange = Keyword.fetch!(opts, :exchange)
    handle_publisher_ack_confirms = Keyword.fetch!(opts, :handle_publisher_ack_confirms)
    handle_publisher_nack_confirms = Keyword.fetch!(opts, :handle_publisher_nack_confirms)

    %Connection{} = connection = GenServer.call(connection, :get)

    with {:ok, channel} <- Channel.open(connection),
         :ok <- Confirm.select(channel),
         :ok <- Basic.return(channel, self()),
         :ok <- Confirm.register_handler(channel, self()) do
      # Monitor the channel process. Should channel exceptions occur,
      # such as when publishing to a non-existent exchange, we will
      # try to exit cleanly and let the supervisor restart the process.
      _ref = Process.monitor(channel.pid)

      {:ok,
       %State{
         channel: channel,
         exchange: exchange,
         handle_publisher_ack_confirms: handle_publisher_ack_confirms,
         handle_publisher_nack_confirms: handle_publisher_nack_confirms,
         outstanding_confirms: []
       }}
    end
  end

  @impl true
  def handle_call(
        {:publish, routing_key, data, opts},
        _from,
        %State{
          channel: %Channel{} = channel,
          exchange: exchange,
          outstanding_confirms: outstanding_confirms
        } = state
      ) do
    next_publish_seqno = Confirm.next_publish_seqno(channel)

    # Investigate what happens if confirms are not received within a given time limit.
    # Are they nacked after a specific timeout? Is any of this configurable?
    case Basic.publish(channel, exchange, routing_key, data, opts) do
      :ok ->
        # Always prepend, as it is pretty much constantly fast.
        # Read more about lists at https://hexdocs.pm/elixir/List.html.
        outstanding_confirms = [
          {next_publish_seqno, routing_key, data, opts} | outstanding_confirms
        ]

        {:reply, {:ok, next_publish_seqno}, %{state | outstanding_confirms: outstanding_confirms}}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(
        {confirmation_type, seq_number, multiple},
        %State{outstanding_confirms: outstanding_confirms} = state
      )
      when confirmation_type in [:basic_ack, :basic_nack] do
    outstanding_confirms
    |> update_outstanding_confirms(seq_number, multiple)
    |> handle_confirmations(confirmation_type, state)
  end

  @impl true
  def handle_info({:basic_return, _payload, _meta}, %State{} = state) do
    # See if publisher ack/nack is received in this instance
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _reference, :process, _pid, reason}, %State{} = state) do
    Logger.warn("Worker channel process down; #{inspect(reason)}.")
    # Stop GenServer; will be restarted by Supervisor.
    {:stop, {:channel_down, reason}, state}
  end

  @doc """
  Invoked when the server is about to exit. It should do any cleanup required.
  See https://hexdocs.pm/elixir/GenServer.html#c:terminate/2 for more details.
  """
  @impl true
  def terminate(reason, %State{channel: %Channel{} = channel} = state) do
    Logger.warn("Terminating Producer Worker: #{inspect(reason)}. Unregistering handler.")

    # Not sure this check is needed.
    if Process.alive?(channel.pid) do
      Confirm.unregister_handler(channel)
      Basic.cancel_return(channel)
      Channel.close(channel)
    end

    {:noreply, %{state | channel: nil, outstanding_confirms: []}}
  end

  #####################
  # Private Functions #
  #####################

  defp update_outstanding_confirms(outstanding_confirms, seq_number, true) do
    case outstanding_confirms do
      # The case where the confirm is the first (or the only) item in the list.
      [{^seq_number, _routing_key, _data, _opts} | _outstanding] = confirmed ->
        {confirmed, []}

      # The case where the confirm is somewhere in the list.
      list ->
        {outstanding, confirmed} =
          Enum.split_while(list, fn {seq_no, _routing_key, _data, _opts} ->
            seq_no > seq_number
          end)

        {confirmed, outstanding}
    end
  end

  defp update_outstanding_confirms(outstanding_confirms, seq_number, false) do
    case outstanding_confirms do
      # The case where the confirm is the only item in the list.
      [{^seq_number, _routing_key, _data, _opts} = confirmed] ->
        {[confirmed], []}

      # The case where the confirm is the first item in the list.
      [{^seq_number, _routing_key, _data, _opts} = confirmed | rest] ->
        {[confirmed], rest}

      # The case where the confirm is somewhere in the list.
      list ->
        confirmed =
          Enum.find(list, fn
            {^seq_number, _routing_key, _data, _opts} -> true
            _ -> false
          end)

        {[confirmed], List.delete(list, confirmed)}
    end
  end

  defp handle_confirmations(
         {confirmed, outstanding},
         :basic_ack,
         %State{
           handle_publisher_ack_confirms: handle_publisher_ack_confirms
         } = state
       ) do
    spawn(fn -> handle_publisher_ack_confirms.(confirmed) end)
    {:noreply, %{state | outstanding_confirms: outstanding}}
  end

  defp handle_confirmations(
         {confirmed, outstanding},
         :basic_nack,
         %State{
           handle_publisher_nack_confirms: handle_publisher_nack_confirms
         } = state
       ) do
    spawn(fn -> handle_publisher_nack_confirms.(confirmed) end)
    {:noreply, %{state | outstanding_confirms: outstanding}}
  end
end
