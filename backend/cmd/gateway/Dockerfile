# Same shape as ../monolith/Dockerfile — see the comments there. Build
# context is `backend/` (see ../../docker-compose.yml), not this folder.

FROM golang:1.26.6-alpine AS build
WORKDIR /workspace

COPY go.mod go.sum* ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/gateway ./cmd/gateway

FROM gcr.io/distroless/static-debian12:nonroot AS runtime
COPY --from=build /out/gateway /gateway
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/gateway"]
