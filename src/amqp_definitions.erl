-module(amqp_definitions).

-export([inject/2]).

%% Initialize a set of queues.
inject(_Channel, []) -> ok;
inject(Channel, [#'queue.declare' { queue = Q} = QDec | Defns]) ->
    #'queue.declare_ok' { queue = Q } = amqp_channel:call(Channel, QDec),
    inject(Channel, Defns);
inject(Channel, [#'queue.bind' {} = BindDec | Defns]) ->
    #'queue.bind_ok' {} = amqp_channel:call(Channel, BindDec),
    inject(Channel, Defns).