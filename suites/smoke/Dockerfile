FROM alpine:3.21

RUN apk add --no-cache jq
COPY run.sh /run.sh
RUN chmod +x /run.sh
ENTRYPOINT ["/run.sh"]
