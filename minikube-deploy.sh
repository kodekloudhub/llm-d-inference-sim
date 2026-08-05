#!/bin/bash

# This shell script deploys a minikube cluster with the vLLM renderer and the simulator
set -eo pipefail

# ------------------------------------------------------------------------------
# Check variables
# ------------------------------------------------------------------------------
require_non_empty() {
  local name=$1
  if [ -z "${!name-}" ]; then
    echo "Error: $name must not be empty" >&2
    exit 1
  fi
}

require_non_empty CLUSTER_NAME
require_non_empty HOST_PORT
require_non_empty MODEL_NAME
require_non_empty VLLM_SIMULATOR_IMAGE
require_non_empty VLLM_RENDER_IMAGE

export CLUSTER_NAME
export HOST_PORT
export MODEL_NAME
export VLLM_SIMULATOR_IMAGE
export VLLM_RENDER_IMAGE
export HF_TOKEN

# deploy/deployments.yaml pins the Service's nodePort to HOST_PORT, so it has to
# fall inside the cluster's NodePort range.
if [ "${HOST_PORT}" -lt 30000 ] || [ "${HOST_PORT}" -gt 32767 ]; then
    echo "Error: HOST_PORT must be within the NodePort range 30000-32767 (got ${HOST_PORT})." >&2
    exit 1
fi

MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-8192}"
MINIKUBE_DISK_SIZE="${MINIKUBE_DISK_SIZE:-40g}"

# ------------------------------------------------------------------------------
# Setup & Requirement Checks
# ------------------------------------------------------------------------------

# Check for a supported container runtime if an explicit one was not set
if [ -z "${CONTAINER_RUNTIME}" ]; then
  if command -v docker &> /dev/null; then
    CONTAINER_RUNTIME="docker"
  elif command -v podman &> /dev/null; then
    CONTAINER_RUNTIME="podman"
  else
    echo "Neither docker nor podman could be found in PATH" >&2
    exit 1
  fi
fi

set -u

# Check for required programs
for cmd in minikube kubectl envsubst ${CONTAINER_RUNTIME}; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is not installed or not in the PATH."
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# Cluster Deployment
# ------------------------------------------------------------------------------

# Only the docker and podman drivers can publish a host port. On the VM drivers
# the simulator is reached through "minikube service" instead.
PORT_ARGS=()
if [ "${MINIKUBE_DRIVER}" == "docker" ] || [ "${MINIKUBE_DRIVER}" == "podman" ]; then
    PORT_ARGS=("--ports=${HOST_PORT}:${HOST_PORT}")
fi

# Check if the cluster already exists
if minikube profile list -o json 2>/dev/null | grep -q "\"Name\":\"${CLUSTER_NAME}\""; then
    echo "Cluster '${CLUSTER_NAME}' already exists, re-using"
    if [ ${#PORT_ARGS[@]} -ne 0 ]; then
        echo "NOTE: a pre-existing profile keeps the port mapping it was created with."
        echo "      If http://localhost:${HOST_PORT} is unreachable, recreate the cluster:"
        echo "        minikube delete --profile ${CLUSTER_NAME}"
    fi
else
    minikube start \
        --profile "${CLUSTER_NAME}" \
        --driver "${MINIKUBE_DRIVER}" \
        --cpus "${MINIKUBE_CPUS}" \
        --memory "${MINIKUBE_MEMORY}" \
        --disk-size "${MINIKUBE_DISK_SIZE}" \
        ${PORT_ARGS[@]+"${PORT_ARGS[@]}"}
fi

# Set the kubectl context to the minikube cluster
KUBE_CONTEXT="${CLUSTER_NAME}"
kubectl config set-context ${KUBE_CONTEXT} --namespace=default

set -x

# Wait for all pods to be ready (includes minikube's storage-provisioner)
kubectl --context ${KUBE_CONTEXT} -n kube-system wait --for=condition=Ready --all pods --timeout=600s

# ------------------------------------------------------------------------------
# Load Container Images
# ------------------------------------------------------------------------------

LINUX_ARCH="$(uname -m)"
case "${LINUX_ARCH}" in
    x86_64) LINUX_ARCH="amd64" ;;
    aarch64|arm64) LINUX_ARCH="arm64" ;;
esac

PLATFORM_ARGS=()
if [ "${CONTAINER_RUNTIME}" == "docker" ]; then
    PLATFORM_ARGS=("--platform" "linux/${LINUX_ARCH}")
fi

image_in_minikube() {
    local image="$1"
    minikube --profile "${CLUSTER_NAME}" image ls 2>/dev/null \
        | sed 's|^docker.io/library/||; s|^docker.io/||' \
        | grep -qxF "${image#docker.io/}"
}

pull_image() {
    local image="$1"
    if ! "${CONTAINER_RUNTIME}" image inspect "${image}" > /dev/null 2>&1; then
        echo "Image ${image} not found locally, pulling..."
        if ! "${CONTAINER_RUNTIME}" pull ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} "${image}"; then
            echo "Error: could not pull ${image}." >&2
            if [ "${image}" == "${VLLM_SIMULATOR_IMAGE}" ]; then
                echo "Build it locally first with: make image-build" >&2
            fi
            exit 1
        fi
    fi
}

load_image() {
    local image="$1"
    echo "Loading ${image} into minikube cluster..."
    minikube --profile "${CLUSTER_NAME}" image load "${image}"
}

for IMAGE in "${VLLM_SIMULATOR_IMAGE}" "${VLLM_RENDER_IMAGE}"; do
    # "make image-build" run under "minikube docker-env" builds straight into the
    # cluster, in which case there is nothing to pull or load.
    if image_in_minikube "${IMAGE}"; then
        echo "Image ${IMAGE} is already present in the cluster, skipping load"
        continue
    fi
    pull_image "${IMAGE}"
    load_image "${IMAGE}"
done

# ------------------------------------------------------------------------------
# Development Environment
# ------------------------------------------------------------------------------

kubectl kustomize deploy \
	| envsubst '${MODEL_NAME} ${VLLM_SIMULATOR_IMAGE} ${VLLM_RENDER_IMAGE} ${HOST_PORT} ${HF_TOKEN}' \
  | kubectl --context ${KUBE_CONTEXT} apply -f -

# ------------------------------------------------------------------------------
# Check & Verify
# ------------------------------------------------------------------------------

# Wait for all deployments to be ready
kubectl --context ${KUBE_CONTEXT} -n default wait --for=condition=available --timeout=300s deployment --all

set +x

if [ ${#PORT_ARGS[@]} -ne 0 ]; then
    SIM_URL="http://localhost:${HOST_PORT}"
else
    SIM_URL="http://$(minikube --profile "${CLUSTER_NAME}" ip):${HOST_PORT}"
fi

cat <<EOF
-----------------------------------------
Deployment completed!

* Minikube Profile: ${CLUSTER_NAME}
* Kubectl Context: ${KUBE_CONTEXT}

Status:

* The vllm simulator is running
* The vllm renderer is running

You can watch the Simulator logs with:

  $ kubectl --context ${KUBE_CONTEXT} logs -f deployments/vllm-sim

With that running in the background, you can make requests:

  $ curl -s -w '\n' ${SIM_URL}/v1/completions -H 'Content-Type: application/json' -d '{"model":"${MODEL_NAME}","prompt":"hi","max_tokens":10,"temperature":0}' | jq

-----------------------------------------
EOF
