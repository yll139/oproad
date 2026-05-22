FROM ubuntu:22.04
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
      time \
      wget && \
    rm -rf /var/lib/apt/lists/*

CMD ["bash"]
