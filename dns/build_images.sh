#!/bin/bash
# build_images.sh — Build and push Cilium + SDP images for DNS perf testing
#
# Builds from dev/v1.18 and dev/v1.19 branches, pushes to acnpublic.azurecr.io/cilium/.
# Does NOT modify your working tree — uses git worktrees for clean builds.
#
# Usage:
#   ./build_images.sh --version v1.18          # build v1.18 only
#   ./build_images.sh --version v1.19          # build v1.19 only
#   ./build_images.sh --version all            # build both
#   ./build_images.sh --version v1.18 --dry-run  # show commands only
#
# Prerequisites:
#   - Docker with buildx
#   - az cli logged in + ACR access to acnpublic
#   - Go toolchain

set -euo pipefail

###############################################################################
# Configuration
###############################################################################

CILIUM_REPO="${CILIUM_REPO:-$(pwd)}"
ACR_REGISTRY="${ACR_REGISTRY:-acnpublic.azurecr.io}"
ACR_NAME="${ACR_NAME:-acnpublic}"

# SDP base image (distroless minimal for standalone dns proxy)
SDP_BASE_IMAGE="${SDP_BASE_IMAGE:-mcr.microsoft.com/azurelinux/distroless/minimal:3.0}"

# Build arch — amd64 for testing, or multi for production
BUILD_ARCH="${BUILD_ARCH:-amd64}"

# Tag prefix for the perf test images
TAG_PREFIX="${TAG_PREFIX:-dns-perf}"

TARGET_VERSION="all"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --version|-v) TARGET_VERSION="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --arch)       BUILD_ARCH="$2"; shift 2 ;;
        --tag-prefix) TAG_PREFIX="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 --version <v1.18|v1.19|all> [--dry-run] [--arch amd64] [--tag-prefix dns-perf]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

DATE_TAG=$(date +%y%m%d)

log() { echo "[$(date '+%H:%M:%S')] $1"; }

run_or_dry() {
    if $DRY_RUN; then
        echo "  [DRY-RUN] $*"
    else
        "$@"
    fi
}

###############################################################################
# ACR Login
###############################################################################

acr_login() {
    log "Logging into ACR: $ACR_NAME"
    run_or_dry az acr login -n "$ACR_NAME"
}

###############################################################################
# Build v1.18 images (cilium, operator-generic, dns-proxy)
###############################################################################

build_v18() {
    local branch="upstream/dev/v1.18"
    local tag="${TAG_PREFIX}-v1.18"
    local worktree="$CILIUM_REPO/.worktree-v1.18"

    log "═══════════════════════════════════════════════"
    log "Building v1.18 images from $branch"
    log "  Tag: $tag"
    log "═══════════════════════════════════════════════"

    # Create worktree for clean build (doesn't touch your working tree)
    if [[ -d "$worktree" ]]; then
        log "Removing existing worktree"
        git -C "$CILIUM_REPO" worktree remove "$worktree" --force 2>/dev/null || rm -rf "$worktree"
    fi
    log "Creating worktree at $worktree"
    run_or_dry git -C "$CILIUM_REPO" worktree add "$worktree" "$branch" --detach

    if ! $DRY_RUN; then
        cd "$worktree"
    fi

    # Cilium agent and operator use the upstream cilium-builder image (standard Go).
    # Only the dnsproxy Dockerfile accepts a GOLANG_IMAGE arg. For perf testing
    # we use the default upstream Go images — no MS Go / GOEXPERIMENT needed.

    # 1. Build Cilium agent
    log "Building cilium agent..."
    run_or_dry env -C "$worktree" \
        DOCKER_REGISTRY="$ACR_REGISTRY" \
        DOCKER_IMAGE_TAG="${BUILD_ARCH}-${tag}" \
        DOCKER_FLAGS="--platform linux/${BUILD_ARCH}" \
        make docker-cilium-image

    local cilium_image="$ACR_REGISTRY/cilium/cilium:${BUILD_ARCH}-${tag}"
    log "Pushing $cilium_image"
    run_or_dry docker push "$cilium_image"

    # 2. Build Cilium operator
    log "Building cilium operator-generic..."
    run_or_dry env -C "$worktree" \
        DOCKER_REGISTRY="$ACR_REGISTRY" \
        DOCKER_IMAGE_TAG="${BUILD_ARCH}-${tag}" \
        DOCKER_FLAGS="--platform linux/${BUILD_ARCH}" \
        make docker-operator-generic-image

    local operator_image="$ACR_REGISTRY/cilium/operator-generic:${BUILD_ARCH}-${tag}"
    log "Pushing $operator_image"
    run_or_dry docker push "$operator_image"

    # 3. Build DNS proxy (v1.18 uses images/dnsproxy/)
    # Uses default GOLANG_IMAGE from the Dockerfile (upstream Go, no GOEXPERIMENT needed)
    log "Building dns-proxy (v1.18: dnsproxy)..."
    run_or_dry env -C "$worktree" \
        DOCKER_REGISTRY="$ACR_REGISTRY" \
        DOCKER_IMAGE_TAG="${BUILD_ARCH}-${tag}" \
        DOCKER_FLAGS="--platform linux/${BUILD_ARCH} --build-arg BASE_IMAGE=${SDP_BASE_IMAGE}" \
        make docker-dnsproxy-image

    local sdp_image="$ACR_REGISTRY/cilium/dns-proxy:${BUILD_ARCH}-${tag}"
    log "Pushing $sdp_image"
    run_or_dry docker push "$sdp_image"

    # Cleanup worktree
    log "Cleaning up worktree"
    cd "$CILIUM_REPO"
    run_or_dry git -C "$CILIUM_REPO" worktree remove "$worktree" --force

    log ""
    log "v1.18 images built and pushed:"
    log "  Cilium:   $cilium_image"
    log "  Operator: $operator_image"
    log "  SDP:      $sdp_image"
    log ""

    # Write image tags to a file for the perf script
    mkdir -p "$CILIUM_REPO/.build-tags"
    cat > "$CILIUM_REPO/.build-tags/v1.18.env" << EOF
CILIUM_IMAGE_REGISTRY=$ACR_REGISTRY
CILIUM_V18_IMAGE=$cilium_image
OPERATOR_V18_IMAGE=$operator_image
SDP_V18_IMAGE=$sdp_image
CILIUM_V18_TAG=${BUILD_ARCH}-${tag}
SDP_V18_TAG=${BUILD_ARCH}-${tag}
EOF
}

