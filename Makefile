REPO=amqp_director

.PHONY: all deps compile-deps compile clean console test check_plt clean_plt build_plt dialyzer

all: deps compile-deps

deps:
	rebar get-deps
	
compile-deps:
	rebar compile
	
compile:
	rebar skip_deps=true compile

clean:
	rebar clean

## A way to test the system
console:
	erlc -I deps test/t.erl
	erl -boot start_sasl -pa ebin deps/*/ebin

test:
	mkdir -p test_logs
	ct_run -pa deps/*/ebin ebin -spec test-local.spec \
	 -label local \
	 -ct_hooks cth_surefire '[{path,"common_test_report.xml"}]'

## Dialyzer stuff follows
APPS = kernel stdlib sasl erts ssl tools os_mon runtime_tools crypto inets \
	xmerl webtool snmp public_key mnesia eunit syntax_tools compiler
COMBO_PLT = $(HOME)/.$(REPO)_combo_dialyzer_plt

check_plt: compile
	dialyzer --check_plt --plt $(COMBO_PLT) --apps $(APPS) \
		deps/*/ebin

build_plt: compile
	dialyzer --build_plt --output_plt $(COMBO_PLT) --apps $(APPS) \
		deps/amqp_client/ebin\
		deps/rabbit_common/ebin

dialyzer:
	@echo
	@echo Use "'make check_plt'" to check PLT prior to using this target.
	@echo Use "'make build_plt'" to build PLT prior to using this target.
	@echo
	@sleep 1
	dialyzer -Wno_return --plt $(COMBO_PLT) ebin #| grep -F -v -f ./dialyzer.ignore-warnings

cleanplt:
	@echo
	@echo "Are you sure?  It takes about 1/2 hour to re-build."
	@echo Deleting $(COMBO_PLT) in 5 seconds.
	@echo
	sleep 5
	rm $(COMBO_PLT)