FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/benchmark-app ./main.go

FROM alpine:3.22
RUN apk add --no-cache ca-certificates wget
COPY --from=build /out/benchmark-app /usr/local/bin/benchmark-app
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/benchmark-app"]
