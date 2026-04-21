# Grafana Init Container

This directory contains the Dockerfile and scripts for building the Grafana initialization container used in the Lakerunner CloudFormation deployment.

## Purpose

The init container handles three different modes of operation. The mode is
selected explicitly via the `MODE` environment variable
(`install-plugins`, `db-setup`, or `datasource-provisioning`). If `MODE` is
unset, the container falls back to legacy auto-detection based on which
environment variables are present.

### Plugin Install Mode (`MODE=install-plugins`)
- Copies plugins bundled into the image at `/opt/plugins` into the
  shared plugins volume (default `/var/lib/grafana/plugins`)
- Lets the Grafana container load the Cardinal datasource plugin at
  startup without an outbound HTTP download — useful for air-gapped
  clusters or reproducible deployments where the plugin version is
  pinned to the image tag.

### Database Setup Mode (`MODE=db-setup`)
- Creates PostgreSQL database for Grafana
- Creates dedicated database user with appropriate permissions
- Sets up schema permissions for Grafana to operate
- Also runs automatically (legacy) when database-related environment
  variables are present and `MODE` is unset.

### Datasource Provisioning Mode (`MODE=datasource-provisioning`)
- Setting up Grafana datasource provisioning directories
- Writing datasource configuration for the Cardinal Lakerunner plugin
- Implementing data reset functionality via reset tokens
- Ensuring proper filesystem permissions and directory structure

## Building the Image

To build and push the multi-architecture init container image:

```bash
# Login to ECR (if not already authenticated)
aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws

# Build and push multi-architecture image (AMD64 + ARM64)
./build.sh
```

For local development and testing:

```bash
# Build for current architecture only (for local testing)
docker buildx build --platform linux/amd64 --pull -t public.ecr.aws/cardinalhq.io/lakerunner/initcontainer-grafana:latest --load .
```

## Usage

This image is used automatically by the Grafana CloudFormation stack as an init container. It runs before the main Grafana container starts and sets up the necessary configuration.

## Environment Variables

### Plugin Install Mode
Used when pre-installing plugins into the shared Grafana plugins volume:
- `MODE`: Set to `install-plugins`
- `GF_PATHS_PLUGINS`: Destination plugins directory (default: `/var/lib/grafana/plugins`)

### Database Setup Mode
Required when setting up PostgreSQL for Grafana:
- `GRAFANA_DB_NAME`: Name of the database to create (e.g., "grafana")
- `GRAFANA_DB_USER`: Username for the Grafana database user (e.g., "grafana") 
- `GRAFANA_DB_PASSWORD`: Password for the Grafana database user
- `PGHOST`: PostgreSQL server hostname
- `PGUSER`: PostgreSQL admin username (with database creation privileges)
- `PGPASSWORD`: PostgreSQL admin password
- `PGPORT`: PostgreSQL port (optional, default: 5432)
- `PGDATABASE`: Admin database name (optional, default: postgres)
- `PGSSLMODE`: SSL mode (optional, default: require)

### Datasource Provisioning Mode  
Used when setting up Grafana datasources:
- `PROVISIONING_DIR`: Grafana provisioning directory (default: `/etc/grafana/provisioning`)
- `RESET_TOKEN`: Optional token to trigger Grafana data reset
- `GRAFANA_DATASOURCE_CONFIG`: YAML configuration for the Cardinal datasource

## Container Structure

The container follows CardinalHQ conventions:
- `/app/scripts/init-grafana.sh`: Main initialization script (entrypoint) - detects mode and delegates
- `/app/scripts/install-plugins.sh`: Copies bundled plugins into `GF_PATHS_PLUGINS`
- `/app/scripts/setup-grafana-db.sh`: Database setup script for PostgreSQL configuration
- `/opt/plugins/`: Plugins baked in at image build time (currently the Cardinal LakeRunner datasource)

## Volumes

The container needs access to these mounted volumes:

- `/var/lib/grafana`: Grafana data directory (for reset token file)
- `/etc/grafana/provisioning`: Grafana provisioning directory (to write datasource config)

## Air-gapped Deployment

This approach solves air-gapped deployment issues by:

1. Pre-building the init logic into a container image
2. Using PostgreSQL Alpine image as base for database operations and shell support
3. Eliminating the need to download packages at runtime
4. Providing a self-contained initialization solution for both database setup and datasource provisioning

## Operation Mode Detection

Mode selection is explicit via the `MODE` env var
(`install-plugins` | `db-setup` | `datasource-provisioning`).

If `MODE` is unset, the container falls back to legacy auto-detection:
- If `GRAFANA_DB_NAME`, `GRAFANA_DB_USER`, and `PGHOST` are all present, it runs in **Database Setup Mode**
- Otherwise, it runs in **Datasource Provisioning Mode**

Plugin Install Mode is never auto-detected and must be selected with
`MODE=install-plugins`.

## Build-time Plugin Version

The bundled Cardinal datasource plugin version is controlled by
`--build-arg CARDINAL_PLUGIN_VERSION=vX.Y.Z` (default in the Dockerfile).
Tag the built image with the same version (e.g. `initcontainer-grafana:v2.4.0`)
so chart releases can pin to a known plugin version.