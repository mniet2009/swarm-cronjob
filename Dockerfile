.......# syntax=docker/dockerfile:1

ARG GO_VERSION="1.19"
ARG ALPINE_VERSION="3.17"
ARG XX_VERSION="1.1.2"

FROM --platform=$BUILDPLATFORM tonistiigi/xx:${XX_VERSION} AS xx

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS base
COPY --from=xx / /
ENV CGO_ENABLED=0
RUN apk add --no-cache file git
WORKDIR /src

FROM base AS version
ARG GIT_REF
RUN --mount=target=. <<EOT
  set -e
  case "$GIT_REF" in
    refs/tags/v*) version="${GIT_REF#refs/tags/}" ;;
    *) version=$(git describe --match 'v[0-9]*' --dirty='.m' --always --tags) ;;
  esac
  echo "$version" | tee /tmp/.version
EOT

FROM base AS vendored
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
  go mod download

FROM vendored AS build
ARG TARGETPLATFORM
RUN --mount=type=bind,target=. \
    --mount=type=bind,from=version,source=/tmp/.version,target=/tmp/.version \
    --mount=type=cache,target=/root/.cache \
    --mount=type=cache,target=/go/pkg/mod <<EOT
  set -ex
  xx-go build -trimpath -ldflags "-s -w -X main.version=$(cat /tmp/.version)" -o /usr/bin/swarm-cronjob ./cmd
  xx-verify --static /usr/bin/swarm-cronjob
EOT

FROM scratch AS binary-unix
COPY --link --from=build /usr/bin/swarm-cronjob /

FROM scratch AS binary-windows
COPY --link --from=build /usr/bin/swarm-cronjob /swarm-cronjob.exe

FROM binary-unix AS binary-darwin
FROM binary-unix AS binary-linux
FROM binary-$TARGETOS AS binary

FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS build-artifact
RUN apk add --no-cache bash tar zip
WORKDIR /work
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
RUN --mount=type=bind,target=/src \
    --mount=type=bind,from=binary,target=/build \
    --mount=type=bind,from=version,source=/tmp/.version,target=/tmp/.version <<EOT
  set -ex
  mkdir /out
  version=$(cat /tmp/.version)
  cp /build/* /src/CHANGELOG.md /src/LICENSE /src/README.md .
  if [ "$TARGETOS" = "windows" ]; then
    zip -r "/out/swarm-cronjob_${version#v}_${TARGETOS}_${TARGETARCH}${TARGETVARIANT}.zip" .
  else
    tar -czvf "/out/swarm-cronjob_${version#v}_${TARGETOS}_${TARGETARCH}${TARGETVARIANT}.tar.gz" .
  fi
EOT

FROM scratch AS artifact
COPY --link --from=build-artifact /out /

FROM scratch AS artifacts
FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS releaser
RUN apk add --no-cache bash coreutils
WORKDIR /out
RUN --mount=from=artifacts,source=.,target=/artifacts <<EOT
  set -e
  cp /artifacts/**/* /out/ 2>/dev/null || cp /artifacts/* /out/
  sha256sum -b swarm-cronjob_* > ./checksums.txt
  sha256sum -c --strict checksums.txt
EOT

FROM scratch AS release
COPY --link --from=releaser /out /

FROM alpine:${ALPINE_VERSION}
RUN apk --update --no-cache add ca-certificates openssl
COPY --from=build /usr/bin/swarm-cronjob /usr/local/bin/swarm-cronjob
ENTRYPOINT [ "swarm-cronjob" ]
