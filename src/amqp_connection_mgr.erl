%%% @doc Keep track of an AMQP connection.
%%%
%%% This gen_server keeps track of an AMQP connection. It exposes the connection, but it
%%% also tracks whether or not the connection is still alive. If the connection dies, the
%%% process will crash. This will tell the supervisor tree of this process to close down
%%% and restart.
%%%
%%% If the connection can not be established, the process will enter a repeated wait-state
%%% where it tries to reconnect every 30 seconds. As soon as it gets the connection it
%%% will begin operating normally and manage the connection.
%%%
%%% Essentially this module is a supervisor tree link. It watches over RabbitMQs connections
%%% and injects a fault into its own supervisor tree whenever the RabbitMQ connection dies.
%%% @end
%%% @hidden
-module(amqp_connection_mgr).
-behaviour(gen_server).
-compile([{parse_transform, lager_transform}]).


-include_lib("amqp_client/include/amqp_client.hrl").

%% API
-export([start_link/2, fetch/1]).

%% Callbacks
-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2, code_change/3]).

-record(state, { conn, info }).

-define(MAX_RECONNECT, timer:seconds(30)).
%%--------------------------------------------------------------------------

%% @doc Start up the connection manager.
%% You give the connection manager two parameters: `RegName' is the name under which the
%% connection manager should register itself. `ConnInfo' is the connection info the process
%% should use.
%% @end
-spec start_link(RegName, ConnInfo) -> {ok, pid()}
  when RegName :: atom(),
       ConnInfo :: #amqp_params_network{}.
start_link(RegName, ConnInfo) ->
    gen_server:start_link({local, RegName}, ?MODULE, [ConnInfo],
                          %% We give the server 30 seconds to connect to AMQP. If this fails,
                          %% We fail the connection.
                          [{timeout, timer:seconds(30)}]).

%% @doc Fetch the current connection from the manager.
%% Obtain the connection from the manager, if it has one.
%% @end
-spec fetch(RegName) -> {ok, pid()} | {error, Reason}
  when RegName :: atom(),
       Reason :: term().
fetch(RegName) ->
    gen_server:call(RegName, fetch).

%%--------------------------------------------------------------------------

%% @private
init([ConnInfo]) ->
    process_flag(trap_exit, true),
    {ok, try_connect(#state { info = ConnInfo }, 1000)}.


%% @private
terminate(_Reason, #state { conn = Conn }) when is_pid(Conn) ->
    catch amqp_connection:close(Conn),
    ok;
terminate(_Reason, _State) ->
    ok.

%% @private
handle_call(fetch, _From, #state { conn = {error, _} = Err } = State) ->
    {reply, Err, State};
handle_call(fetch, _From, #state { conn = Conn } = State) ->
    {reply, {ok, Conn}, State};
handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.


%% @private
handle_info({'DOWN', _, process, _ConnPid, Reason}, #state { info = Info } = State) ->
    lager:notice("Connection ~p going down: ~p", [Info, Reason]),
    {stop, Reason, State};
handle_info({reconnect, ReconnectTime}, #state { conn = {error, _}} = State) ->
   {noreply, try_connect(State, ReconnectTime)};
handle_info(_Info, State) ->
   {noreply, State}.

%% @private
code_change(_OldVsn, State, _Extra) ->
    State.

%%--------------------------------------------------------------------------

try_connect(#state { info = ConnInfo } = State, ReconnectTime) ->
    case amqp_connection:start(ConnInfo) of
      {ok, Connection} ->
        erlang:monitor(process, Connection),
        State#state { conn = Connection };
      {error, econnrefused} ->
        lager:warning("Connection refused to AMQP, waiting a bit"),
        timer:send_after(ReconnectTime, self(), {reconnect, min(ReconnectTime * 2, ?MAX_RECONNECT)}),
        State#state { conn = {error, econnrefused} }
    end.
