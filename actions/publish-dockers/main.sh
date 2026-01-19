#!/bin/bash

# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the terms described in the LICENSE file in
# the root directory of this source tree.

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi
DISTROS=${DISTROS:-}

set -euo pipefail

release_exists() {
  local source=$1
  releases=$(curl -s https://${source}.org/pypi/llama-stack/json | jq -r '.releases | keys[]')
  for release in $releases; do
    if [ x"$release" = x"$VERSION" ]; then
      return 0
    fi
  done
  return 1
}

if release_exists "test.pypi"; then
  echo "Version $VERSION found in test.pypi"
  PYPI_SOURCE="testpypi"
elif release_exists "pypi"; then
  echo "Version $VERSION found in pypi"
  PYPI_SOURCE="pypi"
else
  echo "Version $VERSION not found in either test.pypi or pypi" >&2
  exit 1
fi

set -x
TMPDIR=$(mktemp -d)
cd $TMPDIR
uv venv -p python3.12
source .venv/bin/activate

uv pip install --index-url https://test.pypi.org/simple/ \
  --extra-index-url https://pypi.org/simple \
  --index-strategy unsafe-best-match \
  llama-stack==${VERSION}

which llama
llama stack list-apis

build_and_push_docker() {
  distro=$1

  echo "Building and pushing docker for distro $distro"

  # Clone llama-stack repo to get the Containerfile
  LLAMA_STACK_DIR=$(mktemp -d)
  git clone --depth 1 https://github.com/llamastack/llama-stack.git "$LLAMA_STACK_DIR"

  # Determine the tag suffix and build args based on PyPI source
  if [ "$PYPI_SOURCE" = "testpypi" ]; then
    TAG_SUFFIX="test-${VERSION}"
    BASE_TAG="llamastack/distribution-$distro:$TAG_SUFFIX-base"
    docker buildx build "$LLAMA_STACK_DIR" \
      --platform linux/amd64,linux/arm64 \
      -f "$LLAMA_STACK_DIR/containers/Containerfile" \
      --build-arg DISTRO_NAME=$distro \
      --build-arg INSTALL_MODE=test-pypi \
      --build-arg TEST_PYPI_VERSION=${VERSION} \
      -t "$BASE_TAG" \
      --push
  else
    TAG_SUFFIX="${VERSION}"
    BASE_TAG="llamastack/distribution-$distro:$TAG_SUFFIX-base"
    docker buildx build "$LLAMA_STACK_DIR" \
      --platform linux/amd64,linux/arm64 \
      -f "$LLAMA_STACK_DIR/containers/Containerfile" \
      --build-arg DISTRO_NAME=$distro \
      --build-arg PYPI_VERSION=${VERSION} \
      -t "$BASE_TAG" \
      --push
  fi

  rm -rf "$LLAMA_STACK_DIR"

  # Build a second layer for OpenShift compatibility
  TMP_BUILD_DIR=$(mktemp -d)
  CONTAINERFILE="$TMP_BUILD_DIR/Containerfile"
  cat > "$CONTAINERFILE" << EOF
FROM $BASE_TAG
USER root

# Create group with GID 1001 and user with UID 1001
RUN groupadd -g 1001 appgroup && useradd -u 1001 -g appgroup -M appuser

# Create necessary directories with appropriate permissions for UID 1001
RUN mkdir -p /.llama /.cache && chown -R 1001:1001 /.llama /.cache && chmod -R 775 /.llama /.cache && chmod -R g+w /app

# Set the Llama Stack config directory environment variable to use /.llama
ENV LLAMA_STACK_CONFIG_DIR=/.llama
ENV HOME=/

USER 1001
EOF

  echo "Building and pushing multi-arch OpenShift-compatible image"
  if [ "$PYPI_SOURCE" = "testpypi" ]; then
    FINAL_TAG="llamastack/distribution-$distro:$TAG_SUFFIX"
    docker buildx build "$TMP_BUILD_DIR" \
      --platform linux/amd64,linux/arm64 \
      -f "$CONTAINERFILE" \
      -t "$FINAL_TAG" \
      --push
  else
    FINAL_TAG="llamastack/distribution-$distro:$TAG_SUFFIX"
    LATEST_TAG="llamastack/distribution-$distro:latest"
    docker buildx build "$TMP_BUILD_DIR" \
      --platform linux/amd64,linux/arm64 \
      -f "$CONTAINERFILE" \
      -t "$FINAL_TAG" \
      -t "$LATEST_TAG" \
      --push
  fi
  rm -rf "$TMP_BUILD_DIR"

  docker images | cat
}

if [ -z "$DISTROS" ]; then
  DISTROS=(starter meta-reference-gpu postgres-demo dell starter-gpu)
else
  DISTROS=(${DISTROS//,/ })
fi

for distro in "${DISTROS[@]}"; do
  build_and_push_docker $distro
done

echo "Done"
