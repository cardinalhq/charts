#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

get_cardinal_api_key() {
    if [ -n "$LAKERUNNER_CARDINAL_APIKEY" ]; then
        CARDINAL_API_KEY="$LAKERUNNER_CARDINAL_APIKEY"
        print_status "Using Cardinal API key from LAKERUNNER_CARDINAL_APIKEY environment variable"
        return 0
    fi

    echo
    echo "=== Cardinal API Key Required ==="
    echo
    print_status "To run the MCP demo, you need to create a Cardinal API key."
    print_status "Please follow these steps:"
    echo
    print_status "1. Open your browser and go to: ${BLUE}https://app.cardinalhq.io${NC}"
    print_status "2. Sign up or log in to your account"
    print_status "3. Navigate to the API Keys section"
    print_status "4. Create a new API key"
    print_status "5. Copy the API key"
    echo
    print_warning "The API key will be used for this demo session only."
    echo

    while true; do
        read -s -p "Enter your Cardinal API key: " api_key
        echo

        if [[ -n "$api_key" ]]; then
            # Validate API key format (basic check)
            if [[ "$api_key" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                CARDINAL_API_KEY="$api_key"
                break
            else
                print_error "Invalid API key format. Please enter a valid API key."
            fi
        else
            print_error "API key cannot be empty. Please enter a valid API key."
        fi
    done
}

check_prerequisites() {
    print_status "Checking prerequisites..."

    if ! command_exists docker; then
        print_error "Docker is not installed or not in PATH"
        echo "Please install Docker from https://www.docker.com/get-started"
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        print_error "Docker daemon is not running"
        echo "Please start Docker and try again"
        exit 1
    fi

    if ! command_exists docker-compose && ! docker compose version >/dev/null 2>&1; then
        print_error "Docker Compose is not available"
        echo "Please ensure Docker Compose is installed"
        exit 1
    fi

    print_success "All prerequisites are satisfied"
}

main() {
    echo "=========================================="
    echo "    MCP Demo Run Script"
    echo "=========================================="
    echo

    check_prerequisites

    # Get Cardinal API key
    get_cardinal_api_key

    # Export the API key for docker-compose
    export LAKERUNNER_CARDINAL_APIKEY="$CARDINAL_API_KEY"

    # Change to the mcp-demo directory
    cd "$(dirname "$0")" || exit 1

    print_status "Starting MCP demo services..."
    echo

    # Run docker-compose
    print_status "Using Cardinal API key: ${LAKERUNNER_CARDINAL_APIKEY:0:10}..."
    if docker compose version >/dev/null 2>&1; then
        # Modern docker with compose subcommand
        LAKERUNNER_CARDINAL_APIKEY="$LAKERUNNER_CARDINAL_APIKEY" docker compose up --force-recreate --remove-orphans --detach
    else
        # Legacy docker-compose command
        LAKERUNNER_CARDINAL_APIKEY="$LAKERUNNER_CARDINAL_APIKEY" docker-compose up --force-recreate --remove-orphans --detach
    fi

    if [ $? -eq 0 ]; then
        echo
        print_success "MCP demo is now running in the background!"
        echo
        echo "=== Access Information ==="
        echo
        echo "Cardinal Dashboard:"
        echo "  URL: https://app.cardinalhq.io"
        echo "  Log in with your Cardinal account to view the telemetry data"
        echo
        echo "=== Managing the Demo ==="
        echo
        echo "View logs:"
        echo "  docker compose logs -f"
        echo
        echo "Stop the demo:"
        echo "  docker compose down"
        echo
        echo "Stop and remove all data:"
        echo "  docker compose down -v"
        echo
        echo "=== MCP Client Configuration ==="
        echo
        echo "To start asking questions about the demo app data, add this to your MCP client config:"
        echo "(For Claude Desktop, add to your claude_desktop_config.json file)"
        echo
        echo "{"
        echo "  \"mcpServers\": {"
        echo "    \"chip\": {"
        echo "      \"command\": \"npx\","
        echo "      \"args\": ["
        echo "        \"-y\","
        echo "        \"mcp-remote\","
        echo "        \"http://localhost:3001/mcp\","
        echo "        \"--header\","
        echo "        \"x-cardinalhq-api-key: $LAKERUNNER_CARDINAL_APIKEY\""
        echo "      ]"
        echo "    }"
        echo "  }"
        echo "}"
        echo
        print_status "The demo is generating telemetry data that will appear in Cardinal within a few minutes."
    else
        print_error "Failed to start MCP demo services"
        exit 1
    fi
}

main "$@"