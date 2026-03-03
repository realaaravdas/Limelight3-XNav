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
pip download \
  -d "$OUTPUT_DIR" \
  --prefer-binary \
  -r "$REPO_ROOT/vision_core/requirements.txt"

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
