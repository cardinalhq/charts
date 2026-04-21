#!/bin/sh
# Grafana Plugin Install
# Copies plugins baked into this image at /opt/plugins into the shared
# plugins volume mounted by the Grafana container. Grafana then loads
# them from GF_PATHS_PLUGINS without needing a runtime HTTP pull.

set -e

SRC="/opt/plugins"
DEST="${GF_PATHS_PLUGINS:-/var/lib/grafana/plugins}"

if [ ! -d "$SRC" ] || [ -z "$(ls -A "$SRC" 2>/dev/null)" ]; then
    echo "No plugins bundled at $SRC - nothing to install"
    exit 0
fi

echo "Installing bundled Grafana plugins from $SRC to $DEST..."
mkdir -p "$DEST"
cp -a "$SRC"/. "$DEST"/

echo "Installed plugins:"
ls -la "$DEST"
echo "Plugin install complete"
