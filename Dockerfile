ARG ORFS_BASE_IMAGE=openroad/orfs:v3.0-1305-g0aa3fe5d
ARG ORFS_BASE_PLATFORM=linux/amd64

FROM --platform=${ORFS_BASE_PLATFORM} ${ORFS_BASE_IMAGE}

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      gawk \
      git \
      iverilog \
      make \
      perl \
      python3 \
      rsync \
      sed \
      time && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /OpenROAD-flow-scripts

COPY env.sh /OpenROAD-flow-scripts/env.sh
COPY flow /OpenROAD-flow-scripts/flow
COPY container/runner.sh /usr/local/bin/oproad-runner
COPY container/entrypoint.sh /usr/local/bin/oproad-entrypoint

RUN chmod +x /usr/local/bin/oproad-runner /usr/local/bin/oproad-entrypoint && \
    mkdir -p /workspace /project /tmp/runtime-root && \
    chmod -R a+rwX /OpenROAD-flow-scripts /workspace /project /tmp/runtime-root

ENV ORFS_ROOT=/OpenROAD-flow-scripts/flow \
    OPROAD_RUNNER=local \
    OPROAD_DOCKER_TTY=0 \
    OPROAD_FINISH_MODE=auto \
    QT_QPA_PLATFORM=offscreen \
    XDG_RUNTIME_DIR=/tmp/runtime-root \
    PATH=/usr/local/bin:/OpenROAD-flow-scripts/tools/install/OpenROAD/bin:/OpenROAD-flow-scripts/tools/install/yosys/bin:${PATH}

WORKDIR /workspace

ENTRYPOINT ["oproad-entrypoint"]
CMD ["bash"]
