# Grafana Init Container
# Handles Grafana datasource provisioning, data reset, database setup,
# and (optionally) pre-installing the CardinalHQ LakeRunner datasource plugin
# into a shared volume so the main Grafana container can load it without
# a runtime HTTP pull.
FROM postgres:13-alpine AS base

# Install bash, curl and unzip for scripts and plugin download
RUN apk add --no-cache bash curl unzip

# --- plugin bake stage ---
# Downloads the Cardinal datasource plugin at build time so the resulting
# image can be deployed into air-gapped clusters without runtime network
# access to github.com.
FROM base AS plugin
ARG CARDINAL_PLUGIN_VERSION=v2.4.0
ARG CARDINAL_PLUGIN_URL=https://github.com/cardinalhq/cardinalhq-lakerunner-datasource/releases/download/${CARDINAL_PLUGIN_VERSION}/cardinalhq-lakerunner-datasource.zip
RUN mkdir -p /opt/plugins \
 && curl -fsSL "$CARDINAL_PLUGIN_URL" -o /tmp/plugin.zip \
 && unzip -q /tmp/plugin.zip -d /opt/plugins \
 && rm /tmp/plugin.zip

# --- final image ---
FROM base

# Copy bundled plugin from the bake stage
COPY --from=plugin /opt/plugins /opt/plugins

# Copy the scripts (COPY automatically creates parent directories)
COPY init-grafana.sh        /app/scripts/init-grafana.sh
COPY setup-grafana-db.sh    /app/scripts/setup-grafana-db.sh
COPY reset-grafana-admin.sh /app/scripts/reset-grafana-admin.sh
COPY install-plugins.sh     /app/scripts/install-plugins.sh

# Make the scripts executable
RUN chmod +x /app/scripts/init-grafana.sh \
             /app/scripts/setup-grafana-db.sh \
             /app/scripts/reset-grafana-admin.sh \
             /app/scripts/install-plugins.sh

# Set the entrypoint
ENTRYPOINT ["/app/scripts/init-grafana.sh"]
