# Build stage: compile Zig source to binary
FROM alpine:3.21 AS builder

RUN apk add --no-cache zig sqlite-dev musl-dev

WORKDIR /build
COPY browser-relay/build.zig browser-relay/build.zig.zon ./browser-relay/
COPY browser-relay/src/ ./browser-relay/src/
COPY shared/ ./shared/

WORKDIR /build/browser-relay
RUN zig build -Doptimize=ReleaseSafe

# Runtime stage: minimal image with just the binary
FROM alpine:3.21

RUN apk add --no-cache sqlite-libs

WORKDIR /app
RUN mkdir -p /app/data

COPY --from=builder /build/browser-relay/zig-out/bin/browser-relay /app/browser-relay

EXPOSE 8000
CMD ["/app/browser-relay"]
