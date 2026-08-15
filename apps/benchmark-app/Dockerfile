FROM golang:1.23-alpine AS build

WORKDIR /src
COPY go.mod ./
COPY main.go ./

RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w" \
    -o /out/benchmark-app \
    ./

FROM alpine:3.20

RUN addgroup -S benchmark && adduser -S -G benchmark -u 10001 benchmark
COPY --from=build /out/benchmark-app /usr/local/bin/benchmark-app

USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/benchmark-app"]
