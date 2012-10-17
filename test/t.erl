-module(t).

-include_lib("amqp_client/include/amqp_client.hrl").

-export([t_start/0, t/0]).

-spec f(Msg, ContentType, Type) -> {reply, binary(), binary()} | ack | reject | reject_no_requeue
  when
    Msg :: binary(),
    ContentType :: binary(),
    Type :: binary().
f(<<"Hello.">>, _ContentType, _Type) ->
  {reply, <<"ok.">>, <<"application/x-erlang-term">>}.

t_start() ->
	application:start(amqp_client),
	%% Spawn a RabbitMQ server system:
	ConnInfo = #amqp_params_network { username = <<"guest">>, password = <<"guest">>,
	                                  host = "localhost", port = 5672 },
	{ok, SPid} = amqp_server_sup:start_link(
	    server_connection_mgr, ConnInfo, <<"test_queue">>,
	                                     [{<<"x-message-ttl">>, long, 30000},
	                                      {<<"x-dead-letter-exchange">>, longstr, <<"dead-letters">>}], fun f/1, 5),
	{ok, CPid} = amqp_client_sup:start_link(
	    client_connection, client_connection_mgr, 
	    ConnInfo, <<"test_queue">>),
	{ok, SPid, CPid}.

t() ->
    Parent = self(),
	Pids = [spawn_link(fun () -> do_work(Parent, 1000) end) || _ <- lists:seq(1, 100)],
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
	amqp_rpc_client2:call(client_connection, <<"Hello.">>, <<"application/x-erlang-term">>),
	do_work_(N-1).

