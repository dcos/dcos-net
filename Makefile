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

dev-install:
	@ which gcc g++ make dig ip ipvsadm > /dev/null 2> /dev/null || \
	  sudo yum install -y make gcc gcc-c++ bind-utils iproute2 ipvsadm

dev-stop:
	@ systemctl stop dcos-net.service && \
	  ( echo "options timeout:1" && \
	    echo "options attempts:3" && \
	    echo $(shell source /opt/mesosphere/etc/dns_config && \
	                 echo $${RESOLVERS} | \
	                 sed -re 's/(^|[,])/\nnameserver /g') \
	  ) > /etc/resolv.conf

dev-start:
	@ systemctl stop dcos-net.service

dev-shell:
	@ CFLAGS="-I/opt/mesosphere/include -I/opt/mesosphere/active/libsodium/include" \
	  LDFLAGS="-L/opt/mesosphere/lib -L/opt/mesosphere/active/libsodium/lib -Wl,-rpath=/opt/mesosphere/active/libsodium/lib" \
	  $(REBAR) shell --config config/sys.config --name ${NAME} --setcookie minuteman \
	    --apps mnesia,dcos_dns,dcos_l4lb,dcos_overlay,dcos_rest,dcos_net,recon

console: dev-shell

dev: dev-install dev-stop
	@ export ENABLE_CHECK_TIME=false && \
	  systemctl cat dcos-net | sed -nre 's/ExecStartPre=//p' | tr '\n' '\0' | \
	    xargs -0 -n 1 /opt/mesosphere/bin/dcos-shell bash -c
	@ DCOS_NET_ENV_CMD="make" \
	  DCOS_NET_EBIN="$(BUILD_DIR)/default/lib/dcos_net/ebin" \
	  /opt/mesosphere/bin/dcos-net-env console

##
## DC/OS E2E
##

DCOS_DOCKER_TRANSPORT ?= docker-exec
DCOS_DOCKER_CLUSTOM_VOLUME ?= "$(BASE_DIR):$(BASE_DIR):rw"
DCOS_DOCKER_CLUSTER_ID ?= default
DCOS_DOCKER_MASTERS ?= 1
DCOS_DOCKER_AGENTS ?= 1
DCOS_DOCKER_PUBLIC_AGENTS ?= 0
DCOS_DOCKER_NODE ?= master_0
DCOS_DOCKER_WEB_PORT ?= 443

dcos-docker-create:
	@ dcos-docker inspect \
	      --cluster-id $(DCOS_DOCKER_CLUSTER_ID) \
	      > /dev/null 2> /dev/null || \
	( dcos-docker create dcos_generate_config.sh \
	      --transport $(DCOS_DOCKER_TRANSPORT) \
	      --masters $(DCOS_DOCKER_MASTERS) \
	      --agents $(DCOS_DOCKER_AGENTS) \
	      --public-agents $(DCOS_DOCKER_PUBLIC_AGENTS) \
	      --cluster-id $(DCOS_DOCKER_CLUSTER_ID) \
	      --custom-volume $(DCOS_DOCKER_CLUSTOM_VOLUME) \
	      $(DCOS_DOCKER_OPTS) && \
	  dcos-docker wait \
	      --transport $(DCOS_DOCKER_TRANSPORT) \
	      --cluster-id $(DCOS_DOCKER_CLUSTER_ID) \
	      --skip-http-checks )

dcos-docker-destroy:
	@ docker ps \
	    --filter label=dcos-e2e-web-id=$(DCOS_DOCKER_CLUSTER_ID) \
	    --format '{{.ID}}' \
	| xargs docker kill > /dev/null
	@ dcos-docker destroy --cluster-id $(DCOS_DOCKER_CLUSTER_ID)

dcos-docker-web: dcos-docker-create
	@ docker ps \
	    --filter label=dcos-e2e-web-id=$(DCOS_DOCKER_CLUSTER_ID) \
	    --filter label=dcos-e2e-web-port=$(DCOS_DOCKER_WEB_PORT) \
	    --format '{{.ID}}' \
	| xargs docker kill > /dev/null
	@ docker run \
	    --rm --detach \
	    --publish $(DCOS_DOCKER_WEB_PORT):$(DCOS_DOCKER_WEB_PORT) \
	    --name $(shell dcos-docker inspect --cluster-id $(DCOS_DOCKER_CLUSTER_ID) | \
	                   jq -r .Nodes.masters[0].docker_container_name | \
	                   sed -re 's/-master-0/-web-$(DCOS_DOCKER_WEB_PORT)/') \
	    --label dcos-e2e-web-id=$(DCOS_DOCKER_CLUSTER_ID) \
	    --label dcos-e2e-web-port=$(DCOS_DOCKER_WEB_PORT) \
	    alpine/socat TCP4-LISTEN:$(DCOS_DOCKER_WEB_PORT),bind=0.0.0.0,reuseaddr,fork,su=nobody \
	                 TCP4:$(shell dcos-docker inspect --cluster-id $(DCOS_DOCKER_CLUSTER_ID) | \
	                              jq '.Nodes | .[] | .[]' | \
	                              jq 'select (.e2e_reference == "$(DCOS_DOCKER_NODE)")' | \
	                              jq -r .ip_address \
	                       ):$(DCOS_DOCKER_WEB_PORT),bind=0.0.0.0 \
	    > /dev/null
	open https://localhost:$(DCOS_DOCKER_WEB_PORT)/

dcos-docker-shell: dcos-docker-create
	@ dcos-docker run \
	    --transport $(DCOS_DOCKER_TRANSPORT) \
	    --cluster-id $(DCOS_DOCKER_CLUSTER_ID) \
	    --node $(DCOS_DOCKER_NODE) \
	    -- 'cd $(BASE_DIR) && exec /opt/mesosphere/bin/dcos-shell'

dcos-docker-dev: dcos-docker-create
	@ dcos-docker run \
	    --transport $(DCOS_DOCKER_TRANSPORT) \
	    --cluster-id $(DCOS_DOCKER_CLUSTER_ID) \
	    --node $(DCOS_DOCKER_NODE) \
	    -- '(which make > /dev/null 2> /dev/null || sudo yum install -y make) ' \
	    '&& (cd $(BASE_DIR) && exec make dev)'