###############################################################################
# Build v1.19 images (cilium, operator-generic, standalone-dns-proxy)
###############################################################################

build_v19() {
    local branch="upstream/dev/v1.19"
    local tag="${TAG_PREFIX}-v1.19"
    local worktree="$CILIUM_REPO/.worktree-v1.19"

    log "═══════════════════════════════════════════════"
    log "Building v1.19 images from $branch"
    log "  Tag: $tag"
    log "═══════════════════════════════════════════════"

    if [[ -d "$worktree" ]]; then
        git -C "$CILIUM_REPO" worktree remove "$worktree" --force 2>/dev/null || rm -rf "$worktree"
    fi
    log "Creating worktree at $worktree"
    run_or_dry git -C "$CILIUM_REPO" worktree add "$worktree" "$branch" --detach

    if ! $DRY_RUN; then
        cd "$worktree"
    fi

    # Use default upstream Go images for perf testing (no MS Go / GOEXPERIMENT)

    # 1. Build Cilium agent
    log "Building cilium agent..."
    run_or_dry env -C "$worktree" \
        DOCKER_REGISTRY="$ACR_REGISTRY" \
        DOCKER_IMAGE_TAG="${BUILD_ARCH}-${tag}" \
        DOCKER_FLAGS="--platform linux/${BUILD_ARCH}" \
        make docker-cilium-image

    local cilium_image="$ACR_REGISTRY/cilium/cilium:${BUILD_ARCH}-${tag}"
    log "Pushing $cilium_image"
    run_or_dry docker push "$cilium_image"

    # 2. Build Cilium operator
    log "Building cilium operator-generic..."
    run_or_dry env -C "$worktree" \
        DOCKER_REGISTRY="$ACR_REGISTRY" \
        DOCKER_IMAGE_TAG="${BUILD_ARCH}-${tag}" \
        DOCKER_FLAGS="--platform linux/${BUILD_ARCH}" \
        make docker-operator-generic-image

    local operator_image="$ACR_REGISTRY/cilium/operator-generic:${BUILD_ARCH}-${tag}"
    log "Pushing $operator_image"
    run_or_dry docker push "$operator_image"

    # 3. Build standalone-dns-proxy (v1.19 uses images/standalone-dns-proxy/)
    #    v1.19 has a separate make target: docker-standalone-dns-proxy-image
    #    If that target doesn't exist, fall back to building via Docker directly
    log "Building standalone-dns-proxy (v1.19)..."

    # Check if the make target exists
    local makefile_content
    if $DRY_RUN; then
        makefile_content=$(git -C "$CILIUM_REPO" show "${branch}:Makefile" 2>/dev/null || true)
    else
        makefile_content=$(cat "$worktree/Makefile" 2>/dev/null || true)
    fi

    if echo "$makefile_content" | grep -q "docker-standalone-dns-proxy-image"; then
        run_or_dry env -C "$worktree" \
            DOCKER_REGISTRY="$ACR_REGISTRY" \
            DOCKER_IMAGE_TAG="${BUILD_ARCH}-${tag}" \
            DOCKER_FLAGS="--platform linux/${BUILD_ARCH} --build-arg BASE_IMAGE=${SDP_BASE_IMAGE}" \
            make docker-standalone-dns-proxy-image
        # The make target builds as standalone-dns-proxy; retag to dns-proxy for consistency
        run_or_dry docker tag \
            "$ACR_REGISTRY/cilium/standalone-dns-proxy:${BUILD_ARCH}-${tag}" \
            "$ACR_REGISTRY/cilium/dns-proxy:${BUILD_ARCH}-${tag}"
    else
        # Fallback: build directly with docker buildx
        log "  No make target found, building with docker buildx directly"
        run_or_dry docker buildx build \
            --platform "linux/${BUILD_ARCH}" \
            --build-arg "BASE_IMAGE=${SDP_BASE_IMAGE}" \
            -t "$ACR_REGISTRY/cilium/dns-proxy:${BUILD_ARCH}-${tag}" \
            -f "$worktree/images/standalone-dns-proxy/Dockerfile" \
            --load \
            "$worktree"
    fi

    local sdp_image="$ACR_REGISTRY/cilium/dns-proxy:${BUILD_ARCH}-${tag}"
    log "Pushing $sdp_image"
    run_or_dry docker push "$sdp_image"

    # Cleanup worktree
    cd "$CILIUM_REPO"
    run_or_dry git -C "$CILIUM_REPO" worktree remove "$worktree" --force

    log ""
    log "v1.19 images built and pushed:"
    log "  Cilium:   $cilium_image"
    log "  Operator: $operator_image"
    log "  SDP:      $sdp_image"
    log ""

    mkdir -p "$CILIUM_REPO/.build-tags"
    cat > "$CILIUM_REPO/.build-tags/v1.19.env" << EOF
CILIUM_IMAGE_REGISTRY=$ACR_REGISTRY
CILIUM_V19_IMAGE=$cilium_image
OPERATOR_V19_IMAGE=$operator_image
SDP_V19_IMAGE=$sdp_image
CILIUM_V19_TAG=${BUILD_ARCH}-${tag}
SDP_V19_TAG=${BUILD_ARCH}-${tag}
EOF
}

