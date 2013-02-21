-module(main_SUITE).

-export([all/0, groups/0, suite/0,
         init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2,
         init_per_testcase/2, end_per_testcase/2
        ]).

-export([blind_cast_test/1,
         connectivity_test/1,
         no_ack_test/1]).
         
-include_lib("common_test/include/ct.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

%% ----------------------------------------------------------------------


-spec suite() -> proplists:proplist().
suite() ->
    [{timetrap, {'seconds', 120}},
     {require, amqp_host}].

-spec groups() -> proplists:proplist().
groups() ->
    [{integration_test_group, [],
        [connectivity_test,
         no_ack_test,
         blind_cast_test]}].

-spec all() -> proplists:proplist().
all() ->
    [{group, integration_test_group}].

-spec init_per_group(atom(), proplists:proplist()) -> proplists:proplist().
init_per_group(_, Config) ->
    Config.

-spec end_per_group(atom(), proplists:proplist()) -> 'ok'.
end_per_group(_, _Config) ->
    ok.

-spec init_per_suite(proplists:proplist()) -> proplists:proplist().
init_per_suite(Config) ->
	ok = application:start(amqp_client),
	Config.

-spec end_per_suite(proplists:proplist()) -> 'ok'.
end_per_suite(_) ->
    ok.

-spec init_per_testcase(atom(), proplists:proplist()) -> proplists:proplist().
init_per_testcase(_Case, Config) ->
    Config.

-spec end_per_testcase(atom(), proplists:proplist()) -> 'ok'.
end_per_testcase(_Case, _Config) ->
   ok.

%% ----------------------------------------------------------------------
  
connectivity_test(_Config) ->
    AppId = amqp_director:mk_app_id(client_connection),
	QConf =
       [{reply_queue, <<"replyq-", AppId/binary>>},
        {consumer_tag, <<"my.consumer">>},
        {app_id, AppId},
        {routing_key, <<"test_queue_2">>},
        % {exchange, <<>>}, % This is the default
        {consume_queue, <<"test_queue_2">>},
        {queue_definitions, [#'queue.declare' { queue = <<"test_queue_2">>, arguments = [] }]}],
    amqp_connect(client_connection, fun f/3, QConf),
	do_connectivity_work(1000),
	ok.
	
do_connectivity_work(0) -> ok;
do_connectivity_work(N) ->
  case amqp_rpc_client2:call(client_connection, <<"Hello.">>, <<"application/x-erlang-term">>) of
        {ok, <<"ok.">>, _} -> ok
  end,
  do_connectivity_work(N-1).
  
no_ack_test(_Config) ->
    QArgs = [{<<"x-message-ttl">>, long, 30000},
             {<<"x-dead-letter-exchange">>, longstr, <<"dead-letters">>}],
    AppId = amqp_director:mk_app_id(client_connection),
    QConf =
       [{reply_queue, <<"replyq-", AppId/binary>>},
        no_ack,
        {consumer_tag, <<"my.consumer">>},
        {app_id, AppId},
        {routing_key, <<"test_queue">>},
        % {exchange, <<>>}, % This is the default
        {consume_queue, <<"test_queue">>},
        {queue_definitions, [#'queue.declare' { queue = <<"test_queue">>,
                                                arguments = QArgs }]}],

    amqp_connect(no_ack_test_client, fun f/3, QConf),
    do_no_ack_work(),
    ok.

do_no_ack_work() ->
    Parent = self(),
    Pids = [spawn_link(fun () -> do_work(Parent, 10) end) || _ <- lists:seq(1, 10000)],
    collect(Pids).

collect([]) ->
  done;
collect(Pids) ->
  receive
    {done, Pid} -> collect(Pids -- [Pid])
  end.

do_work(Parent, N) ->
    do_work_(N),
    Parent ! {done, self()}.

do_work_(0) -> ok;
do_work_(N) ->
    case amqp_rpc_client2:call(no_ack_test_client, <<"Hello.">>, <<"application/x-erlang-term">>) of
        {ok, <<"ok.">>, _} -> ok
    end,
    do_work_(N-1).

blind_cast_test(_Config) ->
    %% Spawn a RabbitMQ server system:
	{Host, Port, UN, PW} = ct:get_config(amqp_host),
	ConnInfo = #amqp_params_network { username = UN, password = PW,
                                      host = Host, port = Port },
    AppId = amqp_director:mk_app_id(client_connection_cast),
    QConf =
       [{reply_queue, none},
        {app_id, AppId},
        {routing_key, <<"test_queue">>},
        {exchange, <<"amq.topic">>},
        {queue_definitions, [#'queue.declare' { queue = <<"rk_test_queue">> },
                             #'queue.bind' { queue = <<"rk_test_queue">>, exchange = <<"amq.topic">>,
                                             routing_key = <<"rk.*">> } ]}],
    {ok, _CPid} = amqp_client_sup:start_link(client_connection_cast,
                                             client_connection_cast_mgr, ConnInfo, QConf),
    
    %% Set up a consumer hole
    TesterPid = self(),
    F = fun(Msg, CType, Type) ->
          TesterPid ! {msg, Msg, CType, Type},
          ack
        end,
    {ok, _SPid} = amqp_server_sup:start_link(
         server_connection_mgr, ConnInfo, [{consume_queue, <<"rk_test_queue">>}], F, 1),
    timer:sleep(timer:seconds(1)), %% Allow the system to connect
	amqp_rpc_client2:cast(client_connection_cast, <<"Fire!">>, <<"text/plain">>, <<"event">>),
	amqp_rpc_client2:cast(client_connection_cast, <<"1">>, <<"text/plain">>, <<"event">>, <<"rk.a">>),
	amqp_rpc_client2:cast(client_connection_cast, <<"2">>, <<"text/plain">>, <<"event">>, <<"rk.b">>),
	
	receive {msg, <<"1">>, _, _} -> ok after 1000 -> ct:fail("Incorrect Receive") end,
	receive {msg, <<"2">>, _, _} -> ok after 1000 -> ct:fail("Incorrect Receive") end,
	ok.
  
  
%% --------------------------------------------------------------------------
-spec f(Msg, ContentType, Type) -> {reply, binary(), binary()} | ack | reject | reject_no_requeue
  when
    Msg :: binary(),
    ContentType :: binary(),
    Type :: binary().
f(<<"Hello.">>, _ContentType, _Type) ->
    {reply, <<"ok.">>, <<"application/x-erlang-term">>}.

%% Standard connection to the RabbitMQ broker
amqp_connect(Name, Fun, QConf) ->
    %% Spawn a RabbitMQ server system:
	{Host, Port, UN, PW} = ct:get_config(amqp_host),
	ConnInfo = #amqp_params_network { username = UN, password = PW,
                                      host = Host, port = Port },
    {ok, _SPid} = amqp_server_sup:start_link(
         server_connection_mgr, ConnInfo, QConf, Fun, 5),
    {ok, _CPid} = amqp_client_sup:start_link(Name,
                                             client_connection_mgr, ConnInfo, QConf),
    
    timer:sleep(timer:seconds(1)). %% Allow the system to connect

