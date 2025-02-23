# Shortcut targets
default: build

## Build binary for current platform
all: build

## Run the tests for the current platform/architecture
test: ut test-install-cni

###############################################################################
# Both native and cross architecture builds are supported.
# The target architecture is select by setting the ARCH variable.
# When ARCH is undefined it is set to the detected host architecture.
# When ARCH differs from the host architecture a crossbuild will be performed.
ARCHES=$(patsubst Dockerfile.%,%,$(wildcard Dockerfile.*))

# BUILDARCH is the host architecture
# ARCH is the target architecture
# we need to keep track of them separately
BUILDARCH ?= $(shell uname -m)

# canonicalized names for host architecture
ifeq ($(BUILDARCH),aarch64)
	BUILDARCH=arm64
endif
ifeq ($(BUILDARCH),x86_64)
	BUILDARCH=amd64
endif

# unless otherwise set, I am building for my own architecture, i.e. not cross-compiling
ARCH ?= $(BUILDARCH)

# canonicalized names for target architecture
ifeq ($(ARCH),aarch64)
	override ARCH=arm64
endif
ifeq ($(ARCH),x86_64)
	override ARCH=amd64
endif

BIN=bin/$(ARCH)
GO_BUILD_VER ?= v0.24
PACKAGE_NAME?=github.com/projectcalico/cni-plugin

# Figure out the users UID/GID.  These are needed to run docker containers
# as the current user and ensure that files built inside containers are
# owned by the current user.
LOCAL_USER_ID:=$(shell id -u)
LOCAL_GROUP_ID:=$(shell id -g)

# Volume-mount gopath into the build container to cache go module's packages. If the environment is using multiple
# comma-separated directories for gopath, use the first one, as that is the default one used by go modules.
ifneq ($(GOPATH),)
	# If the environment is using multiple comma-separated directories for gopath, use the first one, as that
	# is the default one used by go modules.
	GOMOD_CACHE = $(shell echo $(GOPATH) | cut -d':' -f1)/pkg/mod
else
	# If gopath is empty, default to $(HOME)/go.
	GOMOD_CACHE = $(HOME)/go/pkg/mod
endif

EXTRA_DOCKER_ARGS	+= -e GO111MODULE=on -v $(GOMOD_CACHE):/go/pkg/mod:rw

# Build mounts for running in "local build" mode. This allows an easy build using local development code,
# assuming that there is a local checkout of libcalico in the same directory as this repo.
PHONY:local_build

ifdef LOCAL_BUILD
EXTRA_DOCKER_ARGS+=-v $(CURDIR)/../libcalico-go:/go/src/github.com/projectcalico/libcalico-go:rw
local_build:
	$(DOCKER_RUN) $(CALICO_BUILD) go mod edit -replace=github.com/projectcalico/libcalico-go=../libcalico-go
else
local_build:
	-$(DOCKER_RUN) $(CALICO_BUILD) go mod edit -dropreplace=github.com/projectcalico/libcalico-go
endif

DOCKER_RUN := mkdir -p .go-pkg-cache $(GOMOD_CACHE) $(BIN) && \
	docker run --rm \
		--net=host \
		$(EXTRA_DOCKER_ARGS) \
		-e LOCAL_USER_ID=$(LOCAL_USER_ID) \
		-e GOCACHE=/go-cache \
		-e GOARCH=$(ARCH) \
		-e GOPATH=/go \
		-v $(CURDIR):/go/src/$(PACKAGE_NAME):rw \
		-v $(CURDIR)/.go-pkg-cache:/go-cache:rw \
		-w /go/src/$(PACKAGE_NAME)

# we want to be able to run the same recipe on multiple targets keyed on the image name
# to do that, we would use the entire image name, e.g. calico/node:abcdefg, as the stem, or '%', in the target
# however, make does **not** allow the usage of invalid filename characters - like / and : - in a stem, and thus errors out
# to get around that, we "escape" those characters by converting all : to --- and all / to ___ , so that we can use them
# in the target, we then unescape them back
escapefs = $(subst :,---,$(subst /,___,$(1)))
unescapefs = $(subst ---,:,$(subst ___,/,$(1)))

