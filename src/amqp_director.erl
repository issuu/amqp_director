-module (amqp_director).
-compile([{parse_transform, lager_transform}]).

-include_lib("amqp_client/include/amqp_client.hrl").
-deprecated({client_child_spec, 3, eventually}).

%% Lifetime API
-export([
         ad_client_child_spec/3,
         sp_client_child_spec/3,
         client_child_spec/3,
         mk_app_id/1,
         parse_connection_parameters/1,
         server_child_spec/5
        ]).


-type connection_option() ::
    {host, binary()} |
    {port, non_neg_integer()} |
    {username, binary()} |
    {password, binary()} |
    {virtual_host, binary()}.

-type parsed_connection_options() :: #amqp_params_network{}.

-type content_type() :: binary().
-type queue_definition() :: #'queue.declare'{} | #'queue.bind'{} | #'exchange.declare'{}.
-type handler_return_type() ::  {reply, Payload :: binary(), content_type()} |
                                reject |
                                reject_no_requeue |
                                {reject_dump_msg, binary()} |
                                ack.
-type handler() :: fun((Payload :: binary(), ContentType :: binary(), Type :: binary()) -> handler_return_type()).

-type server_option() ::
    {queue_definitions, list(queue_definition())} |
    {consume_queue, binary()} |
    {consumer_tag, binary()} |
    {no_ack, boolean()} |
    {qos, number()} |
    {reply_persistent, boolean()}.


-type client_option() ::
    {app_id, binary()} |
    {queue_definitions, list(queue_definition())} |
    {reply_queue, binary()} |
    {no_ack, boolean()}.


-type pull_client_option() ::
    {app_id, binary()} |
    {queue_definitions, list(queue_definition())}.



%% @doc Construct an application Id for this node based on a RegName atom
%% @end
-spec mk_app_id(atom()) -> binary().
mk_app_id(RegName) when is_atom(RegName) ->
  Hostname = string:strip(os:cmd("/bin/hostname"), right, $\n),
  Creation = erlang:system_info(creation),
  {Mega, S, _} = os:timestamp(),
  iolist_to_binary(
    [Hostname, $-, atom_to_list(node()), $-,
     integer_to_list(Creation), $.,
     integer_to_list(Mega * 1000000 + S), $., atom_to_list(RegName)]).

%% @doc
%% Construct a child specification for an AMQP RPC Server.
%% This specification allows for RPC servers to be nested under any supervisor in the application using AmqpDirector. The RPC Server
%% will initialize the queues it is instructed to and will then consume messages on the queue specified. The handler function will
%% be called to handle each request.
%% @end
-spec server_child_spec(atom(), handler(), parsed_connection_options(), pos_integer(), list(server_option())) -> supervisor:child_spec().
server_child_spec(Name, Fun, ConnInfo, ServersCount, Config) ->
	ConnReg = list_to_atom(atom_to_list(Name) ++ "_conn"),
    {Name, {amqp_server_sup, start_link, [ConnReg, ConnInfo, Config, Fun, ServersCount]},
     permanent, infinity, supervisor, [amqp_server_sup]}.

%% @doc
%% Construct a child specification for an AMQP RPC Server.
%% This specification allows for RPC clients to be nested under any supervisor in the application using AmqpDirector. The RPC
%% client can perform queue initialization. It will also create a reply queue to consume replies on.
%% @end
-spec ad_client_child_spec(atom(), parsed_connection_options(), list(client_option())) -> supervisor:child_spec().
ad_client_child_spec(Name, ConnInfo, Config) ->
    ConnReg = list_to_atom(atom_to_list(Name) ++ "_conn"),
    {Name, {amqp_client_sup, start_link_ad, [Name, ConnReg, ConnInfo, Config]},
     permanent, infinity, supervisor, [amqp_client_sup]}.

%% @doc
%% Creates a child specification for an AMQP RPC pull client.
%% This specification allows for RPC clients to be nested under any supervisor in the application using AmqpDirector. The pull client
%% uses the Synchronous Pull (`#basic.get{}') over AMQP.
%% @end
-spec sp_client_child_spec(atom(), parsed_connection_options(), list(pull_client_option())) -> supervisor:child_spec().
sp_client_child_spec(Name, ConnInfo, Config) ->
    ConnReg = list_to_atom(atom_to_list(Name) ++ "_conn"),
    {Name, {amqp_client_sup, start_link_sp, [Name, ConnReg, ConnInfo, Config]},
     permanent, infinity, supervisor, [amqp_client_sup]}.

%% @deprecated Please use {@link ad_client_child_spec/3} instead
client_child_spec(Name, ConnInfo, Config) ->
    ConnReg = list_to_atom(atom_to_list(Name) ++ "_conn"),
    {Name, {amqp_client_sup, start_link, [Name, ConnReg, ConnInfo, Config]},
     permanent, infinity, supervisor, [amqp_client_sup]}.

%% @doc
%% Parses the connection parameters.
%% This function takes the conneciton parameters in form of a proplist and outputs them in format used by other functions.
%% @end
-spec parse_connection_parameters(list(connection_option())) -> parsed_connection_options().
parse_connection_parameters(Props) ->
  case [proplists:get_value(E, Props)
         || E <- [host, port, username, password, virtual_host]] of
    [Host, Port, Username, Password, VHost]
      when is_list(Host),
           Port == undefined orelse is_integer(Port),
           is_binary(Username),
           is_binary(Password) ->
       VirtualHost = case VHost of
                         undefined -> <<"/">>;
                         VH -> VH
                     end,
       #amqp_params_network { username = Username, password = Password,
                              host = Host, port = Port, virtual_host = VirtualHost };
    _Otherwise ->
      exit({error, parse_connection_parameters})
  end.
