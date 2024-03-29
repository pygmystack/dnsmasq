FROM alpine:3.14

RUN apk --no-cache add dnsmasq-dnssec=~2.85
EXPOSE 53 53/udp
ENTRYPOINT ["dnsmasq", "-k"]
