ARG KERNEL_REF

FROM ${KERNEL_REF} AS kernel

FROM ghcr.io/armada-os/armada/pkg/lepton@sha256:ee6f27cb9d6b812c8da3685ad9e6c3b8ff55ec32a698aa292d676ea164aead24 AS lepton

FROM scratch AS ctx
COPY build/steps /steps
COPY system_files /system_files
COPY packages/pipewire-aptx/SOURCE.env /pins/pipewire-aptx.env

FROM registry.fedoraproject.org/fedora-bootc:44@sha256:a2789aaa615504ac9dd039a6ac0cc75343ceca89416e38441d739dbffe6557c9

COPY --from=seed / /

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=kernel,source=/rpms,target=/rpms \
    /ctx/steps/10-kernel.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx /ctx/steps/20-release.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=pkgs,source=/,target=/pkgs \
    /ctx/steps/30-packages.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=lepton,source=/,target=/lepton \
    /ctx/steps/35-lepton.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx /ctx/steps/40-system-files.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx /ctx/steps/50-initramfs.sh

ARG MICROOS_VERSION

RUN --mount=type=bind,from=ctx,source=/,target=/ctx MICROOS_VERSION=${MICROOS_VERSION} /ctx/steps/90-identity.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx /ctx/steps/99-cleanup.sh

RUN bootc container lint --fatal-warnings

ARG MICROOS_SEED

LABEL org.opencontainers.image.source=https://github.com/seilent/MicroOS
LABEL microos.seed=${MICROOS_SEED}
LABEL org.opencontainers.image.version=${MICROOS_VERSION}
