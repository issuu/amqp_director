-module(amqp_definitions).

-include_lib("amqp_client/include/amqp_client.hrl").

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
    case proplists:is_defined(reply_persistent, Config) of
        false -> ok;
        true -> 
            NonDurablePersistentQueues = lists:all(
                fun(#'queue.declare'{ durable = Durable }) -> Durable end,
                [ QDef || QDef <- proplists:get_value(queue_definitions, Config, []), is_record(QDef, 'queue.declare') ]
            ),
            case NonDurablePersistentQueues of
                [] -> ok;
                _ -> {conflict, "non durable persistent queue definition found", NonDurablePersistentQueues}
            end
    end.
