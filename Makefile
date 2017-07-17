PACKAGE         ?= dcos-net
VERSION         ?= $(shell git describe --tags)
BASE_DIR         = $(shell pwd)
ERLANG_BIN       = $(shell dirname $(shell which erl))
REBAR            = $(shell pwd)/rebar3

.PHONY: rel deps test

all: compile

##
## Compilation targets
##

compile:
	$(REBAR) compile

clean:
	$(REBAR) clean

##
## Test targets
##

check: test xref dialyzer lint cover edoc

test: ct eunit

lint:
	${REBAR} as lint lint

xref:
	${REBAR} as test xref

dialyzer:
	${REBAR} dialyzer

eunit:
	${REBAR} as test eunit

ct:
	${REBAR} as test ct -v

cover:
	${REBAR} as test cover

edoc:
	${REBAR} edoc

##
## Release targets
##

rel:
	${REBAR} as prod release

stage:
	${REBAR} release -d
