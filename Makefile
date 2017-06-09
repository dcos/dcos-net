PACKAGE         ?= navstar
VERSION         ?= $(shell git describe --tags)
BASE_DIR         = $(shell pwd)
ERLANG_BIN       = $(shell dirname $(shell which erl))
REBAR            = $(shell pwd)/rebar3

.PHONY: rel deps test eqc

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

eqc:
	${REBAR} as test eqc

eunit:
	${REBAR} as test eunit

ct:
	${REBAR} as test ct -v

cover:
	./rebar3 as test cover

edoc:
	./rebar3 edoc

##
## Release targets
##

rel:
	${REBAR} as prod release

stage:
	${REBAR} release -d

shell:
	${REBAR} shell --apps spartan

DIALYZER_APPS = kernel stdlib erts sasl eunit syntax_tools compiler crypto

include tools.mk
