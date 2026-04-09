# Build stage: compile Zig source to binary
FROM alpine:3.21 AS builder

RUN apk add --no-cache sqlite-dev musl-dev curl tar xz \
    && curl -sSL https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz | tar -xJ -C /usr/local \
    && ln -s /usr/local/zig-linux-x86_64-0.15.2/zig /usr/local/bin/zig

WORKDIR /build
COPY browser-relay/build.zig browser-relay/build.zig.zon ./browser-relay/
COPY browser-relay/src/ ./browser-relay/src/
COPY shared/ ./shared/

WORKDIR /build/browser-relay
RUN zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl -Dcpu=baseline

# Runtime stage: minimal image with just the binary
FROM alpine:3.21

RUN apk add --no-cache sqlite-libs

WORKDIR /app
RUN mkdir -p /app/data

COPY --from=builder /build/browser-relay/zig-out/bin/browser-relay /app/browser-relay

EXPOSE 8000
CMD ["/app/browser-relay"]
