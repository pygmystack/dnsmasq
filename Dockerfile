FROM alpine:3.24

RUN apk --no-cache add bash dnsmasq-dnssec=~2.91

RUN sed -i 's/^local-service/\#&/' /etc/dnsmasq.conf

EXPOSE 53 53/udp
ENTRYPOINT ["dnsmasq", "-k"]
