REPO=amqp_director

.PHONY: compile clean test eunit common-test dialyzer

compile:
	rebar3 compile

clean:
	rebar3 clean

## A way to test the system
console:
	rebar3 shell

test: eunit common-test

eunit:
	rebar3 eunit

common-test:
	rebar3 ct --config ./test/test-local.config

## Dialyzer stuff follows

dialyzer:
	rebar3 dialyzer