# these macros create a list of valid architectures for pushing manifests
space :=
space +=
comma := ,
prefix_linux = $(addprefix linux/,$(strip $1))
join_platforms = $(subst $(space),$(comma),$(call prefix_linux,$(strip $1)))

###############################################################################
SRC_FILES=$(shell find pkg cmd internal -name '*.go')
TEST_SRC_FILES=$(shell find tests -name '*.go')
LOCAL_IP_ENV?=$(shell ip route get 8.8.8.8 | head -1 | awk '{print $$7}')

# If local build is set, then always build the binary since we might not
# detect when another local repository has been modified.
ifeq ($(LOCAL_BUILD),true)
.PHONY: $(SRC_FILES) $(TEST_SRC_FILES)
endif

# fail if unable to download
CURL=curl -C - -sSf

K8S_VERSION?=v1.14.1
CNI_VERSION=v0.8.0

# Get version from git.
GIT_VERSION:=$(shell git describe --tags --dirty --always)
ifeq ($(LOCAL_BUILD),true)
	GIT_VERSION = $(shell git describe --tags --dirty --always)-dev-build
endif

BUILD_IMAGE_ORG?=calico

# By default set the CNI_SPEC_VERSION to 0.3.1 for tests.
CNI_SPEC_VERSION?=0.3.1

CALICO_BUILD?=$(BUILD_IMAGE_ORG)/go-build:$(GO_BUILD_VER)

BUILD_IMAGE?=calico/cni
DEPLOY_CONTAINER_MARKER=cni_deploy_container-$(ARCH).created

PUSH_IMAGES?=$(BUILD_IMAGE) quay.io/calico/cni
RELEASE_IMAGES?=gcr.io/projectcalico-org/cni eu.gcr.io/projectcalico-org/cni asia.gcr.io/projectcalico-org/cni us.gcr.io/projectcalico-org/cni

# If this is a release, also tag and push additional images.
ifeq ($(RELEASE),true)
PUSH_IMAGES+=$(RELEASE_IMAGES)
endif

# remove from the list to push to manifest any registries that do not support multi-arch
EXCLUDE_MANIFEST_REGISTRIES ?= quay.io/
PUSH_MANIFEST_IMAGES=$(PUSH_IMAGES:$(EXCLUDE_MANIFEST_REGISTRIES)%=)
PUSH_NONMANIFEST_IMAGES=$(filter-out $(PUSH_MANIFEST_IMAGES),$(PUSH_IMAGES))

# location of docker credentials to push manifests
DOCKER_CONFIG ?= $(HOME)/.docker/config.json

# list of arches *not* to build when doing *-all
#    until s390x works correctly
EXCLUDEARCH ?= s390x
VALIDARCHES = $(filter-out $(EXCLUDEARCH),$(ARCHES))

ETCD_VER=v3.3.7
ETCD_CONTAINER ?= quay.io/coreos/etcd:$(ETCD_VER)-$(BUILDARCH)
# If building on amd64 omit the arch in the container name.
ifeq ($(BUILDARCH),amd64)
	ETCD_CONTAINER=quay.io/coreos/etcd:$(ETCD_VER)
endif

LOCAL_USER_ID?=$(shell id -u $$USER)

.PHONY: clean
clean:
	rm -rf $(BIN) bin/github $(DEPLOY_CONTAINER_MARKER) .go-pkg-cache k8s-install/scripts/install_cni.test
	rm -f *.created
	rm -f crds.yaml

###############################################################################
# Updating pins
###############################################################################
PIN_BRANCH?=$(shell git rev-parse --abbrev-ref HEAD)

