%%% @hidden
-module(amqp_definitions).

-include_lib("amqp_client/include/amqp_client.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([inject/2]).
-export([verify_config/1]).

%% Initialize a set of queues.
inject(_Channel, []) -> ok;
inject(Channel, [#'queue.declare' { queue = Q} = QDec | Defns]) ->
    #'queue.declare_ok' { queue = Q } = amqp_channel:call(Channel, QDec),
    inject(Channel, Defns);
inject(Channel, [#'queue.bind' {} = BindDec | Defns]) ->
    #'queue.bind_ok' {} = amqp_channel:call(Channel, BindDec),
    inject(Channel, Defns);
inject(Channel, [#'exchange.declare'{} = ExchDec | Defns]) ->
	#'exchange.declare_ok' {} = amqp_channel:call(Channel, ExchDec),
	inject(Channel, Defns).


%% @doc Exit in case of persistent messages on non durable queues
%% @end
verify_config(Config) ->
    case {proplists:get_value(pre_ack, Config), proplists:get_value(no_ack, Config)} of
        {true, true} ->
            {conflict, "Cannot set both pre_ack and no_ack to true!"};
        _ ->
            validate_persistent(Config)
    end.

validate_persistent(Config) ->
    case proplists:is_defined(reply_persistent, Config) orelse
        proplists:is_defined(persistent, Config) of
        false -> ok;
        true ->
            Filter = fun(#'queue.declare'{ durable = Durable }) ->
                            not Durable
                    end,
            case [ QDef || #'queue.declare'{} =
                            QDef <- proplists:get_value(queue_definitions, Config, []),
                        Filter(QDef) ] of
                [] -> ok;
                _ -> {conflict, "non durable persistent queue definition found", Config}
            end
    end.


%% Unit tests
-ifdef(TEST).
verify_config_test_() ->
    ServerConfig1 = [
        {exchange, <<"e">>},
        {consume_queue, <<"q">>},
        reply_persistent,
        {queue_definitions, [
                #'queue.declare' { queue = <<"q">>, durable = true },
                #'queue.bind' { exchange = <<"e">>, queue = <<"q">>, routing_key = <<"q">> }
            ]}
    ],
    ServerConfig2 = [
        {exchange, <<"e">>},
        {consume_queue, <<"q">>},
        reply_persistent,
        {queue_definitions, [
                #'queue.declare' { queue = <<"q">> },
                #'queue.bind' { exchange = <<"e">>, queue = <<"q">>, routing_key = <<"q">> }
            ]}
    ],
    ServerConfig3 = [
        {exchange, <<"e">>},
        {consume_queue, <<"q">>},
        {queue_definitions, [
                #'queue.declare' { queue = <<"q">> },
                #'queue.bind' { exchange = <<"e">>, queue = <<"q">>, routing_key = <<"q">> }
            ]}
    ],
    ClientConfig1 = [
        {exchange, <<"e">>},
        {routing_key, <<"rk">>},
        persistent,
        {queue_definitions, [
                #'queue.declare' { queue = <<"rk">>, durable = true },
                #'queue.bind' { exchange = <<"e">>, queue = <<"rk">>, routing_key = <<"rk">> }
            ]}
    ],
    ClientConfig2 = [
        {exchange, <<"e">>},
        {routing_key, <<"rk">>},
        persistent,
        {queue_definitions, [
                #'queue.declare' { queue = <<"rk">> },
                #'queue.bind' { exchange = <<"e">>, queue = <<"rk">>, routing_key = <<"rk">> }
            ]}
    ],
    ClientConfig3 = [
        {exchange, <<"e">>},
        {routing_key, <<"rk">>},
        {queue_definitions, [
                #'queue.declare' { queue = <<"rk">> },
                #'queue.bind' { exchange = <<"e">>, queue = <<"rk">>, routing_key = <<"rk">> }
            ]}
    ],
    [
        ?_assertEqual(ok, verify_config(ServerConfig1)),
        ?_assertEqual(conflict, element(1, verify_config(ServerConfig2))),
        ?_assertEqual(ok, verify_config(ServerConfig3)),
        ?_assertEqual(ok, verify_config(ClientConfig1)),
        ?_assertEqual(conflict, element(1, verify_config(ClientConfig2))),
        ?_assertEqual(ok, verify_config(ClientConfig3))
    ].
-endif.
