# Build stage: compile Zig source to binary
FROM alpine:3.21 AS builder

RUN apk add --no-cache zig sqlite-dev musl-dev

WORKDIR /build
COPY log-viewer/build.zig log-viewer/build.zig.zon ./log-viewer/
COPY log-viewer/src/ ./log-viewer/src/
COPY shared/ ./shared/

WORKDIR /build/log-viewer
RUN zig build -Doptimize=ReleaseSafe

# Runtime stage: minimal image with just the binary
FROM alpine:3.21

RUN apk add --no-cache sqlite-libs

WORKDIR /app
RUN mkdir -p /app/data

COPY --from=builder /build/log-viewer/zig-out/bin/log-viewer /app/log-viewer

EXPOSE 8000
CMD ["/app/log-viewer"]
