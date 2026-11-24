# Fixture for .github/workflows/image-build-selftest.yml: a tiny image whose
# RUN step executes on every target platform (QEMU for arm64).
FROM alpine:3
RUN uname -m > /arch && apk upgrade --no-cache
CMD ["cat", "/arch"]
