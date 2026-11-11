# syntax=docker/dockerfile:1
# -----------------------------------------------------------------------------
# DV toolchain image for tilelink-to-axi4-bridge (Chisel 7 -> SystemVerilog, then Verilator / Icarus / cocotb /
# SymbiYosys).  Added 2026-10-31 for the shared dv-swarm-kit; mirrors .github/workflows/ci.yml:
#   JDK 17 + sbt (elab)   apt verilator + iverilog + lcov (sim, coverage)   cocotb 1.8.1 (cocotb)
#   yosys (apt; formal uses the built-in `read -sv`) + SymbiYosys + yices (`smtbmc yices`)
# CI installs OSS CAD Suite for formal; this image uses apt yosys + from-source sby + prebuilt yices instead.
# The first `make elab` downloads Chisel/firtool via sbt (network needed once per container).
#
# Stages: tools = toolchain only (CI-style, devcontainer target); full (last) = tools + this repo + the
# dv-swarm-kit entrypoint (Railway batch, swarm workflow).  `docker run <img>` runs `make check`.
# NOT YET BUILT: written without a Docker daemon - build it once (`docker build --target tools .`) before relying
# on Codespaces / Railway.
# -----------------------------------------------------------------------------
FROM ubuntu:24.04 AS tools

ARG SBT_VERSION=1.10.5
ARG YICES_VERSION=2.6.5
ARG SBY_REF=79fc9eddca5e33a28cc2f2cd19c9825efd9a7255   # SymbiYosys main as of 2026-11-10, pinned
ARG COCOTB_VERSION=1.8.1

ENV DEBIAN_FRONTEND=noninteractive
# bare C locale in containers makes Python's stdout ASCII-only; non-ASCII banners would then crash a run
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONIOENCODING=UTF-8 PYTHONUTF8=1 PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git make g++ xz-utils \
        openjdk-17-jdk-headless \
        verilator iverilog lcov yosys \
        python3 python3-dev python3-venv \
    && rm -rf /var/lib/apt/lists/*

# sbt (launcher; the project pins sbt.version in project/build.properties)
RUN curl -fsSL "https://github.com/sbt/sbt/releases/download/v${SBT_VERSION}/sbt-${SBT_VERSION}.tgz" | tar -xz -C /opt \
    && ln -s /opt/sbt/bin/sbt /usr/local/bin/sbt

# yices2 (prebuilt static) for the `smtbmc yices` formal engine
RUN curl -fsSL "https://github.com/SRI-CSL/yices2/releases/download/Yices-${YICES_VERSION}/yices-${YICES_VERSION}-x86_64-pc-linux-gnu-static-gmp.tar.gz" \
      | tar -xz -C /opt \
    && ln -s /opt/yices-${YICES_VERSION}/bin/* /usr/local/bin/

# Python: cocotb (CI pin) + SymbiYosys's runtime deps, in a venv (PEP 668)
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir "cocotb==${COCOTB_VERSION}" click

# SymbiYosys (pure Python)
RUN git clone https://github.com/YosysHQ/sby /tmp/sby && git -C /tmp/sby checkout "${SBY_REF}" \
    && make -C /tmp/sby install PREFIX=/opt/sby && rm -rf /tmp/sby
ENV PATH="/opt/sby/bin:$PATH"

# Claude Code CLI + gh for swarm runs (dv-swarm-kit: devcontainer, swarm workflow, Railway swarm service).
ARG WITH_CLAUDE=0
ARG CLAUDE_CODE_VERSION=2.1.322   # pinned: bump on purpose, in a PR
RUN if [ "$WITH_CLAUDE" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends nodejs npm gh \
      && npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} && rm -rf /var/lib/apt/lists/*; \
    fi

RUN java -version 2>&1 | head -1 && sbt --script-version && verilator --version && iverilog -V | head -1 \
    && yosys -V && sby --help >/dev/null && yices --version | head -1 \
    && python -c "import cocotb; print('cocotb', cocotb.__version__)"

# -----------------------------------------------------------------------------
# full: the toolchain + this repo (Railway / swarm workflow).
# -----------------------------------------------------------------------------
FROM tools AS full
WORKDIR /work
COPY . /work
RUN chmod +x docker/*.sh
# dv-swarm-kit entrypoint: no args = the Railway batch; any other command (e.g. the CMD below) is exec'd
ENTRYPOINT ["/work/docker/entrypoint.sh"]
CMD ["make", "check"]
