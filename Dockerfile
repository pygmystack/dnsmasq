FROM alpine:3.16

RUN apk --no-cache add dnsmasq-dnssec=~2.86
EXPOSE 53 53/udp
ENTRYPOINT ["dnsmasq", "-k"]
