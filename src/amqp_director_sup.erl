
-module(amqp_director_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
% -define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).
-define(CHILDSUP (I), {I, {I, start_link, []}, transient, infinity, supervisor, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    ConnectionsSup = ?CHILDSUP( amqp_director_connection_sup ),
    CharactersSup = ?CHILDSUP( amqp_director_character_sup ),

    {ok, { {one_for_all, 5, 10}, [ ConnectionsSup,CharactersSup ]} }.

