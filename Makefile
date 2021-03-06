
# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd"

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

TOOLS_DIR := hack/tools
TOOLS_BIN_DIR := $(TOOLS_DIR)/bin
BIN_DIR := bin

# Binaries
GOLANGCI_LINT := $(abspath $(TOOLS_BIN_DIR)/golangci-lint)

.DEFAULT_GOAL := all

include project-name.mk

# Makes a recipe passed to a single invocation of the shell.
.ONESHELL:

MAKE_SOURCES:=makefile.mk project-name.mk Makefile
PROJECT_SOURCES:=$(shell find ./pkg -regex '.*.\.\(go\|json\)$$')

BUILD_DIR:=build/
GOMOD_VENDOR_DIR:=vendor/
export VERSION?=latest
export REPO ?="
# Image URL to use all building/pushing image targets
IMG ?= ${REPO}${ORG}/${PROJECT}:${VERSION}

ALL_GO_PACKAGES:=$(shell find ${CURDIR}/pkg/ \
	-type f -name *.go -exec dirname {} \; | sort --uniq)
GO_CHECK_PACKAGES:=$(shell echo $(subst $() $(),\\n,$(ALL_GO_PACKAGES)) | \
	awk '{print $$0}')

CHECK_ARTIFACT:=${BUILD_DIR}${PROJECT}-check-${VERSION}-docker.tar
BUILD_ARTIFACT:=${BUILD_DIR}${PROJECT}-build-${VERSION}-docker.tar

GOMOD_CACHE_ARTIFACT:=${GOMOD_CACHE_DIR}._gomod
GOMOD_VENDOR_ARTIFACT:=${GOMOD_VENDOR_DIR}._gomod
GO_BIN_ARTIFACT:=$(shell echo "$${GOBIN:-$${GOPATH}/bin}/${PROJECT}")
GO_DOCS_ARTIFACTS:=$(shell echo $(subst $() $(),\\n,$(ALL_GO_PACKAGES)) | \
	sed 's:\(.*[/\]\)\(.*\):\1\2/\2.md:')

