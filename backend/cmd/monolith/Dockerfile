# Multi-stage build: compile in a full Go image, ship only the static binary
# in a minimal runtime image. Same shape as
# ../../../Professional-Meetups/backend/services/*/Dockerfile, simplified for
# this repo's single-Go-module layout (ADR-001; see
# ../../docs/plans/01-phase1-scaffold-gateway-auth.md Step 0) — one go.mod at
# backend/, no go.work, no per-module go.mod/go.sum to copy separately.
#
# Build context is the `backend/` directory (see ../../docker-compose.yml's
# `context: .` for this service), not this cmd/monolith/ folder, so the whole
# module (internal/, go.mod, go.sum) is visible to the build.

FROM golang:1.27.3-alpine@sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb AS build
WORKDIR /workspace

# Copy go.mod/go.sum before source so dependency downloads are cached across
# builds unless go.mod actually changes.
COPY go.mod go.sum* ./
RUN go mod download

COPY . .

# CGO disabled + static build: the runtime stage below has no C libraries.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/monolith ./cmd/monolith

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab AS runtime
COPY --from=build /out/monolith /monolith
USER nonroot:nonroot
EXPOSE 9090
ENTRYPOINT ["/monolith"]
