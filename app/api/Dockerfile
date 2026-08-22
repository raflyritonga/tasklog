FROM --platform=$BUILDPLATFORM golang:1.26.1-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /tasklog-api .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /tasklog-api /tasklog-api
EXPOSE 8080
ENTRYPOINT ["/tasklog-api"]