###############################################################################
# Main
###############################################################################

main() {
    log "╔══════════════════════════════════════════════════════╗"
    log "║  Build Cilium + SDP Images for DNS Perf Testing     ║"
    log "╠══════════════════════════════════════════════════════╣"
    log "║  Registry: $ACR_REGISTRY"
    log "║  Arch:     $BUILD_ARCH"
    log "║  Tag:      $TAG_PREFIX"
    log "║  Version:  $TARGET_VERSION"
    log "╚══════════════════════════════════════════════════════╝"
    log ""

    cd "$CILIUM_REPO"

    # Verify branches exist
    if [[ "$TARGET_VERSION" == "v1.18" || "$TARGET_VERSION" == "all" ]]; then
        if ! git rev-parse "upstream/dev/v1.18" >/dev/null 2>&1; then
            log "ERROR: upstream/dev/v1.18 not found. Run: git fetch upstream dev/v1.18"
            exit 1
        fi
    fi
    if [[ "$TARGET_VERSION" == "v1.19" || "$TARGET_VERSION" == "all" ]]; then
        if ! git rev-parse "upstream/dev/v1.19" >/dev/null 2>&1; then
            log "ERROR: upstream/dev/v1.19 not found. Run: git fetch upstream dev/v1.19"
            exit 1
        fi
    fi

    acr_login

    if [[ "$TARGET_VERSION" == "v1.18" || "$TARGET_VERSION" == "all" ]]; then
        build_v18
    fi

    if [[ "$TARGET_VERSION" == "v1.19" || "$TARGET_VERSION" == "all" ]]; then
        build_v19
    fi

    log "╔══════════════════════════════════════════════════════╗"
    log "║  All builds complete!                               ║"
    log "║  Image tags saved to: $CILIUM_REPO/.build-tags/     ║"
    log "╚══════════════════════════════════════════════════════╝"
    log ""
    log "To use with dns_perf_4scenario.sh, source the env files:"
    log "  source $CILIUM_REPO/.build-tags/v1.18.env"
    log "  source $CILIUM_REPO/.build-tags/v1.19.env"
}

main "$@"
