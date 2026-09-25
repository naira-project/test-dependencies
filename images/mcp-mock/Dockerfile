# Build context: images/mcp-mock
FROM golang:1.26-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /out/mcp-mock .

FROM gcr.io/distroless/static-debian12:latest
COPY --from=builder /out/mcp-mock /mcp-mock
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/mcp-mock"]
