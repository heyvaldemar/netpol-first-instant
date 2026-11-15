# The probe is one static binary in an empty image: nothing to pull at pod
# start, and nothing in the image but the code that measures.
FROM docker.io/library/golang:1.27.4-alpine@sha256:0a5f7fe796599ff487605987432e7619ae45beeb2fba4c2ce0b907879932aebf AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /probe .

FROM scratch
COPY --from=build /probe /probe
USER 65532:65532
ENTRYPOINT ["/probe"]
