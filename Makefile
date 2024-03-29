REPO=amqp_director

.PHONY: compile clean test eunit common-test dialyzer

compile:
	rebar3 compile

clean:
	rebar3 clean

## A way to test the system
console:
	rebar3 shell

test: exunit eunit common-test

exunit:
	mix test

eunit:
	rebar3 eunit

common-test:
	rebar3 ct --config ./test/test-local.config --readable=false

## Dialyzer stuff follows
dialyzer:
	mix dialyzer

erl-dialyzer:
	rebar3 dialyzer

publish:
	mix do format, compile, hex.build
	mix hex.publish --yes
