defmodule AmqpDirector.Queues do
    @moduledoc false
    require Record
    import Record

    defrecord :exchange_declare,    :'exchange.declare',    Record.extract(:'exchange.declare',    from_lib: "rabbit_common/include/rabbit_framing.hrl")
    defrecord :queue_declare,       :'queue.declare',       Record.extract(:'queue.declare',       from_lib: "rabbit_common/include/rabbit_framing.hrl")
    defrecord :queue_bind,          :'queue.bind',          Record.extract(:'queue.bind',          from_lib: "rabbit_common/include/rabbit_framing.hrl")
    defrecord :'exchange.declare',    Record.extract(:'exchange.declare',    from_lib: "rabbit_common/include/rabbit_framing.hrl")
    defrecord :'queue.declare',       Record.extract(:'queue.declare',       from_lib: "rabbit_common/include/rabbit_framing.hrl")
    defrecord :'queue.bind',          Record.extract(:'queue.bind',          from_lib: "rabbit_common/include/rabbit_framing.hrl")

    @type exchange_declare :: record(:'exchange.declare',
        ticket: number,
        exchange: String.t,
        type: String.t,
        passive: boolean,
        durable: boolean,
        auto_delete: boolean,
        internal: boolean,
        nowait: boolean,
        arguments: term)

    @type queue_declare :: record(:'queue.declare',
        ticket: number,
        queue: String.t,
        passive: boolean,
        durable: boolean,
        exclusive: boolean,
        auto_delete: boolean,
        nowait: boolean,
        arguments: list(term))

    @type queue_bind :: record(:'queue.bind',
        ticket: term,
        queue: String.t,
        exchange: String.t,
        routing_key: String.t,
        nowait: term,
        arguments: term)

end
