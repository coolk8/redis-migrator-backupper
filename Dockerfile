FROM golang:1.22-bullseye AS builder
WORKDIR /src
ARG RDB_VERSION=v1.3.0
ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64
RUN go install github.com/hdt3213/rdb@${RDB_VERSION}

FROM ubuntu:jammy
RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y redis-tools gzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /go/bin/rdb /usr/local/bin/rdb
COPY --chmod=755 migrate.sh ./
CMD ["bash", "migrate.sh"]
