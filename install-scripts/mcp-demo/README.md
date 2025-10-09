
# CardinalHQ MCP Demo

This demo provides a local, full-stack observability environment using CardinalHQ's Model Context Protocol (MCP) and Docker Compose. It simulates a real-world microservices system, generates telemetry data, and sends it to Cardinal for analysis and visualization.

## Demo Video

[Demo Video (click to watch)](https://framerusercontent.com/assets/aUTaNbHiOMSY84wnisevq6ubVI.mp4)

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Setup & Quick Start](#setup--quick-start)
- [How It Works](#how-it-works)
- [Managing the Demo](#managing-the-demo)
- [Troubleshooting](#troubleshooting)
- [Getting Help](#getting-help)

## Overview

This demo launches a set of microservices (OpenTelemetry Demo App, aka otel-demo) and observability tools using Docker Compose. It is designed to:

- Generate realistic telemetry data (logs, metrics, traces)
- Collect and process data using OpenTelemetry Collector
- Forward data to Cardinal for visualization and analysis

You can use this environment to explore observability, test integrations, and see CardinalHQ in action.

### Producing and Testing Telemetry Data

The otel-demo app is set up to produce telemetry data automatically. You can also visit [http://localhost:8080/feature](http://localhost:8080/feature) in your browser to configure the demo app to generate specific errors or failures. This allows you to test how errors and failures are captured and visualized in Cardinal.

## Architecture

The stack includes:

- **OpenTelemetry Demo App**: Simulates a real-world microservices system and produces telemetry data
- **OpenTelemetry Collector**: Aggregates and exports telemetry
- **Grafana**: For local visualization
- **CardinalHQ Integration**: Sends all telemetry to your Cardinal account

All services and dependencies are defined in [`docker-compose.yaml`](./docker-compose.yaml).

## Prerequisites

- [Docker](https://www.docker.com/get-started) (with Compose plugin or `docker-compose`)
- A CardinalHQ account and API key ([sign up here](https://app.cardinalhq.io))

## Setup & Quick Start

1. **Clone the repository**

  ```bash
  git clone https://github.com/cardinalhq/charts.git
  cd charts/install-scripts/mcp-demo
  ```

2. **Run the demo**

  The `run.sh` script will check prerequisites, prompt for your Cardinal API key (or use the `LAKERUNNER_CARDINAL_APIKEY` environment variable), and start all services:

  ```bash
  ./run.sh
  ```

- To skip the prompt, set the API key in your environment:

   ```bash
   export LAKERUNNER_CARDINAL_APIKEY="your-api-key-here"
   ./run.sh
   ```

- Or run in a single command:

   ```bash
   LAKERUNNER_CARDINAL_APIKEY="your-api-key-here" ./run.sh
   ```

- On Windows, use Git Bash or WSL for best results.

3. **Access the Cardinal Dashboard**

- Go to [https://app.cardinalhq.io](https://app.cardinalhq.io)
- Log in with your account
- Telemetry data will appear within a few minutes

## How It Works

The `run.sh` script:

- Checks for Docker and Docker Compose
- Prompts for your Cardinal API key (or uses the environment variable)
- Exports the API key for use by Docker Compose
- Starts all services in the background
- Prints instructions for viewing logs, stopping services, and connecting MCP clients

The main services are defined in [`docker-compose.yaml`](./docker-compose.yaml). The stack includes application services, telemetry generators, OpenTelemetry Collector, and Grafana for visualization.

## Managing the Demo

- **View logs:**

 ```bash
 docker compose logs -f
 ```

- **Stop the demo:**

 ```bash
 docker compose down
 ```

- **Stop and remove all data:**

 ```bash
 docker compose down -v
 ```

## Troubleshooting

- **Docker Not Found:**
  - Install Docker from [docker.com/get-started](https://www.docker.com/get-started)
- **Docker Daemon Not Running:**
  - Start Docker Desktop or the Docker service
- **Permission Denied on run.sh:**
  - Make it executable: `chmod +x run.sh`
- **API Key Issues:**
  - Ensure your API key is valid and active (create/manage at [app.cardinalhq.io](https://app.cardinalhq.io))
