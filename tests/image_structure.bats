#!/usr/bin/env bats
# Image structure tests — verify the binary, DNSSEC capability, and image
# metadata baked into the dnsmasq image.  These tests run ephemeral containers
# and require Docker to be available on the host (no long-running containers).

IMAGE="${IMAGE_NAME:-pygmystack/dnsmasq:test}"

# ---------------------------------------------------------------------------
# Binaries
# ---------------------------------------------------------------------------

@test "dnsmasq binary is available in PATH" {
    run docker run --rm --entrypoint which "${IMAGE}" dnsmasq
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "dnsmasq version is 2.91.x" {
    run docker run --rm --entrypoint sh "${IMAGE}" -c 'dnsmasq --version 2>&1'
    [ "$status" -eq 0 ]
    [[ "$output" =~ "2.91" ]]
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
    # Validates that the local-service restriction is NOT active.
    # The default Alpine dnsmasq.conf enables "local-service", which silently
    # drops queries from clients whose source IP is not on a subnet directly
    # attached to dnsmasq. The Dockerfile comments that line out so all clients
    # are served — required by the pygmy stack.
    #
    # Topology:
    #   net-a (Docker auto-assigned) ── dnsmasq
    #              │
    #         router (--privileged, IP forwarding on)
    #              │
    #   net-b (Docker auto-assigned) ── DNS client
    #
    # The client's source IP is in net-b, not net-a, so local-service would
    # drop it. We verify dnsmasq received and processed the query by checking
    # its logs (--log-queries). The DNS reply cannot route back to the client
    # due to Docker network isolation — that is expected and irrelevant here;
    # only the client→dnsmasq direction is needed.

    local suffix net_a net_b dns_c rtr_c
    suffix="$(openssl rand -hex 4)"
    net_a="dnsmasq-ls-a-${suffix}"
    net_b="dnsmasq-ls-b-${suffix}"
    dns_c="dnsmasq-ls-dns-${suffix}"
    rtr_c="dnsmasq-ls-rtr-${suffix}"

    docker rm -f "${dns_c}" "${rtr_c}" 2>/dev/null || true
    docker network rm "${net_a}" "${net_b}" 2>/dev/null || true

    # Let Docker assign subnets automatically to avoid conflicts with the
    # runner's existing networks (the root cause of failures with hardcoded IPs).
    docker network create "${net_a}" >/dev/null
    docker network create "${net_b}" >/dev/null

    # dnsmasq on net-a only; logs queries to stderr so docker logs shows them.
    docker run -d --name "${dns_c}" \
        --network "${net_a}" \
        "${IMAGE}" \
        --log-queries \
        --log-facility=- \
        --address=/local-service-test.docker.amazee.io/1.2.3.4 >/dev/null

    local dns_ip net_a_subnet
    dns_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${net_a}\").IPAddress}}" "${dns_c}")"
    net_a_subnet="$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "${net_a}")"

    if [ -z "${dns_ip}" ]; then
        echo "dns_ip is empty; docker inspect failed or returned no IP for container '${dns_c}' on network '${net_a}'" >&2
        docker rm -f "${dns_c}" "${rtr_c}" 2>/dev/null || true
        docker network rm "${net_a}" "${net_b}" 2>/dev/null || true
        return 1
    fi

    if [ -z "${net_a_subnet}" ]; then
        echo "net_a_subnet is empty; docker network inspect failed or returned no subnet for network '${net_a}'" >&2
        docker rm -f "${dns_c}" "${rtr_c}" 2>/dev/null || true
        docker network rm "${net_a}" "${net_b}" 2>/dev/null || true
        return 1
    fi

    # Router with IP forwarding bridges both networks. --privileged is used
    # to ensure /proc/sys/net/ipv4/ip_forward is writable in all CI environments.
    docker run -d --name "${rtr_c}" \
        --network "${net_a}" \
        --privileged \
        alpine sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward && tail -f /dev/null' >/dev/null
    docker network connect "${net_b}" "${rtr_c}" >/dev/null

    local rtr_b_ip
    rtr_b_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${net_b}\").IPAddress}}" "${rtr_c}")"

    # Wait until the router container is running before sending traffic.
    local wait_secs=0
    until [ "$(docker inspect -f '{{.State.Running}}' "${rtr_c}" 2>/dev/null)" = "true" ]; do
        sleep 1
        wait_secs=$((wait_secs + 1))
        if [ "$wait_secs" -ge 20 ]; then
            echo "Timed out waiting for router container to start" >&2
            break
        fi
    done

    # Client on net-b routes through the router and sends the query. nslookup
    # will time out (no return path) — that is expected and ignored. We only
    # need the UDP query to reach dnsmasq.
    docker run --rm \
        --network "${net_b}" \
        --cap-add NET_ADMIN \
        alpine sh -c "
            ip route add ${net_a_subnet} via ${rtr_b_ip} 2>/dev/null || true
            timeout 3 nslookup local-service-test.docker.amazee.io ${dns_ip}
        " >/dev/null 2>&1 || true

    # Wait (bounded) for dnsmasq to log the query rather than using a fixed sleep.
    wait_secs=0
    until docker logs "${dns_c}" 2>&1 | grep -q "local-service-test.docker.amazee.io"; do
        sleep 1
        wait_secs=$((wait_secs + 1))
        if [ "$wait_secs" -ge 10 ]; then
            break
        fi
    done

    # If local-service were active dnsmasq would silently drop the query and
    # nothing would appear in its log. Presence of the query name confirms
    # local-service is disabled.
    run docker logs "${dns_c}" 2>&1

    local test_status=$status
    local test_output="$output"

    docker rm -f "${dns_c}" "${rtr_c}" 2>/dev/null || true
    docker network rm "${net_a}" "${net_b}" 2>/dev/null || true

    [ "$test_status" -eq 0 ]
    [[ "$test_output" =~ "local-service-test.docker.amazee.io" ]]
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
