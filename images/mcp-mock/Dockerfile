# Build context: images/mcp-mock
FROM golang:1.26-alpine@sha256:3082400e369fa24d5fc60bca20edab3f6d604e0c5a690ec66b295eff4dd87ade AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /out/mcp-mock .

FROM gcr.io/distroless/static-debian12:latest@sha256:d75cdd72874d4790092fcb1b058493ecf6bb5bf2b2b897045b00ff01d91843f2
COPY --from=builder /out/mcp-mock /mcp-mock
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/mcp-mock"]