define get_remote_version
	$(shell git ls-remote http://$(1) $(2) 2>/dev/null | cut -f 1)
endef

# update_pin updates the given package's version to the latest available in the specified repo and branch.
# $(1) should be the name of the package, $(2) and $(3) the repository and branch from which to update it.
define update_pin
	$(eval new_ver := $(call get_remote_version,$(2),$(3)))

	$(DOCKER_RUN) -i $(CALICO_BUILD) sh -c '\
		if [[ ! -z "$(new_ver)" ]]; then \
			go get $(1)@$(new_ver); \
			go mod download; \
		fi'
endef

LIBCALICO_BRANCH?=$(PIN_BRANCH)
LIBCALICO_REPO?=github.com/projectcalico/libcalico-go

update-libcalico-pin:
	$(call update_pin,github.com/projectcalico/libcalico-go,$(LIBCALICO_REPO),$(LIBCALICO_BRANCH))

git-status:
	git status --porcelain

git-config:
ifdef CONFIRM
	git config --global user.name "Semaphore Automatic Update"
	git config --global user.email "marvin@tigera.io"
endif

git-commit:
	git diff --quiet HEAD || git commit -m "Semaphore Automatic Update" go.mod go.sum

git-push:
	git push

update-pins: update-libcalico-pin

commit-pin-updates: update-pins git-status ci git-config git-commit git-push

###############################################################################
# Building the binary
###############################################################################
## Build the Calico network plugin and ipam plugins
$(BIN)/calico $(BIN)/calico-ipam: local_build $(SRC_FILES)
	$(DOCKER_RUN) \
	-v $(CURDIR)/$(BIN):/go/src/$(PACKAGE_NAME)/$(BIN):rw \
	    $(CALICO_BUILD) sh -c '\
		go build -v -o $(BIN)/calico -ldflags "-X main.VERSION=$(GIT_VERSION) -s -w" ./cmd/calico && \
		go build -v -o $(BIN)/calico-ipam -ldflags "-X main.VERSION=$(GIT_VERSION) -s -w" ./cmd/calico-ipam'

build: $(BIN)/calico $(BIN)/calico-ipam
build-all: $(addprefix sub-build-,$(VALIDARCHES))
sub-build-%:
	$(MAKE) build ARCH=$*

###############################################################################
# Building the image
###############################################################################
image: $(DEPLOY_CONTAINER_MARKER)
image-all: $(addprefix sub-image-,$(VALIDARCHES))
sub-image-%:
	$(MAKE) image ARCH=$*

# ensure we have a real imagetag
imagetag:
ifndef IMAGETAG
	$(error IMAGETAG is undefined - run using make <target> IMAGETAG=X.Y.Z)
endif

## push one arch
push: imagetag $(addprefix sub-single-push-,$(call escapefs,$(PUSH_IMAGES)))
sub-single-push-%:
	docker push $(call unescapefs,$*:$(IMAGETAG)-$(ARCH))

push-all: imagetag $(addprefix sub-push-,$(VALIDARCHES))
sub-push-%:
	$(MAKE) push ARCH=$* IMAGETAG=$(IMAGETAG)

## push multi-arch manifest where supported
push-manifests: imagetag  $(addprefix sub-manifest-,$(call escapefs,$(PUSH_MANIFEST_IMAGES)))
sub-manifest-%:
	# Docker login to hub.docker.com required before running this target as we are using $(DOCKER_CONFIG) holds the docker login credentials
	# path to credentials based on manifest-tool's requirements here https://github.com/estesp/manifest-tool#sample-usage
	docker run -t --entrypoint /bin/sh -v $(DOCKER_CONFIG):/root/.docker/config.json $(CALICO_BUILD) -c "/usr/bin/manifest-tool push from-args --platforms $(call join_platforms,$(VALIDARCHES)) --template $(call unescapefs,$*:$(IMAGETAG))-ARCH --target $(call unescapefs,$*:$(IMAGETAG))"

## push default amd64 arch where multi-arch manifest is not supported
push-non-manifests: imagetag $(addprefix sub-non-manifest-,$(call escapefs,$(PUSH_NONMANIFEST_IMAGES)))
sub-non-manifest-%:
ifeq ($(ARCH),amd64)
	docker push $(call unescapefs,$*:$(IMAGETAG))
else
	$(NOECHO) $(NOOP)
endif

## tag images of one arch
tag-images: imagetag $(addprefix sub-single-tag-images-arch-,$(call escapefs,$(PUSH_IMAGES))) $(addprefix sub-single-tag-images-non-manifest-,$(call escapefs,$(PUSH_NONMANIFEST_IMAGES)))

sub-single-tag-images-arch-%:
	docker tag $(BUILD_IMAGE):latest-$(ARCH) $(call unescapefs,$*:$(IMAGETAG)-$(ARCH))

# because some still do not support multi-arch manifest
sub-single-tag-images-non-manifest-%:
ifeq ($(ARCH),amd64)
	docker tag $(BUILD_IMAGE):latest-$(ARCH) $(call unescapefs,$*:$(IMAGETAG))
else
	$(NOECHO) $(NOOP)
endif

## tag images of all archs
tag-images-all: imagetag $(addprefix sub-tag-images-,$(VALIDARCHES))
sub-tag-images-%:
	$(MAKE) tag-images ARCH=$* IMAGETAG=$(IMAGETAG)

$(DEPLOY_CONTAINER_MARKER): Dockerfile.$(ARCH) build fetch-cni-bins
	GO111MODULE=on docker build -t $(BUILD_IMAGE):latest-$(ARCH) --build-arg QEMU_IMAGE=$(CALICO_BUILD) -f Dockerfile.$(ARCH) .
ifeq ($(ARCH),amd64)
	# Need amd64 builds tagged as :latest because Semaphore depends on that
	docker tag $(BUILD_IMAGE):latest-$(ARCH) $(BUILD_IMAGE):latest
endif
	touch $@

.PHONY: fetch-cni-bins
fetch-cni-bins: $(BIN)/flannel $(BIN)/loopback $(BIN)/host-local $(BIN)/portmap $(BIN)/tuning $(BIN)/bandwidth

$(BIN)/flannel $(BIN)/loopback $(BIN)/host-local $(BIN)/portmap $(BIN)/tuning $(BIN)/bandwidth:
	mkdir -p $(BIN)
	$(CURL) -L --retry 5 https://github.com/containernetworking/plugins/releases/download/$(CNI_VERSION)/cni-plugins-linux-$(ARCH)-$(CNI_VERSION).tgz | tar -xz -C $(BIN) ./flannel ./loopback ./host-local ./portmap ./tuning ./bandwidth

###############################################################################
# Static checks
###############################################################################
.PHONY: static-checks
LINT_ARGS := --deadline 5m --max-issues-per-linter 0 --max-same-issues 0
static-checks:
	$(DOCKER_RUN) $(CALICO_BUILD) golangci-lint run $(LINT_ARGS)

.PHONY: fix
fix:
	goimports -w $(SRC_FILES) $(TEST_SRC_FILES)

.PHONY: install-git-hooks
install-git-hooks:
	./install-git-hooks

foss-checks:
	$(DOCKER_RUN) -e FOSSA_API_KEY=$(FOSSA_API_KEY) $(CALICO_BUILD) /usr/local/bin/fossa

###############################################################################
# Unit Tests
###############################################################################
## Run the unit tests.
ut: run-k8s-controller build $(BIN)/host-local
	$(MAKE) ut-datastore DATASTORE_TYPE=etcdv3
	$(MAKE) ut-datastore DATASTORE_TYPE=kubernetes

ut-datastore: local_build
	# The tests need to run as root
	docker run --rm -t --privileged --net=host \
	-e ETCD_IP=$(LOCAL_IP_ENV) \
	-e LOCAL_USER_ID=0 \
	-e ARCH=$(ARCH) \
	-e PLUGIN=calico \
	-e BIN=/go/src/$(PACKAGE_NAME)/$(BIN) \
	-e CNI_SPEC_VERSION=$(CNI_SPEC_VERSION) \
	-e DATASTORE_TYPE=$(DATASTORE_TYPE) \
	-e ETCD_ENDPOINTS=http://$(LOCAL_IP_ENV):2379 \
	-e K8S_API_ENDPOINT=http://127.0.0.1:8080 \
	-e GO111MODULE=on \
	-v $(CURDIR):/go/src/$(PACKAGE_NAME):rw \
	$(CALICO_BUILD) sh -c '\
			cd  /go/src/$(PACKAGE_NAME) && \
			ginkgo -cover -r -skipPackage vendor -skipPackage k8s-install $(GINKGO_ARGS)'

ut-etcd: run-k8s-controller build $(BIN)/host-local
	$(MAKE) ut-datastore DATASTORE_TYPE=etcdv3
	make stop-etcd
	make stop-k8s-controller

ut-kdd: run-k8s-controller build $(BIN)/host-local
	$(MAKE) ut-datastore DATASTORE_TYPE=kubernetes
	make stop-etcd
	make stop-k8s-controller

## Run the tests in a container (as root) for different CNI spec versions
## to make sure we don't break backwards compatibility.
.PHONY: test-cni-versions
test-cni-versions:
	for cniversion in "0.2.0" "0.3.1" ; do \
		make ut CNI_SPEC_VERSION=$$cniversion; \
	done

.PHONY: remote-deps
remote-deps:
	$(DOCKER_RUN) $(CALICO_BUILD) sh -c ' \
	go mod download; \
	cp `go list -m -f "{{.Dir}}" github.com/projectcalico/libcalico-go`/test/crds.yaml crds.yaml; \
	chmod +w crds.yaml'

## Kubernetes apiserver used for tests
run-k8s-apiserver: remote-deps stop-k8s-apiserver run-etcd
	docker run --detach --net=host \
	  --name calico-k8s-apiserver \
	  -v `pwd`/crds.yaml:/crds.yaml \
	  -v `pwd`/internal/pkg/testutils/private.key:/private.key \
	  gcr.io/google_containers/hyperkube-$(ARCH):$(K8S_VERSION) \
	  /hyperkube apiserver \
	    --etcd-servers=http://$(LOCAL_IP_ENV):2379 \
	    --service-cluster-ip-range=10.101.0.0/16 \
	    --service-account-key-file=/private.key
	# Wait until the apiserver is accepting requests.
	while ! docker exec calico-k8s-apiserver kubectl get nodes; do echo "Waiting for apiserver to come up..."; sleep 2; done
	docker exec calico-k8s-apiserver kubectl apply -f /crds.yaml

## Kubernetes controller manager used for tests
run-k8s-controller: stop-k8s-controller run-k8s-apiserver
	docker run --detach --net=host \
	  --name calico-k8s-controller \
	  -v `pwd`/internal/pkg/testutils/private.key:/private.key \
	  gcr.io/google_containers/hyperkube-$(ARCH):$(K8S_VERSION) \
	  /hyperkube controller-manager \
	    --master=127.0.0.1:8080 \
	    --min-resync-period=3m \
	    --allocate-node-cidrs=true \
	    --cluster-cidr=192.168.0.0/16 \
	    --v=5 \
	    --service-account-private-key-file=/private.key

## Stop Kubernetes apiserver
stop-k8s-apiserver:
	@-docker rm -f calico-k8s-apiserver

## Stop Kubernetes controller manager
stop-k8s-controller:
	@-docker rm -f calico-k8s-controller

## Etcd is used by the tests
run-etcd: stop-etcd
	docker run --detach \
	  -p 2379:2379 \
	  --name calico-etcd $(ETCD_CONTAINER) \
	  etcd \
	  --advertise-client-urls "http://$(LOCAL_IP_ENV):2379,http://127.0.0.1:2379,http://$(LOCAL_IP_ENV):4001,http://127.0.0.1:4001" \
	  --listen-client-urls "http://0.0.0.0:2379,http://0.0.0.0:4001"

## Stops calico-etcd containers
stop-etcd:
	@-docker rm -f calico-etcd

###############################################################################
# Install test
###############################################################################
# We pre-build the test binary so that we can run it outside a container and allow it
# to interact with docker.
k8s-install/scripts/install_cni.test: k8s-install/scripts/*.go
	$(DOCKER_RUN) $(CALICO_BUILD) sh -c '\
		go test ./k8s-install/scripts -c --tags install_cni_test -o ./k8s-install/scripts/install_cni.test'

.PHONY: test-install-cni
## Test the install-cni.sh script
test-install-cni: image k8s-install/scripts/install_cni.test
	cd k8s-install/scripts && CONTAINER_NAME=$(BUILD_IMAGE) ./install_cni.test

###############################################################################
# CI/CD
###############################################################################
.PHONY: mod-download
mod-download:
	-$(DOCKER_RUN) $(CALICO_BUILD) go mod download

.PHONY: ci
ci: clean mod-download build assert-not-dirty static-checks test-cni-versions image-all test-install-cni

## Deploys images to registry
cd:
ifndef CONFIRM
	$(error CONFIRM is undefined - run using make <target> CONFIRM=true)
endif
ifndef BRANCH_NAME
	$(error BRANCH_NAME is undefined - run using make <target> BRANCH_NAME=var or set an environment variable)
endif
	$(MAKE) tag-images-all push-all push-manifests push-non-manifests  IMAGETAG=${BRANCH_NAME} EXCLUDEARCH="$(EXCLUDEARCH)"
	$(MAKE) tag-images-all push-all push-manifests push-non-manifests  IMAGETAG=$(shell git describe --tags --dirty --always --long) EXCLUDEARCH="$(EXCLUDEARCH)"


# Assert no local changes after a clean build. This helps catch errors resulting from
# misconfigured go.mod / go.sum / gitignore, etc.
assert-not-dirty:
	@./hack/check-dirty.sh

###############################################################################
# Release
###############################################################################
PREVIOUS_RELEASE=$(shell git describe --tags --abbrev=0)

## Tags and builds a release from start to finish.
release: release-prereqs
	$(MAKE) VERSION=$(VERSION) release-tag
	$(MAKE) VERSION=$(VERSION) release-build
	$(MAKE) VERSION=$(VERSION) release-verify

	@echo ""
	@echo "Release build complete. Next, push the produced images."
	@echo ""
	@echo "  make VERSION=$(VERSION) release-publish"
	@echo ""

## Produces a git tag for the release.
release-tag: release-prereqs release-notes
	git tag $(VERSION) -F release-notes-$(VERSION)
	@echo ""
	@echo "Now you can build the release:"
	@echo ""
	@echo "  make VERSION=$(VERSION) release-build"
	@echo ""

## Produces a clean build of release artifacts at the specified version.
release-build: release-prereqs clean
# Check that the correct code is checked out.
ifneq ($(VERSION), $(GIT_VERSION))
	$(error Attempt to build $(VERSION) from $(GIT_VERSION))
endif
	$(MAKE) image-all
	$(MAKE) tag-images-all RELEASE=true IMAGETAG=$(VERSION)
	$(MAKE) tag-images-all RELEASE=true IMAGETAG=latest

	# Copy artifacts for upload to GitHub.
	mkdir -p bin/github
	$(foreach var,$(VALIDARCHES), cp bin/$(var)/calico bin/github/calico-$(var);)
	$(foreach var,$(VALIDARCHES), cp bin/$(var)/calico-ipam bin/github/calico-ipam-$(var);)

## Verifies the release artifacts produces by `make release-build` are correct.
release-verify: release-prereqs
	# Check the reported version is correct for each release artifact.
	docker run --rm $(BUILD_IMAGE):$(VERSION)-$(ARCH) calico -v | grep -x $(VERSION) || ( echo "Reported version:" `docker run --rm $(BUILD_IMAGE):$(VERSION)-$(ARCH) calico -v` "\nExpected version: $(VERSION)" && exit 1 )
	docker run --rm $(BUILD_IMAGE):$(VERSION)-$(ARCH) calico-ipam -v | grep -x $(VERSION) || ( echo "Reported version:" `docker run --rm $(BUILD_IMAGE):$(VERSION)-$(ARCH) calico-ipam -v | grep -x $(VERSION)` "\nExpected version: $(VERSION)" && exit 1 )
	docker run --rm quay.io/calico/cni:$(VERSION)-$(ARCH) calico -v | grep -x $(VERSION) || ( echo "Reported version:" `docker run --rm quay.io/calico/cni:$(VERSION)-$(ARCH) calico -v | grep -x $(VERSION)` "\nExpected version: $(VERSION)" && exit 1 )
	docker run --rm quay.io/calico/cni:$(VERSION)-$(ARCH) calico-ipam -v | grep -x $(VERSION) || ( echo "Reported version:" `docker run --rm quay.io/calico/cni:$(VERSION)-$(ARCH) calico-ipam -v | grep -x $(VERSION)` "\nExpected version: $(VERSION)" && exit 1 )

	# TODO: Some sort of quick validation of the produced binaries.

## Generates release notes based on commits in this version.
release-notes: release-prereqs
	mkdir -p dist
	echo "# Changelog" > release-notes-$(VERSION)
	sh -c "git cherry -v $(PREVIOUS_RELEASE) | cut '-d ' -f 2- | sed 's/^/- /' >> release-notes-$(VERSION)"

## Pushes a github release and release artifacts produced by `make release-build`.
release-publish: release-prereqs
	# Push the git tag.
	git push origin $(VERSION)

	# Push images.
	$(MAKE) push-all push-manifests push-non-manifests RELEASE=true IMAGETAG=$(VERSION)

	# Push binaries to GitHub release.
	# Requires ghr: https://github.com/tcnksm/ghr
	# Requires GITHUB_TOKEN environment variable set.
	ghr -u projectcalico -r cni-plugin \
		-b "Release notes can be found at https://docs.projectcalico.org" \
		-n $(VERSION) \
		$(VERSION) ./bin/github/

	@echo "Confirm that the release was published at the following URL."
	@echo ""
	@echo "  https://$(PACKAGE_NAME)/releases/tag/$(VERSION)"
	@echo ""
	@echo "If this is the latest stable release, then run the following to push 'latest' images."
	@echo ""
	@echo "  make VERSION=$(VERSION) release-publish-latest"
	@echo ""

# WARNING: Only run this target if this release is the latest stable release. Do NOT
# run this target for alpha / beta / release candidate builds, or patches to earlier Calico versions.
## Pushes `latest` release images. WARNING: Only run this for latest stable releases.
release-publish-latest: release-prereqs
	# Check latest versions match.
	if ! docker run $(BUILD_IMAGE):latest-$(ARCH) calico -v | grep '^$(VERSION)$$'; then echo "Reported version:" `docker run $(BUILD_IMAGE):latest-$(ARCH) calico -v` "\nExpected version: $(VERSION)"; false; else echo "\nVersion check passed\n"; fi
	if ! docker run quay.io/$(BUILD_IMAGE):latest-$(ARCH) calico -v | grep '^$(VERSION)$$'; then echo "Reported version:" `docker run quay.io/$(BUILD_IMAGE):latest-$(ARCH) calico -v` "\nExpected version: $(VERSION)"; false; else echo "\nVersion check passed\n"; fi

	$(MAKE) push-all push-manifests push-non-manifests RELEASE=true IMAGETAG=latest

# release-prereqs checks that the environment is configured properly to create a release.
release-prereqs:
ifndef VERSION
	$(error VERSION is undefined - run using make release VERSION=vX.Y.Z)
endif
ifdef LOCAL_BUILD
	$(error LOCAL_BUILD must not be set for a release)
endif
ifndef GITHUB_TOKEN
	$(error GITHUB_TOKEN must be set for a release)
endif
ifeq (, $(shell which ghr))
	$(error Unable to find `ghr` in PATH, run this: go get -u github.com/tcnksm/ghr)
endif

###############################################################################
# Developer helper scripts (not used by build or test)
###############################################################################
## Run kube-proxy
run-kube-proxy:
	-docker rm -f calico-kube-proxy
	docker run --name calico-kube-proxy -d --net=host --privileged gcr.io/google_containers/hyperkube:$(K8S_VERSION) /hyperkube proxy --master=http://127.0.0.1:8080 --v=2

.PHONY: test-watch
## Run the unit tests, watching for changes.
test-watch: $(BIN)/calico $(BIN)/calico-ipam run-etcd run-k8s-apiserver
	# The tests need to run as root
	CGO_ENABLED=0 ETCD_IP=127.0.0.1 PLUGIN=calico GOPATH=$(GOPATH) $(shell which ginkgo) watch -skipPackage k8s-install -skipPackage vendor

.PHONY: help
help: # Some kind of magic from https://gist.github.com/rcmachado/af3db315e31383502660
	$(info Available targets)
	@awk '/^[a-zA-Z\-\_0-9\/]+:/ {				      \
		nb = sub( /^## /, "", helpMsg );				\
		if(nb == 0) {						   \
			helpMsg = $$0;					      \
			nb = sub( /^[^:]*:.* ## /, "", helpMsg );		   \
		}							       \
		if (nb)							 \
			printf "\033[1;31m%-" width "s\033[0m %s\n", $$1, helpMsg;  \
	}								   \
	{ helpMsg = $$0 }'						  \
	width=20							    \
	$(MAKEFILE_LIST)
