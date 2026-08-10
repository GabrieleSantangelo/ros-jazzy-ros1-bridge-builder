VERSION := 0.1.0-tfstatic-test
CONTAINER_IMAGE := ros-jazzy-ros1-bridge:$(VERSION)
BUILDER_IMAGE := ros-jazzy-ros1-bridge-builder:$(VERSION)
CONTAINER_NAME := ros-jazzy-ros1-bridge-tfstatic-test

ROOT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

# Bridge configuration, overridable per run:
#   make run NAMESPACE=robot0 USE_SIM_TIME=true ROS_MASTER_URI=http://localhost:11311
#
# NAMESPACE replaces the {ns} placeholder in entrypoint/bridge_topics.yaml.
# Leave it empty to bridge unnamespaced names (/sensor_measurements/odom
# rather than /robot0/sensor_measurements/odom).
#
# USE_SIM_TIME=false drops /clock from the bridge. Keep it true whenever the
# ROS 1 side runs with use_sim_time, or its nodes will sit on a frozen clock.
#
# ROS_MASTER_URI picks which roscore this bridge attaches to, so one bridge
# instance per robot can run side by side, each against that robot's own
# master:
#   make run NAMESPACE=robot0 ROS_MASTER_URI=http://localhost:11311
#   make run NAMESPACE=robot1 ROS_MASTER_URI=http://localhost:11312
# The container runs with --net host, so "localhost" is the host's. A master
# on another machine also needs ROS_IP set to an address that machine can
# reach back on, or its nodes will fail to connect to the bridge.
NAMESPACE ?=
USE_SIM_TIME ?= true
ROS_MASTER_URI ?= http://localhost:11311

default: help
build: ## Build release container
	@echo "Building $(BUILDER_IMAGE) container image..."
	@docker build \
		--tag $(BUILDER_IMAGE) \
		--file docker/Dockerfile.builder \
		.
	@echo "Building ros package"
	@docker run --rm \
		$(BUILDER_IMAGE) | tar xvzf -
	@echo "Building $(CONTAINER_IMAGE) container image..."
	@docker build \
		--tag $(CONTAINER_IMAGE) \
		--file docker/Dockerfile.run \
		.
	

run-dev: ## Run container in development mode
	@echo "Running $(CONTAINER_IMAGE) container in development mode..."
	@xhost +
	@docker run \
		--interactive \
		--tty \
		--rm \
		--runtime nvidia \
		--gpus all \
		--privileged \
		--net host \
		--ipc host \
		--name ${CONTAINER_NAME}-dev \
		--volume /tmp/.X11-unix:/tmp/.X11-unix \
		--volume ~/.Xauthority:/root/.Xauthority \
		--env DISPLAY=$$DISPLAY \
		--env XAUTHORITY=$$XAUTHORITY \
		--env SSH_AUTH_SOCK=/ssh-agent \
		--env BRIDGE_NAMESPACE=$(NAMESPACE) \
		--env BRIDGE_USE_SIM_TIME=$(USE_SIM_TIME) \
		--env ROS_MASTER_URI=$(ROS_MASTER_URI) \
		--volume "$$SSH_AUTH_SOCK:/ssh-agent" \
		--volume $(ROOT_DIR):/workspace \
		--volume $(ROOT_DIR)/.cache/.claude:/root/.claude \
		$(CONTAINER_IMAGE) \
		bash

run: ## Run container in release mode
	@echo "Running $(CONTAINER_IMAGE) container in release mode..."
	@xhost +
	@docker run \
		--interactive \
		--tty \
		--rm \
		--runtime nvidia \
		--gpus all \
		--privileged \
		--net host \
		--ipc host \
		--name ${CONTAINER_NAME} \
		--volume $(ROOT_DIR)/entrypoint:/workspace/entrypoint \
		--volume /tmp/.X11-unix:/tmp/.X11-unix \
		--volume ~/.Xauthority:/root/.Xauthority \
		--env DISPLAY=$$DISPLAY \
		--env XAUTHORITY=$$XAUTHORITY \
		--env BRIDGE_NAMESPACE=$(NAMESPACE) \
		--env BRIDGE_USE_SIM_TIME=$(USE_SIM_TIME) \
		--env ROS_MASTER_URI=$(ROS_MASTER_URI) \
		$(CONTAINER_IMAGE) \
		bash -ci "/workspace/entrypoint/start.sh"

enter: ## Enter running container in development mode
	@echo "Entering $(CONTAINER_IMAGE) container..."
	@docker exec -it ${CONTAINER_NAME} bash

enter-dev: ## Enter running container in development mode
	@echo "Entering $(CONTAINER_IMAGE) container..."
	@docker exec -it ${CONTAINER_NAME}-dev bash

clean: ## Clean up container image
	@echo "Cleaning up $(CONTAINER_IMAGE) container image..."
	@docker rmi $(CONTAINER_IMAGE) $(BUILDER_IMAGE) || true

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: build run-dev enter-dev clean help
