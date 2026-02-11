# Build stage: compile Zig source to binary
FROM alpine:3.21 AS builder

RUN apk add --no-cache zig sqlite-dev musl-dev

WORKDIR /build
COPY error-tracker/build.zig error-tracker/build.zig.zon ./error-tracker/
COPY error-tracker/src/ ./error-tracker/src/
COPY shared/ ./shared/

WORKDIR /build/error-tracker
RUN zig build -Doptimize=ReleaseSafe

# Runtime stage: minimal image with just the binary
FROM alpine:3.21

RUN apk add --no-cache sqlite-libs

WORKDIR /app
RUN mkdir -p /app/data

COPY --from=builder /build/error-tracker/zig-out/bin/error-tracker /app/error-tracker

EXPOSE 8000
CMD ["/app/error-tracker"]
