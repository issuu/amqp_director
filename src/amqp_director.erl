-module (amqp_director).

-include_lib("amqp_client/include/amqp_client.hrl").

-export ([start/0, stop/0]).
-export ([add_connection/2, add_character/2]).

start() ->
    application:load( amqp_director ),
    [ ensure_started(A) || A <- dependent_apps()],
    application:start( amqp_director ).

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

-spec add_connection( atom(), #amqp_params_network{} ) -> {ok, pid()} | {ok, pid(), term()} | {ok, undefined} | {error, term()}.
add_connection( Name, #amqp_params_network{} = AmqpConnInfo ) ->
    amqp_director_connection_sup:register_connection(Name, AmqpConnInfo).

-spec add_character( {module(), term()}, atom() ) ->  {ok, pid()} | {ok, pid(), term()} | {ok, undefined} | {error, term()}.
add_character( CharacterModAndArgs, ConnName ) ->
    amqp_director_character_sup:register_character(CharacterModAndArgs, ConnName).

% Sample configuration:
% {connections, [ {conn_1, [{host,"localhost"}]}, {conn_2, [{username, "myuser"}, {host, "amqp.issuu.com"}]} ]}
% {characters, [ {my_module_1, conn_1}, {my_module_2, conn_1}, {my_module_3, conn_2} ]}