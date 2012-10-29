-module (amqp_director).

-include_lib("amqp_client/include/amqp_client.hrl").

-export ([start/0, stop/0]).
-export ([children_specs/1]).
-export ([add_connection/2, add_character/2]).

start() ->
    application:load( amqp_director ),
    [ ensure_started(A) || A <- dependent_apps()],
    application:start( amqp_director ).

stop() ->
    application:stop( amqp_director ),
    [ application:stop(A) || A <- lists:reverse(dependent_apps())],
    ok.

-spec add_connection( atom(), #amqp_params_network{} ) -> {ok, pid()} | {ok, pid(), term()} | {ok, undefined} | {error, term()}.
add_connection( Name, #amqp_params_network{} = AmqpConnInfo ) ->
    amqp_director_connection_sup:register_connection(Name, AmqpConnInfo).

-spec add_character( {module(), term()}, atom() ) ->  {ok, pid()} | {ok, pid(), term()} | {ok, undefined} | {error, term()}.
add_character( CharacterModAndArgs, ConnName ) ->
    amqp_director_character_sup:register_character(CharacterModAndArgs, ConnName).

-spec children_specs(atom()) -> [ supervisor:child_spec() ].
children_specs(App) when is_atom(App) ->
    {ok, Config} = application:get_env(App, amqp_director),
    ConnectionsConf = proplists:get_value(connections, Config), % will fail if not connection is defined
    ServersConf = proplists:get_value(servers, Config, []),     % might not have any server
    ClientsConf = proplists:get_value(clients, Config, []),     % might not have any client

    Connections = lists:foldl(fun ({Name, Host,Port,User,Pwd}, D) ->
        ConnInfo = #amqp_params_network{
            username = User,
            password = Pwd,
            host     = Host,
            port     = Port
        },
        dict:store(Name, ConnInfo, D)
    end, dict:new(), ConnectionsConf),

    Servers = [ server_specs(ServerConf, Connections) || ServerConf <- ServersConf ],
    Clients = [ client_specs(ClientConf, Connections) || ClientConf <- ClientsConf ],

    Servers ++ Clients.

%%%
%%% Internals
%%%
server_specs({Name, {Mod,Fun}, ConnName, ServerCount, ServerConfig}, Connections) ->
    ConnInfo = dict:fetch(ConnName, Connections),
    ConnReg  = list_to_atom( atom_to_list(Name) ++ "_conn" ),
    Config   = [ {K, setup_config(K, V)} || {K,V} <- ServerConfig ],
    {Name, {
        amqp_server_sup, start_link,
        [ConnReg, ConnInfo, Config, fun Mod:Fun/3, ServerCount]
    }, transient, infinity, supervisor, [amqp_server_sup]}.

client_specs({Name, ConnName, ClientConfig}, Connections) ->
    ConnInfo = dict:fetch(ConnName, Connections),
    ConnReg  = list_to_atom( atom_to_list(Name) ++ "_conn" ),
    Config   = [ {K, setup_config(K, V)} || {K,V} <- ClientConfig ],
    {Name, {
        amqp_client_sup, start_link,
        [Name, ConnReg, ConnInfo, Config]
    }, transient, infinity, supervisor, [amqp_client_sup]}.

setup_config(queue_definitions, Records) ->
    [ setup_amqp_record(Record) || Record <- Records ];
setup_config(_K, V) -> V. % we should't need to touch other things

setup_amqp_record( {'queue.declare', KV} ) ->
    Fields = record_info(fields, 'queue.declare'),
    create_record(Fields, #'queue.declare'{}, KV);
setup_amqp_record( {'queue.bind', KV} ) ->
    Fields = record_info(fields, 'queue.bind'),
    create_record(Fields, #'queue.bind'{}, KV).

create_record(Fields, Empty, KVs) ->
    case lists:filter(fun ({Key, _}) -> not(lists:member(Key, Fields))  end, KVs) of
        [] -> ok;
        Some -> exit({bad_record_template, lists:nth(1, Fields), Some})
    end, 
    FieldsValues = lists:zip( [record_name]++Fields, tuple_to_list(Empty) ),
    NewValues = lists:map(fun ({Key, V}) ->
        proplists:get_value(Key, KVs, V)
    end, FieldsValues),
    list_to_tuple(NewValues).


dependent_apps() ->
    {ok, Apps} = application:get_key(amqp_director, applications),
    Apps -- [kernel, stdlib].

ensure_started(App) ->
    case application:start(App) of
        ok -> ok;
        {error,{already_started, App}} -> ok
    end.
