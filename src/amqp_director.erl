-module (amqp_director).

-include_lib("amqp_client/include/amqp_client.hrl").

-export ([start/0, stop/0]).
-export ([add_connection/2, add_character/2]).

start() ->
    application:load( amqp_director ),
    [ ensure_started(A) || A <- dependent_apps()],
    application:start( amqp_director ),
    setup_connections( application:get_env(amqp_director, connections) ),
    setup_characters( application:get_env(amqp_director, characters) ),
    ok.

stop() ->
    application:stop( amqp_director ),
    [ application:stop(A) || A <- lists:reverse(dependent_apps())],
    ok.

dependent_apps() ->
    {ok, Apps} = application:get_key(amqp_director, applications),
    Apps -- [kernel, stdlib].

ensure_started(App) ->
    case application:start(App) of
        ok -> ok;
        {error,{already_started, App}} -> ok
    end.

-spec add_connection( atom, #amqp_params_network{} ) -> {ok, pid()} | {ok, pid(), term()} | {ok, undefined} | {error, term()}.
add_connection( Name, #amqp_params_network{} = AmqpConnInfo ) ->
    amqp_director_connection_sup:register_connection(Name, AmqpConnInfo).

add_character( CharacterMod, ConnName ) ->
    amqp_director_character_sup:register_character(CharacterMod, ConnName).

setup_connections( undefined ) -> ok;
setup_connections( {ok, ConnectionDefs} ) ->
    [ add_connection( Name, parse_connection(ConnDef) ) || {Name,ConnDef} <- ConnectionDefs ],
    ok.

setup_characters( undefined ) -> ok;
setup_characters( {ok, CharacterDefs} ) ->
    [ add_character( Mod, ConnName ) || {Mod, ConnName} <- CharacterDefs ],
    ok.

parse_connection( ParamsNetwork ) ->
    #amqp_params_network{
        username = list_to_binary( proplists:get_value(username, ParamsNetwork, "guest")  ),
        password = list_to_binary( proplists:get_value(password, ParamsNetwork, "guest")  ),
        host = proplists:get_value(host, ParamsNetwork, "localhost"),
        port = proplists:get_value(port, ParamsNetwork, undefined)
    }.

% Sample configuration:
% {connections, [ {conn_1, [{host,"localhost"}]}, {conn_2, [{username, "myuser"}, {host, "amqp.issuu.com"}]} ]}
% {characters, [ {my_module_1, conn_1}, {my_module_2, conn_1}, {my_module_3, conn_2} ]}