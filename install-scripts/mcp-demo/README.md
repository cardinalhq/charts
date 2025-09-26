# MCP Demo

This demo showcases CardinalHQ's telemetry processing capabilities using Docker Compose to run a complete observability stack locally.

## Prerequisites

- Docker and Docker Compose installed on your machine
- A Cardinal account and API key (sign up at [app.cardinalhq.io](https://app.cardinalhq.io))

## Quick Start

### 1. Get the Demo

Choose one of the following methods:

#### Option A: Clone the repository

```bash
git clone https://github.com/cardinalhq/charts.git
cd charts/install-scripts/mcp-demo
```

#### Option B: Download as ZIP

Download and extract the repository:

- [Download ZIP](https://github.com/cardinalhq/charts/archive/refs/heads/main.zip)
- Extract the ZIP file
- Navigate to `charts-main/install-scripts/mcp-demo/`

### 2. Run the Demo

#### Interactive Mode

Run the script and follow the prompts:

```bash
./run.sh
```

The script will:

1. Check that Docker is installed and running
2. Prompt you for your Cardinal API key (if not already set)
3. Start all demo services in the background
4. Display instructions for managing the demo

#### Non-Interactive Mode

To skip the API key prompt, set the environment variable first:

```bash
export LAKERUNNER_CARDINAL_APIKEY="your-api-key-here"
./run.sh
```

Or run it in a single command:

```bash
LAKERUNNER_CARDINAL_APIKEY="your-api-key-here" ./run.sh
```

## What's Running

The demo starts several Docker containers that:

- Generate sample telemetry data (logs, metrics, and traces)
- Collect and process the telemetry using OpenTelemetry
- Send processed data to Cardinal for analysis and visualization

## Viewing Your Data

Once the demo is running:

1. Go to [app.cardinalhq.io](https://app.cardinalhq.io)
2. Log in with your Cardinal account
3. Your telemetry data will begin appearing within a few minutes

## Managing the Demo

### View Logs

```bash
docker compose logs -f
```

### Stop the Demo

```bash
docker compose down
```

### Stop and Remove All Data

```bash
docker compose down -v
```

## Troubleshooting

### Docker Not Found

If you get a "Docker is not installed" error, install Docker from [docker.com/get-started](https://www.docker.com/get-started)

### Docker Daemon Not Running

If you get a "Docker daemon is not running" error, start the Docker application on your system.

### Permission Denied

If you get a permission error running `run.sh`, make it executable:

```bash
chmod +x run.sh
```

### API Key Issues

- Ensure your API key is valid and active
- API keys can be created at [app.cardinalhq.io](https://app.cardinalhq.io) in the API Keys section

## Getting Help

For issues or questions:

- Visit the [CardinalHQ Charts repository](https://github.com/cardinalhq/charts)
- Check the [Issues page](https://github.com/cardinalhq/charts/issues)
- Contact CardinalHQ support
