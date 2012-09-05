-module(amqp_director_app).

-include_lib("amqp_client/include/amqp_client.hrl").

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    Res = amqp_director_sup:start_link(),
    setup_connections( application:get_env(amqp_director, connections) ),
    setup_characters( application:get_env(amqp_director, characters) ),
    Res.

stop(_State) ->
    ok.

setup_connections( {ok, ConnectionDefs} ) ->
    [ amqp_director:add_connection( Name, parse_connection(ConnDef) ) || {Name,ConnDef} <- ConnectionDefs ],
    ok;
setup_connections( _ ) -> ok.

setup_characters( {ok, CharacterDefs} ) ->
    [ amqp_director:add_character( make_character_module(ModCtor), ConnName ) || {ModCtor, ConnName} <- CharacterDefs ],
    ok;
setup_characters( _ ) -> ok.

make_character_module( Mod ) when is_atom( Mod ) -> {Mod, Mod, undefined};
% make_character_module( {abstract, Mod, Args} )
%     when is_atom(Mod) ->
%     {Mod:new(Args), undefined};
make_character_module( {Mod, Args} ) -> {Mod, Mod, Args};
make_character_module( {Name, Mod, Args} ) ->
    { amqp_director_named_character:new(Name,Mod), Args }.

parse_connection( ParamsNetwork ) ->
    #amqp_params_network{
        username = list_to_binary( proplists:get_value(username, ParamsNetwork, "guest")  ),
        password = list_to_binary( proplists:get_value(password, ParamsNetwork, "guest")  ),
        host = proplists:get_value(host, ParamsNetwork, "localhost"),
        port = proplists:get_value(port, ParamsNetwork, undefined)
    }.
