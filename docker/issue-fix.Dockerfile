# docker/issue-fix.Dockerfile — Container for sgt-issue-listener red/green TDD pipeline
#
# Provides a clean environment to:
#   1. Run an LLM-generated test against the current (buggy) repo  [Red phase]
#   2. Apply an LLM-generated patch, then re-run the test          [Green phase]
#
# Build:
#   docker build -f docker/issue-fix.Dockerfile -t sgt-issue-fix:latest .
#
# Run (red phase):
#   docker run --rm --network=host \
#     -v "$PWD:/repo:ro" -v "/tmp/issue-123:/workspace" \
#     sgt-issue-fix:latest bash /workspace/test.sh
#
# Run (green phase):
#   docker run --rm --network=host \
#     -v "/tmp/issue-123/repo-fix:/repo" -v "/tmp/issue-123:/workspace" \
#     sgt-issue-fix:latest bash -c 'cd /repo && git apply /workspace/fix.patch; bash /workspace/test.sh'

FROM debian:bookworm-slim

LABEL maintainer="sgt-issue-listener"
LABEL description="Red/green TDD pipeline for Sergeant GitHub issue auto-fix"

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      bash \
      git \
      tmux \
      lsof \
      procps \
      python3 \
      python3-pip \
      util-linux \
      sqlite3 \
      curl \
      ca-certificates \
      jq \
      patch \
      diffutils \
      zsh \
      dash \
      bc \
    && rm -rf /var/lib/apt/lists/*

# Install yq (mikefarah/yq — same version as Dockerfile.test)
RUN curl -fsSL \
      "https://github.com/mikefarah/yq/releases/download/v4.43.1/yq_linux_amd64" \
      -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# Configure git for container operations
RUN git config --global user.name "epictetus" && \
    git config --global user.email "epictetus@cromleylabs.com" && \
    git config --global init.defaultBranch main && \
    git config --global safe.directory '*'

WORKDIR /workspace
# NOTE: No ENTRYPOINT — docker run must specify the full command (e.g. bash /workspace/test.sh)
