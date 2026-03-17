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
# Configuration — local-service disabled
# ---------------------------------------------------------------------------

@test "dnsmasq serves DNS to clients whose source IP is not on a directly-connected subnet" {
    # Functionally validates that the local-service restriction is NOT active.
    # The default /etc/dnsmasq.conf in Alpine ships with "local-service" enabled,
    # which causes dnsmasq to silently drop queries from clients whose source IP
    # is not on a subnet directly attached to the server.  The Dockerfile
    # comments that line out so that dnsmasq answers all clients — a requirement
    # for the pygmy stack, where the host resolver queries the containerised
    # dnsmasq across Docker's bridge network.
    #
    # Topology used by this test:
    #   net-a (172.28.200.0/24) ── dnsmasq container
    #              │
    #         router (ip_forward=1, one leg on each net)
    #              │
    #   net-b (172.29.200.0/24) ── DNS client
    #
    # The client's source IP (172.29.200.x) is NOT in net-a, so with
    # local-service active dnsmasq would refuse the query.  Without it, the
    # query is answered.

    local suffix net_a net_b dns_c rtr_c
    suffix="$(openssl rand -hex 4)"
    net_a="dnsmasq-ls-a-${suffix}"
    net_b="dnsmasq-ls-b-${suffix}"
    dns_c="dnsmasq-ls-dns-${suffix}"
    rtr_c="dnsmasq-ls-rtr-${suffix}"

    # Pre-cleanup in case a previous run left debris.
    docker rm -f "${dns_c}" "${rtr_c}" 2>/dev/null || true
    docker network rm "${net_a}" "${net_b}" 2>/dev/null || true

    docker network create --subnet=172.28.200.0/24 "${net_a}"
    docker network create --subnet=172.29.200.0/24 "${net_b}"

    # dnsmasq is only connected to net-a.
    docker run -d --name "${dns_c}" \
        --network "${net_a}" \
        "${IMAGE}" \
        --address=/local-service-test.docker.amazee.io/1.2.3.4

    local dns_ip
    dns_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${net_a}\").IPAddress}}" "${dns_c}")"

    # Router bridges both networks with IP forwarding enabled.
    docker run -d --name "${rtr_c}" \
        --network "${net_a}" \
        --cap-add NET_ADMIN \
        --sysctl net.ipv4.ip_forward=1 \
        alpine sleep 30
    docker network connect "${net_b}" "${rtr_c}"

    local rtr_b_ip
    rtr_b_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${net_b}\").IPAddress}}" "${rtr_c}")"

    # Allow dnsmasq a moment to start.
    sleep 2

    # Client lives only on net-b.  It routes into net-a via the router and
    # queries dnsmasq.  Because the source IP (172.29.200.x) is outside net-a,
    # local-service would reject this if it were still active.
    run docker run --rm \
        --network "${net_b}" \
        --cap-add NET_ADMIN \
        alpine sh -c "
            ip route add 172.28.200.0/24 via ${rtr_b_ip} &&
            nslookup local-service-test.docker.amazee.io ${dns_ip}
        "

    # Capture results before cleanup so assertions reflect the real outcome.
    local test_status=$status
    local test_output="$output"

    docker rm -f "${dns_c}" "${rtr_c}" 2>/dev/null || true
    docker network rm "${net_a}" "${net_b}" 2>/dev/null || true

    [ "$test_status" -eq 0 ]
    [[ "$test_output" =~ "1.2.3.4" ]]
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
