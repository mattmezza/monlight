# Build stage: compile Zig source to binary
FROM alpine:3.21 AS builder

RUN apk add --no-cache sqlite-dev musl-dev curl tar xz \
    && curl -sSL https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz | tar -xJ -C /usr/local \
    && ln -s /usr/local/zig-x86_64-linux-0.15.2/zig /usr/local/bin/zig

WORKDIR /build
COPY error-tracker/build.zig error-tracker/build.zig.zon ./error-tracker/
COPY error-tracker/src/ ./error-tracker/src/
COPY shared/ ./shared/

WORKDIR /build/error-tracker
RUN zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl -Dcpu=baseline

# Runtime stage: minimal image with just the binary
FROM alpine:3.21

RUN apk add --no-cache sqlite-libs

WORKDIR /app
RUN mkdir -p /app/data

COPY --from=builder /build/error-tracker/zig-out/bin/error-tracker /app/error-tracker

EXPOSE 8000
CMD ["/app/error-tracker"]