YELLOW:=\033[0;33m
GREEN:=\033[0;32m
NC:=\033[0m

# Targets that do not represent filenames need to be registered as phony or
# Make won't always rebuild them.
.PHONY: all clean ci-check ci-gate clean-godocs \
	_godocs-build godocs clean-gomod gomod gomod-update \
	clean-${PROJECT}-check ${PROJECT}-check clean-${PROJECT}-build \
	${PROJECT}-build ${GO_CHECK_PACKAGES} clean-check check \
	clean-build build generate manifests deploy docker-push controller-gen \
	install uninstall lint-build run
# Stop prints each line of the recipe.
.SILENT:

# Allow secondary expansion of explicit rules.
.SECONDEXPANSION: %.md %-docker.tar

all: ${PROJECT}-check godocs ${PROJECT}-build
build: gomod ${PROJECT}-check godocs ${PROJECT}-build
clean: clean-gomod clean-godocs clean-${PROJECT}-check \
	clean-${PROJECT}-build clean-check clean-build \
	clean-${BUILD_DIR}


# Specific CI targets.
# ci-check: Validated the 'check' target works for debug as it cache will be used
# by build.
ci-check: check build
	$(MAKE) -C build

clean-${BUILD_DIR}:
	rm -rf ${BUILD_DIR}

${BUILD_DIR}:
	mkdir -p $@

clean-godocs:
	rm -f ${GO_DOCS_ARTIFACTS}

_godocs-build: ${GO_DOCS_ARTIFACTS}
%.md: $$(wildcard $$(dir $$@)*.go)
	echo "${YELLOW}Running godocdown: $@${NC}" && \
	godocdown -output $@ $(shell dirname $@)


clean-gomod:
	rm -rf ${GOMOD_VENDOR_DIR}

go.mod:
	rm -rf ${GOMOD_VENDOR_DIR} && \
	go mod tidy

gomod: go.sum
go.sum:  ${GOMOD_VENDOR_ARTIFACT}
%._gomod: go.mod
	rm -rf ${GOMOD_VENDOR_DIR} && \
	go mod vendor && \
	touch  ${GOMOD_VENDOR_ARTIFACT}

gomod-update: go.mod ${PROJECT_SOURCES}
	rm -rf ${GOMOD_VENDOR_DIR}  && \
	go build ./... && \
	go mod vendor  && \
	touch ${GOMOD_VENDOR_ARTIFACT}

clean-${PROJECT}-check:
	$(foreach target,${GO_CHECK_PACKAGES},
		$(MAKE) -C ${target} --makefile=${CURDIR}/makefile.mk clean;)

${PROJECT}-check: ${GO_CHECK_PACKAGES}
${GO_CHECK_PACKAGES}: go.sum
	$(MAKE) -C $@ --makefile=${CURDIR}/makefile.mk


clean-${PROJECT}-build:
	rm -f ${GO_BIN_ARTIFACT}

${PROJECT}-build: ${GO_BIN_ARTIFACT}
${GO_BIN_ARTIFACT}: go.sum ${MAKE_SOURCES} ${PROJECT_SOURCES}
	echo "${YELLOW}Building executable: $@${NC}" && \
	EMBEDDED_VERSION="github.com/fidelity/kraan/pkg/main" && \
	CGO_ENABLED=0 go build \
		-ldflags="-s -w -X $${EMBEDDED_VERSION}.serverVersion=${VERSION}" \
		-o $@ pkg/main/main.go


clean-check:
	rm -f ${CHECK_ARTIFACT}

check: DOCKER_SOURCES=Dockerfile ${MAKE_SOURCES} ${PROJECT_SOURCES}
check: DOCKER_BUILD_OPTIONS=--target builder --build-arg VERSION
check: TAG=${REPO}${ORG}/${PROJECT}-check:${VERSION}
check: ${BUILD_DIR} ${CHECK_ARTIFACT}

clean-build:
	rm -f ${BUILD_ARTIFACT}

build: DOCKER_SOURCES=Dockerfile ${MAKE_SOURCES} ${PROJECT_SOURCES}
build: DOCKER_BUILD_OPTIONS=--build-arg VERSION
build: TAG=${REPO}${ORG}/${PROJECT}:${VERSION}
build: ${BUILD_DIR} ${BUILD_ARTIFACT}

%-docker.tar: $${DOCKER_SOURCES}
	docker build --rm --pull=true \
		${DOCKER_BUILD_OPTIONS} \
		${DOCKER_BUILD_PROXYS} \
		--tag ${TAG} \
		--file $< \
		. && \
	docker save --output $@ ${TAG}

lint-build: 
$(GOLANGCI_LINT): $(TOOLS_DIR)/go.mod # Build golangci-lint from tools folder
	cd $(TOOLS_DIR); go build -tags=tools -o $(BIN_DIR)/golangci-lint github.com/golangci/golangci-lint/cmd/golangci-lint

# Run against the configured Kubernetes cluster in ~/.kube/config
run: ${PROJECT}-build
	${GO_BIN_ARTIFACT}

# Install CRDs into a cluster
install: manifests
	kustomize build config/crd | kubectl apply -f -

# Uninstall CRDs from a cluster
uninstall: manifests
	kustomize build config/crd | kubectl delete -f -

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy: manifests
	cd config/manager && kustomize edit set image kraan-controller=${IMG}
	kustomize build config/default | kubectl apply -f -

# Generate manifests e.g. CRD, RBAC etc.
manifests: controller-gen
	$(CONTROLLER_GEN) crd:trivialVersions=true paths="./..."  rbac:roleName=manager-role paths="pkg/..." output:crd:artifacts:config=config/crd/bases

# Generate code
generate: controller-gen
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

# Push the docker image
docker-push:
	docker push ${IMG}

# find or download controller-gen
# download controller-gen if necessary
controller-gen:
ifeq (, $(shell which controller-gen))
	@{ \
	set -e ;\
	CONTROLLER_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$CONTROLLER_GEN_TMP_DIR ;\
	go mod init tmp ;\
	go get sigs.k8s.io/controller-tools/cmd/controller-gen@v0.2.5 ;\
	rm -rf $$CONTROLLER_GEN_TMP_DIR ;\
	}
CONTROLLER_GEN=$(GOBIN)/controller-gen
else
CONTROLLER_GEN=$(shell which controller-gen)
endif
