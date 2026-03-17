#!/usr/bin/env bats
# Runtime tests — start a long-running dnsmasq container and exercise its
# DNS behaviour.
#
# The container is started once for the entire file with two --address rules:
#   *.docker.amazee.io   → 127.0.0.1
#   test.example.invalid → 192.0.2.42
#
# DNS queries are issued from *inside* the container using the busybox nslookup
# applet, so no special host-side DNS tooling is required.

bats_require_minimum_version 1.5.0

IMAGE="${IMAGE_NAME:-pygmystack/dnsmasq:test}"

# Container name variable is set in setup() by reading the suffix written by
# setup_file().  This ensures all tests share the same name despite BATS
# re-sourcing the file for each test.
DNSMASQ_CONTAINER=""

# ---------------------------------------------------------------------------
# File-level setup / teardown — container is started once for the entire file.
# ---------------------------------------------------------------------------

setup_file() {
    # Generate a unique suffix once and persist it so every test in this run
    # references the same container name (BATS re-sources the file per test).
    local suffix
    suffix="$(openssl rand -hex 4)"
    echo "${suffix}" > "${BATS_SUITE_TMPDIR}/.suffix"
    DNSMASQ_CONTAINER="dnsmasq-bats-test-${suffix}"

    # Remove any leftover container from a previous (failed) run.
    docker rm -f "${DNSMASQ_CONTAINER}" 2>/dev/null || true

    # Start the container and fail fast if docker run does not succeed.
    local run_output
    if ! run_output="$(docker run -d \
        --name "${DNSMASQ_CONTAINER}" \
        "${IMAGE}" \
        --address=/docker.amazee.io/127.0.0.1 \
        --address=/test.example.invalid/192.0.2.42 2>&1)"; then
        echo "# Failed to start dnsmasq test container" >&3
        echo "${run_output}" >&3
        return 1
    fi

    # Wait for dnsmasq to start accepting DNS queries.
    local max_wait=15
    local waited=0
    until docker exec "${DNSMASQ_CONTAINER}" nslookup test.docker.amazee.io 127.0.0.1 >/dev/null 2>&1; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge "$max_wait" ]; then
            echo "# Timed out waiting for dnsmasq to become ready" >&3
            docker logs "${DNSMASQ_CONTAINER}" >&3 2>&3
            return 1
        fi
    done
}

teardown_file() {
    local suffix
    suffix="$(cat "${BATS_SUITE_TMPDIR}/.suffix" 2>/dev/null || true)"
    if [ -n "${suffix}" ]; then
        docker rm -f "dnsmasq-bats-test-${suffix}" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Per-test setup — restore the container name from the stable suffix written
# by setup_file(), because BATS re-sources the file for every test.
# ---------------------------------------------------------------------------

setup() {
    local suffix
    suffix="$(cat "${BATS_SUITE_TMPDIR}/.suffix" 2>/dev/null || true)"
    DNSMASQ_CONTAINER="dnsmasq-bats-test-${suffix}"
}

# ---------------------------------------------------------------------------
# Container lifecycle
# ---------------------------------------------------------------------------

@test "container is running" {
    run docker inspect --format='{{.State.Status}}' "${DNSMASQ_CONTAINER}"
    [ "$status" -eq 0 ]
    [ "$output" = "running" ]
}

@test "dnsmasq process is alive (PID 1 check)" {
    run docker exec "${DNSMASQ_CONTAINER}" sh -c 'kill -0 1 2>/dev/null && echo alive'
    [ "$status" -eq 0 ]
    [ "$output" = "alive" ]
}

@test "dnsmasq reports its version inside the container" {
    run docker exec "${DNSMASQ_CONTAINER}" sh -c 'dnsmasq --version 2>&1'
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Dnsmasq version" ]]
}

# ---------------------------------------------------------------------------
# DNS resolution
# ---------------------------------------------------------------------------

@test "dnsmasq resolves wildcard *.docker.amazee.io to 127.0.0.1" {
    run docker exec "${DNSMASQ_CONTAINER}" nslookup test.docker.amazee.io 127.0.0.1
    [ "$status" -eq 0 ]
    [[ "$output" =~ "127.0.0.1" ]]
}

@test "dnsmasq resolves a second configured address rule" {
    run docker exec "${DNSMASQ_CONTAINER}" nslookup test.example.invalid 127.0.0.1
    [ "$status" -eq 0 ]
    [[ "$output" =~ "192.0.2.42" ]]
}
