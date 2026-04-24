#!/bin/bash
# Build script for Grafana Init Container (multi-architecture)

set -e

IMAGE_REPO="public.ecr.aws/cardinalhq.io/lakerunner/initcontainer-grafana"
VERSION="${1:-${VERSION:-}}"

TAG_ARGS=(-t "${IMAGE_REPO}:latest")
if [ -n "$VERSION" ]; then
    TAG_ARGS+=(-t "${IMAGE_REPO}:${VERSION}")
    echo "Building Grafana Init Container ${VERSION} (and :latest) for multiple architectures..."
else
    echo "Building Grafana Init Container :latest for multiple architectures..."
    echo "(Pass a version as the first arg — e.g. ./build.sh v2.0.0 — to also tag a versioned release.)"
fi

# Create buildx builder if it doesn't exist
if ! docker buildx inspect multiarch >/dev/null 2>&1; then
    echo "Creating buildx builder..."
    docker buildx create --name multiarch --use
fi

# Use the multiarch builder
docker buildx use multiarch

# Build for both AMD64 and ARM64
echo "Building for linux/amd64 and linux/arm64..."
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --pull \
    "${TAG_ARGS[@]}" \
    --push \
    .

echo "Build and push complete!"
echo "Multi-architecture image available at: ${IMAGE_REPO}:latest"
if [ -n "$VERSION" ]; then
    echo "                                     ${IMAGE_REPO}:${VERSION}"
fi

echo ""
echo "To use locally for testing (single architecture):"
echo "  docker buildx build --platform linux/amd64 --pull -t ${IMAGE_REPO}:latest --load ."