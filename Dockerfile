FROM alpine:3.19

RUN apk --no-cache add dnsmasq-dnssec=~2.90
EXPOSE 53 53/udp
ENTRYPOINT ["dnsmasq", "-k"]
