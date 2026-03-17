#!/usr/bin/env bats
# Image structure tests — verify the binary, DNSSEC capability, and image
# metadata baked into the dnsmasq image.  These tests run ephemeral containers
# and do not require access to the Docker socket.

IMAGE="${IMAGE_NAME:-pygmystack/dnsmasq:test}"

# ---------------------------------------------------------------------------
# Binaries
# ---------------------------------------------------------------------------

@test "dnsmasq binary is available in PATH" {
    run docker run --rm --entrypoint which "${IMAGE}" dnsmasq
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "dnsmasq version is 2.85.x" {
    run docker run --rm --entrypoint sh "${IMAGE}" -c 'dnsmasq --version 2>&1'
    [ "$status" -eq 0 ]
    [[ "$output" =~ "2.85" ]]
}

@test "dnsmasq is built with DNSSEC support" {
    run docker run --rm --entrypoint sh "${IMAGE}" -c 'dnsmasq --version 2>&1'
    [ "$status" -eq 0 ]
    [[ "$output" =~ "DNSSEC" ]]
}

# ---------------------------------------------------------------------------
# Exposed ports (image metadata)
# ---------------------------------------------------------------------------

@test "image exposes port 53/tcp" {
    run docker inspect --format='{{json .Config.ExposedPorts}}' "${IMAGE}"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "53/tcp" ]]
}

@test "image exposes port 53/udp" {
    run docker inspect --format='{{json .Config.ExposedPorts}}' "${IMAGE}"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "53/udp" ]]
}
