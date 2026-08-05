#!/bin/bash

# This shell script generates steady traffic against a running simulator.
#
# The Prometheus metrics the simulator exposes are mostly counters and
# histograms, so the llm-d Grafana dashboards are built on rate() queries. With
# no traffic in the rate window those panels read 0 or NaN even though scraping
# is healthy. Run this alongside the dashboards to give them something to show.
#
# Deliberately does not use "set -e": individual requests are allowed to fail
# (that is useful signal, and it is reported in the summary) without killing the
# whole run.
set -uo pipefail

TARGET_URL="${TARGET_URL:-http://localhost:30080}"
MODEL_NAME="${MODEL_NAME:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}"
DURATION="${DURATION:-300}"
CONCURRENCY="${CONCURRENCY:-3}"
INTERVAL="${INTERVAL:-1}"
TIMEOUT="${TIMEOUT:-20}"

# ------------------------------------------------------------------------------
# Setup & Requirement Checks
# ------------------------------------------------------------------------------

if ! command -v curl &> /dev/null; then
    echo "Error: curl is not installed or not in the PATH." >&2
    exit 1
fi

if ! curl -sf --max-time 5 "${TARGET_URL}/health" > /dev/null 2>&1; then
    echo "Error: no simulator answering at ${TARGET_URL}/health" >&2
    echo "Start one with 'make dev-env-minikube' or 'make dev-env-kind', or set TARGET_URL." >&2
    exit 1
fi

RESULTS="$(mktemp)"

summarize() {
    echo
    echo "-----------------------------------------"
    echo "Requests sent: $(wc -l < "${RESULTS}" | tr -d ' ')"
    echo
    echo "By HTTP status:"
    sort "${RESULTS}" | uniq -c | sed 's/^/  /'
    echo "-----------------------------------------"
    rm -f "${RESULTS}"
}

# Report what was achieved even when interrupted part way through.
trap 'echo; echo "Interrupted."; summarize; exit 0' INT TERM

# ------------------------------------------------------------------------------
# Traffic
# ------------------------------------------------------------------------------

chat_request() {
    local iteration=$1
    local worker=$2
    # Vary prompt text and length so the token and latency histograms spread out
    # across buckets rather than piling into one.
    curl -s -o /dev/null -w '%{http_code}\n' --max-time "${TIMEOUT}" \
        "${TARGET_URL}/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"iteration ${iteration} worker ${worker} topic $((iteration % 11))\"}],\"max_tokens\":$((8 + (iteration * worker) % 40))}" \
        >> "${RESULTS}"
}

streaming_request() {
    local iteration=$1
    # Streaming exercises the time-to-first-token and inter-token latency paths.
    curl -s -o /dev/null -w '%{http_code}\n' -N --max-time "${TIMEOUT}" \
        "${TARGET_URL}/v1/completions" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${MODEL_NAME}\",\"prompt\":\"streaming iteration ${iteration}\",\"max_tokens\":20,\"stream\":true}" \
        >> "${RESULTS}"
}

echo "Generating load against ${TARGET_URL}"
echo "  model:       ${MODEL_NAME}"
echo "  duration:    ${DURATION}s"
echo "  concurrency: ${CONCURRENCY} chat + 1 streaming per iteration"
echo "  interval:    ${INTERVAL}s"
echo "Press Ctrl-C to stop early."
echo

END_TIME=$(( $(date +%s) + DURATION ))
ITERATION=0

while [ "$(date +%s)" -lt "${END_TIME}" ]; do
    ITERATION=$((ITERATION + 1))

    for worker in $(seq 1 "${CONCURRENCY}"); do
        chat_request "${ITERATION}" "${worker}" &
    done
    streaming_request "${ITERATION}" &

    wait
    sleep "${INTERVAL}"
done

echo "Completed ${ITERATION} iterations."
summarize
