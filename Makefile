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

##
## Docker
##

DOCKER_IMAGE_REV = $(shell git log -n 1 --pretty=format:%h -- ${BASE_DIR}/Dockerfile)
DOCKER_IMAGE     = "${PACKAGE}:${DOCKER_IMAGE_REV}"
BUILD_DIR        = "${BASE_DIR}/_build"

docker-image:
	@if [ -z "$(shell docker image ls -q ${DOCKER_IMAGE})" ]; then \
	    echo "Building docker image..." >&2; \
	    docker build -t ${DOCKER_IMAGE} ${BASE_DIR}; \
	fi

docker-%: docker-image
	@mkdir -p ${BUILD_DIR}
	@docker run --rm -it --privileged \
	    -v ${BASE_DIR}:/${PACKAGE} \
	    -v ${BUILD_DIR}:/root \
	    -w /${PACKAGE} \
	    ${DOCKER_IMAGE} \
	    make $(subst docker-,,$@)

docker: docker-image
	@mkdir -p ${BUILD_DIR}
	@docker run --rm -it --privileged \
	    -v ${BASE_DIR}:/${PACKAGE} \
	    -v ${BUILD_DIR}:/root \
	    -w /${PACKAGE} \
	    ${DOCKER_IMAGE}
