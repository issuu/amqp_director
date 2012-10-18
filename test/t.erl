%%% @doc Manual test module for the AMQP client code
%%% This code is used to (manually) test the AMQP client code for correctness.
%%% You use this code by first running `t:t_start()` which starts up the test workers.
%%% Try doing this with and without a running RabbitMQ. When RabbitMQ is running, you can
%%% do `t:t()' to run a test run where 100 workers are spawned and call through the system.
%%% 
%%% Try killing different things from RabbitMQ/AMQP: A connection, a queue, all of the AMQP server,
%%% etc. This will verify that the system correctly restarts when an error occurs.
%%% @end
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
    QArgs = [{<<"x-message-ttl">>, long, 30000},
             {<<"x-dead-letter-exchange">>, longstr, <<"dead-letters">>}],
     {ok, SPid} = amqp_server_sup:start_link(
         server_connection_mgr, ConnInfo, <<"test_queue">>, QArgs, fun f/3, 5),
    ClientConfig =
       [{reply_queue, undefined},
       {routing_key, <<"test_queue">>},
       {queue_definitions, [#'queue.declare' { queue = <<"test_queue">>,
                                               arguments = QArgs }]}],
     {ok, CPid} = amqp_client_sup:start_link(client_connection,
                                             client_connection_mgr, ConnInfo, ClientConfig),
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
    {ok, <<"ok.">>, _} = amqp_rpc_client2:call(client_connection, <<"Hello.">>, <<"application/x-erlang-term">>),
    do_work_(N-1).

