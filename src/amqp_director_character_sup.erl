-module (amqp_director_character_sup).
-behaviour (supervisor).

%% API
-export ([start_link/0, register_character/2]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

register_character( {CharacterMod, _Args} = ModAndArgs, ConnName ) ->
    % io:format("Registering character: ~p (~p)~n", [CharacterMod, CharacterMod:name()]),
    % Res = 
    supervisor:start_child(?MODULE, {
        CharacterMod:name(),
        {amqp_director_character, start_link, [ModAndArgs, ConnName]},
        permanent,
        5000,
        worker,
        [amqp_director_character]}).
    % ,
    % CharacterPid = case Res of
    %     {ok, Child} -> Child;
    %     {ok, Child, _Info} -> Child
    % end. %,
    % amqp_director_connection_sup:register_character(ConnName, CharacterPid),
    % Res.

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, { {one_for_one, 5, 10}, []} }.

