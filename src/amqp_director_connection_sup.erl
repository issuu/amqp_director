-module (amqp_director_connection_sup).
-behaviour (supervisor).

%% API
-export ([start_link/0, register_connection/2, register_character/2]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

register_connection( Name, AmqpConnInfo ) ->
    supervisor:start_child(?MODULE, {
        Name,
        {amqp_director_connection, start_link, [Name, AmqpConnInfo]},
        permanent,
        5000,
        worker,
        [amqp_director_connection]}).

register_character( ConnId, CharacterPid ) ->
    amqp_director_connection:register(ConnId, CharacterPid). 

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, { {one_for_one, 5, 10}, []} }.

