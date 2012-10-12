all: deps compile-deps

deps:
	rebar get-deps
	
compile-deps:
	rebar compile
	
compile:
	rebar skip_deps=true compile

clean:
	rebar clean
