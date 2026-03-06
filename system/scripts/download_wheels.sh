#!/bin/bash
# Download Python wheels for offline installation (LOCAL TESTING)
# This script downloads wheels for testing on the current architecture
# Usage: bash download_wheels.sh [output_dir]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="${1:-$REPO_ROOT/system/wheelhouse}"

log() { echo "[WHEEL] $*"; }

log "Building wheelhouse for offline installation..."
log "Output directory: $OUTPUT_DIR"
log "Platform: $(uname -m)"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Clean any existing wheels
rm -f "$OUTPUT_DIR"/*.whl

# Create temporary venv for downloading
TEMP_VENV=$(mktemp -d)
log "Creating temporary virtual environment..."
python3 -m venv "$TEMP_VENV"
source "$TEMP_VENV/bin/activate"

# Upgrade pip and install pip-tools
log "Upgrading pip..."
pip install --upgrade pip -q

log "Downloading wheels..."

# Detect host architecture and request correct platform wheels
HOST_ARCH=$(uname -m)
if [ "$HOST_ARCH" = "aarch64" ] || [ "$HOST_ARCH" = "arm64" ]; then
  # Native ARM64 build machine - pip downloads correct architecture automatically
  pip download \
    -d "$OUTPUT_DIR" \
    --prefer-binary \
    -r "$REPO_ROOT/vision_core/requirements.txt"
else
  # Cross-platform build (e.g., x86_64 host) - explicitly request ARM64 wheels
  log "Cross-platform build detected ($HOST_ARCH -> aarch64), requesting ARM64 wheels..."
  pip download \
    -d "$OUTPUT_DIR" \
    --prefer-binary \
    --platform manylinux_2_17_aarch64 \
    --platform linux_aarch64 \
    --python-version 311 \
    --only-binary :all: \
    -r "$REPO_ROOT/vision_core/requirements.txt" || {
      log "WARN: Could not download all ARM64 binary-only wheels, retrying with source distributions allowed..."
      rm -f "$OUTPUT_DIR"/*.whl 2>/dev/null || true
      pip download \
        -d "$OUTPUT_DIR" \
        --prefer-binary \
        --platform manylinux_2_17_aarch64 \
        --platform linux_aarch64 \
        --python-version 311 \
        -r "$REPO_ROOT/vision_core/requirements.txt" || {
          log "ERROR: Could not download ARM64 wheels. Check internet connection and PyPI availability."
          exit 1
        }
    }
fi

# Clean up temporary venv
deactivate
rm -rf "$TEMP_VENV"

# Show what we downloaded
log "Wheelhouse created successfully at: $OUTPUT_DIR"
log "Size: $(du -sh "$OUTPUT_DIR" | cut -f1)"
log "Wheels downloaded: $(ls -1 "$OUTPUT_DIR"/*.whl | wc -l)"
echo ""
log "Downloaded wheels:"
ls -lh "$OUTPUT_DIR"/*.whl 2>/dev/null | tail -10
