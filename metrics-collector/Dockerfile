# Build stage: compile Zig source to binary
FROM alpine:3.21 AS builder

RUN apk add --no-cache zig sqlite-dev musl-dev

WORKDIR /build
COPY metrics-collector/build.zig metrics-collector/build.zig.zon ./metrics-collector/
COPY metrics-collector/src/ ./metrics-collector/src/
COPY shared/ ./shared/

WORKDIR /build/metrics-collector
RUN zig build -Doptimize=ReleaseSafe

# Runtime stage: minimal image with just the binary
FROM alpine:3.21

RUN apk add --no-cache sqlite-libs

WORKDIR /app
RUN mkdir -p /app/data

COPY --from=builder /build/metrics-collector/zig-out/bin/metrics-collector /app/metrics-collector

EXPOSE 8000
CMD ["/app/metrics-collector"]
