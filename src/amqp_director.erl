-module (amqp_director).

-include_lib("amqp_client/include/amqp_client.hrl").

-export ([start/0, stop/0]).
-export ([children_specs/2]).
-export ([parse_connection_parameters/1]).
-export ([child_spec/1, server_child_spec/5, client_child_spec/3]).
-export ([add_connection/2, add_character/2]).
-export([mk_app_id/1]).

start() ->
    application:load( amqp_director ),
    [ ensure_started(A) || A <- dependent_apps()],
    application:start( amqp_director ).

stop() ->
    application:stop( amqp_director ),
    [ application:stop(A) || A <- lists:reverse(dependent_apps())],
    ok.

%% @doc Construct an application Id for this node based on a RegName atom
%% @end
mk_app_id(RegName) when is_atom(RegName) ->
  Hostname = string:strip(os:cmd("/bin/hostname"), right, $\n),
  Creation = erlang:system_info(creation),
  {Mega, S, _} = os:timestamp(),
  iolist_to_binary(
    [Hostname, $., atom_to_list(node()), $.,
     integer_to_list(Creation), $.,
     integer_to_list(Mega * 1000000 + S), $., atom_to_list(RegName)]).

-spec add_connection( atom(), #amqp_params_network{} ) ->
      {ok, pid()} | {ok, pid(), term()} | {ok, undefined} | {error, term()}.
add_connection( Name, #amqp_params_network{} = AmqpConnInfo ) ->
    amqp_director_connection_sup:register_connection(Name, AmqpConnInfo).

-spec add_character( {module(), term()}, atom() ) ->
      {ok, pid()} | {ok, pid(), term()} | {ok, undefined} | {error, term()}.
add_character( CharacterModAndArgs, ConnName ) ->
    amqp_director_character_sup:register_character(CharacterModAndArgs, ConnName).

server_child_spec(Name, Fun, ConnInfo, ServersCount, Config) ->
	ConnReg = list_to_atom(atom_to_list(Name) ++ "_conn"),
    {Name, {amqp_server_sup, start_link, [ConnReg, ConnInfo, Config, Fun, ServersCount]},
     permanent, infinity, supervisor, [amqp_server_sup]}.
     
client_child_spec(Name, ConnInfo, Config) ->
	ConnReg = list_to_atom(atom_to_list(Name) ++ "_conn"),
    {Name, {amqp_client_sup, start_link, [Name, ConnReg, ConnInfo, Config]},
     permanent, infinity, supervisor, [amqp_client_sup]}.

parse_connection_parameters(Props) ->
  case [proplists:get_value(E, Props)
         || E <- [host, port, username, password]] of
    [Host, Port, Username, Password]
      when is_list(Host),
           Port == undefined orelse is_integer(Port),
           is_binary(Username),
           is_binary(Password) ->
       #amqp_params_network { username = Username, password = Password,
                              host = Host, port = Port };
    _Otherwise ->
      exit({error, parse_connection_parameters})
  end.

-type children_type() :: servers | clients | all.
-spec children_specs(atom(), children_type()) -> [ supervisor:child_spec() ].
children_specs(App, Type) when is_atom(App) ->
    {ok, Config} = application:get_env(App, amqp_director),
    ConnectionsConf = proplists:get_value(connections, Config), % will fail if no connection is defined
    ComponentsConf = proplists:get_value(components, Config),   % will fail if no component is defined

    Connections = lists:map(fun ({Name, Overrides}) ->
        {Name, setup_amqp_record({amqp_params_network, Overrides})}
    end, ConnectionsConf),

    [ child_spec( prepare_conf(ChildConf, Connections) )
      || ChildConf <- ComponentsConf, is_component_type(ChildConf, Type) ].


-type child_conf() :: {atom(), {atom(), atom()}, #amqp_params_network{}, integer(), [{atom(), term()}]}
                    | {atom(), #amqp_params_network{}, [{atom(), term()}]}.
-spec child_spec( child_conf() ) -> supervisor:child_spec().
child_spec( {Name, Fun, ConnInfo, ServersCount, Config} ) ->
    server_child_spec(Name, Fun, ConnInfo, ServersCount, Config);
child_spec( {Name, ConnInfo, Config} ) ->
    client_child_spec(Name, ConnInfo, Config).

%%%
%%% Internals
%%%
is_component_type( _Any, all ) -> true;
is_component_type( {_Name, _ModFun, _ConnRef, _Count, _Conf}, servers ) -> true;
is_component_type( {_Name, _ConnRef, _Conf}, clients ) -> true;
is_component_type( _Component, _Type ) -> false.

make_fun(Mod, Fun) ->
    fun( Request, ContentType, MessageType ) ->
        apply( Mod, Fun, [Request, ContentType, MessageType] )
    end.

prepare_conf({Name, {Mod,Fun}, ConnRef, Count, Config}, Connections) ->
    {ConnRef, ConnInfo} = lists:keyfind(ConnRef, 1, Connections),
    {Name, make_fun(Mod, Fun), ConnInfo, Count, config(Config)};
prepare_conf({Name, ConnRef, Config}, Connections) ->
    {ConnRef, ConnInfo} = lists:keyfind(ConnRef, 1, Connections),
    {Name, ConnInfo, config(Config)}.

config(Config) ->
    [ {K, setup_config(K, V)} || {K, V} <- Config ].

setup_config(queue_definitions, Records) ->
    [ setup_amqp_record(Record) || Record <- Records ];
setup_config(_K, V) -> V. % we should't need to touch other things

setup_amqp_record( {amqp_params_network, KV} ) ->
    Fields = record_info(fields, amqp_params_network),
    create_record(Fields, #amqp_params_network{}, KV);
setup_amqp_record( {'queue.declare', KV} ) ->
    Fields = record_info(fields, 'queue.declare'),
    create_record(Fields, #'queue.declare'{}, KV);
setup_amqp_record( {'queue.bind', KV} ) ->
    Fields = record_info(fields, 'queue.bind'),
    create_record(Fields, #'queue.bind'{}, KV).

create_record(Fields, Empty, KVs) ->
    % If the template contains fields not mentioned in the record definition, let us fail
    case lists:filter(fun ({Key, _}) -> not(lists:member(Key, Fields))  end, KVs) of
        [] -> ok;
        Some -> exit({bad_record_template, lists:nth(1, Fields), Some})
    end, 
    % zip field names and empty record
    FieldsValues = lists:zip( [record_name]++Fields, tuple_to_list(Empty) ),
    % map the zipped list to the new values
    NewValues = [ proplists:get_value(Key, KVs, Value) || {Key, Value} <- FieldsValues ],
    % return the newly constructed record
    list_to_tuple(NewValues).


dependent_apps() ->
    {ok, Apps} = application:get_key(amqp_director, applications),
    Apps -- [kernel, stdlib].

ensure_started(App) ->
    case application:start(App) of
        ok -> ok;
        {error,{already_started, App}} -> ok
    end.
