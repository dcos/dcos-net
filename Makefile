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

##
## Dev
##

DCOS_DOCKER_HOST ?= dcos-docker-master1

dcos-docker-dev:
	docker exec -w ${BASE_DIR} -it ${DCOS_DOCKER_HOST} make dev

dev-install:
	@ if ! which gcc g++ make dig ip ipvsadm > /dev/null 2> /dev/null; then \
	    yum install -y make gcc gcc-c++ bind-utils iproute2 ipvsadm || exit 2; \
	  fi

dev-stop:
	@ systemctl stop dcos-net.service && \
	  source /opt/mesosphere/etc/dns_config || exit 1 && \
	  ( echo "options timeout:1" && \
	    echo "options attempts:3" && \
	    echo ${RESOLVERS} | sed -re 's/(^|[,])/\nnameserver /g' ) > /etc/resolv.conf

dev-start:
	@ systemctl stop dcos-net.service

dev-shell:
	@ ${REBAR} shell --config config/sys.config --name ${NAME} --setcookie minuteman \
	    --apps mnesia,dcos_dns,dcos_l4lb,dcos_overlay,dcos_rest,dcos_net,recon

console: dev-shell

dev: dev-install dev-stop
	@ export ENABLE_CHECK_TIME=false && \
	  systemctl cat dcos-net | sed -nre 's/ExecStartPre=//p' | tr '\n' '\0' | \
	    xargs -0 -n 1 /opt/mesosphere/bin/dcos-shell bash -c
	@ DCOS_NET_ENV_CMD="make" \
	  DCOS_NET_EBIN="${BUILD_DIR}/default/lib/dcos_net/ebin" \
	  /opt/mesosphere/bin/dcos-net-env console
