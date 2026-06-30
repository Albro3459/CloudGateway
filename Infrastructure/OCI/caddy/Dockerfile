FROM --platform=$TARGETPLATFORM caddy:2-builder AS builder

ARG CADDY_VERSION=v2.8.4
ARG CADDY_RATE_LIMIT_MODULE=github.com/mholt/caddy-ratelimit

RUN xcaddy build "$CADDY_VERSION" \
    --with "$CADDY_RATE_LIMIT_MODULE" \
    --output /out/cloudgateway-caddy-linux-arm64

FROM builder AS verify
RUN /out/cloudgateway-caddy-linux-arm64 version
RUN /out/cloudgateway-caddy-linux-arm64 list-modules | grep -Fq 'http.handlers.rate_limit'

FROM scratch AS artifact
COPY --from=builder /out/cloudgateway-caddy-linux-arm64 /cloudgateway-caddy-linux-arm64
