# AMQP Director: easily integrate AMQP into your Erlang apps

The aim of this library is to make it easy to integrate AMQP in Erlang applications.
It builds on top of amqp_client (https://github.com/jbrisbin/amqp_client).

## Goals

Supports multiple connections. Amqp characters can share a single amqp_connection, or start a new one.
In all cases, each character is provided with its own amqp_channel.
Theoretically, it should be possible to support multiple amqp servers too.

Each amqp_character must provide an initialization function that accepts the amqp_channel.
If the character needs to subscribe to some queue, it needs to provide a callback function
for that purpose.

A bit of semantics:
 - should an amqp_connection fail, all linked characters are killed too
 - should a character fail, the amqp_connection it refers to is signaled,
   the character is removed from the list of linked characters,
   its channel is removed and, should the connection be left without
   characters, the connection close itself.

## Architecture



## Usage
