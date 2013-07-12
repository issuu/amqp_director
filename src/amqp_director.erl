-module (amqp_director).

-include_lib("amqp_client/include/amqp_client.hrl").

%% Lifetime API
-export([
         ad_client_child_spec/3,
         client_child_spec/3,
         mk_app_id/1,
         parse_connection_parameters/1,
         server_child_spec/5
        ]).

%% @doc Construct an application Id for this node based on a RegName atom
%% @end
mk_app_id(RegName) when is_atom(RegName) ->
  Hostname = string:strip(os:cmd("/bin/hostname"), right, $\n),
  Creation = erlang:system_info(creation),
  {Mega, S, _} = os:timestamp(),
  iolist_to_binary(
    [Hostname, $-, atom_to_list(node()), $-,
     integer_to_list(Creation), $.,
     integer_to_list(Mega * 1000000 + S), $., atom_to_list(RegName)]).

server_child_spec(Name, Fun, ConnInfo, ServersCount, Config) ->
	ConnReg = list_to_atom(atom_to_list(Name) ++ "_conn"),
    {Name, {amqp_server_sup, start_link, [ConnReg, ConnInfo, Config, Fun, ServersCount]},
     permanent, infinity, supervisor, [amqp_server_sup]}.

ad_client_child_spec(Name, ConnInfo, Config) ->
    ConnReg = list_to_atom(atom_to_list(Name) ++ "_conn"),
    {Name, {amqp_client_sup, start_link_ad, [Name, ConnReg, ConnInfo, Config]},
     permanent, infinity, supervisor, [amqp_client_sup]}.

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

