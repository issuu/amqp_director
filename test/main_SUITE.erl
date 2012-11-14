-module(main_SUITE).

-export([all/0, groups/0, suite/0,
         init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2,
         init_per_testcase/2, end_per_testcase/2
        ]).

-export([connectivity_test/1,
         immediate_failure_test/1]).
         
-include_lib("common_test/include/ct.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

%% ----------------------------------------------------------------------


-spec suite() -> proplists:proplist().
suite() ->
    [{timetrap, {'seconds', 120}},
     {require, amqp_host}].

-spec groups() -> proplists:proplist().
groups() ->
    [{integration_test_group, [], [connectivity_test, immediate_failure_test]}].

-spec all() -> proplists:proplist().
all() ->
    [
     {group, integration_test_group}].

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
	%% Spawn a RabbitMQ server system:
	{Host, Port, UN, PW} = ct:get_config(amqp_host),
	ConnInfo = #amqp_params_network { username = UN, password = PW,
                                      host = Host, port = Port },
    QArgs = [{<<"x-message-ttl">>, long, 30000},
             {<<"x-dead-letter-exchange">>, longstr, <<"dead-letters">>}],
    AppId = amqp_director:mk_app_id(client_connection),
    QConf =
       [{reply_queue, <<"replyq-", AppId/binary>>},
        {consumer_tag, <<"my.consumer">>},
        {app_id, AppId},
        {routing_key, <<"test_queue">>},
        % {exchange, <<>>}, % This is the default
        {consume_queue, <<"test_queue">>},
        {queue_definitions, [#'queue.declare' { queue = <<"test_queue">>,
                                                arguments = QArgs }]}],
    {ok, _SPid} = amqp_server_sup:start_link(
         server_connection_mgr, ConnInfo, QConf, fun f/3, 5),
    {ok, _CPid} = amqp_client_sup:start_link(client_connection,
                                             client_connection_mgr, ConnInfo, QConf),
    
    timer:sleep(timer:seconds(1)), %% Allow the system to connect
	do_connectivity_work(1000),
	ok.
	
do_connectivity_work(0) -> ok;
do_connectivity_work(N) ->
  case amqp_rpc_client2:call(client_connection, <<"Hello.">>, <<"application/x-erlang-term">>) of
        {ok, <<"ok.">>, _} -> ok
  end,
  do_connectivity_work(N-1).
  
immediate_failure_test(_Config) ->
	%% Spawn a RabbitMQ server system:
	{Host, Port, UN, PW} = ct:get_config(amqp_host),
	ConnInfo = #amqp_params_network { username = UN, password = PW,
                                      host = Host, port = Port },
    QArgs = [{<<"x-message-ttl">>, long, 30000},
             {<<"x-dead-letter-exchange">>, longstr, <<"dead-letters">>}],
    QConf =
       [{reply_queue, undefined},
        {consumer_tag, <<"my.consumer">>},
        {routing_key, <<"test_queue">>},
        % {exchange, <<>>}, % This is the default
        {consume_queue, <<"test_queue">>},
        {queue_definitions, [#'queue.declare' { queue = <<"test_queue">>,
                                                arguments = QArgs }]}],
    {ok, CPid} = amqp_client_sup:start_link(client_connection_ifail,
                                             client_connection_ifail_mgr, ConnInfo, QConf),
    
    timer:sleep(timer:seconds(1)), %% Allow the system to connect
	do_connectivity_work_fail(1000),
	ok.
	
do_connectivity_work_fail(0) -> ok;
do_connectivity_work_fail(N) ->
  case amqp_rpc_client2:call(client_connection_ifail, <<"Hello.">>, <<"application/x-erlang-term">>) of
        {error, no_consumers} -> ok
  end,
  do_connectivity_work_fail(N-1).
  
  
%% --------------------------------------------------------------------------
-spec f(Msg, ContentType, Type) -> {reply, binary(), binary()} | ack | reject | reject_no_requeue
  when
    Msg :: binary(),
    ContentType :: binary(),
    Type :: binary().
f(<<"Hello.">>, _ContentType, _Type) ->
    {reply, <<"ok.">>, <<"application/x-erlang-term">>}.
