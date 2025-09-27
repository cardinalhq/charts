#!/bin/sh
set -euo pipefail

# Default values
DEFAULT_USER="admin"
DEFAULT_PASS="admin"
DEFAULT_HOST="grafana:3000"
DEFAULT_ORG_NAME=""
DEFAULT_SA_NAME="chip2"
DEFAULT_TOKEN_NAME="chip2-token"
DEFAULT_MAX_RETRIES=30
DEFAULT_RETRY_DELAY=2

# Parse CLI arguments and environment variables
USER="${1:-${GRAFANA_USER:-$DEFAULT_USER}}"
PASS="${2:-${GRAFANA_PASS:-$DEFAULT_PASS}}"
HOST="${3:-${GRAFANA_HOST:-$DEFAULT_HOST}}"
ORG_NAME="${GRAFANA_ORG_NAME:-$DEFAULT_ORG_NAME}"
SA_NAME="${GRAFANA_SA_NAME:-$DEFAULT_SA_NAME}"
TOKEN_NAME="${GRAFANA_TOKEN_NAME:-$DEFAULT_TOKEN_NAME}"
MAX_RETRIES="${GRAFANA_MAX_RETRIES:-$DEFAULT_MAX_RETRIES}"
RETRY_DELAY="${GRAFANA_RETRY_DELAY:-$DEFAULT_RETRY_DELAY}"

GRAFANA_URL="http://$USER:$PASS@$HOST"

# Check dependencies
if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required but not installed"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not installed"
    exit 1
fi

api_post() {
    local url="$1"
    local data="$2"
    local temp_file
    temp_file=$(mktemp)

    local http_code
    http_code=$(curl -s -w "%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "$data" \
        "$url" \
        -o "$temp_file") || { rm -f "$temp_file"; return 1; }

    local response
    response=$(cat "$temp_file") || { rm -f "$temp_file"; return 1; }
    rm -f "$temp_file"

    echo "$http_code|$response"
}

api_post_simple() {
    local url="$1"
    local temp_file
    temp_file=$(mktemp)

    local http_code
    http_code=$(curl -s -w "%{http_code}" -X POST \
        "$url" \
        -o "$temp_file") || { rm -f "$temp_file"; return 1; }

    local response
    response=$(cat "$temp_file") || { rm -f "$temp_file"; return 1; }
    rm -f "$temp_file"

    echo "$http_code|$response"
}

# Helper function for GET requests
api_get() {
    local url="$1"
    curl -s "$url" || return 1
}

# Retry function with exponential backoff
retry_until_ready() {
    local retries=0
    local delay=$RETRY_DELAY

    while [ $retries -lt $MAX_RETRIES ]; do
        local http_code=$(curl -s -w "%{http_code}" -o /dev/null "$GRAFANA_URL/api/health")

        if [ "$http_code" = "200" ]; then
            return 0
        fi

        retries=$((retries + 1))
        sleep $delay
        delay=$((delay * 2))
        if [ $delay -gt 30 ]; then
            delay=30
        fi
    done

    echo "Grafana not ready after $MAX_RETRIES attempts"
    exit 1
}

# Create or get organization
create_org() {
    # If no org name specified, use the default organization (ID = 1)
    if [ -z "$ORG_NAME" ]; then
        ORG_ID=1
        echo "Using default organization (ID: $ORG_ID)"
        return
    fi

    # Try to create the specified organization
    local result
    result=$(api_post "$GRAFANA_URL/api/orgs" "{\"name\":\"$ORG_NAME\"}")
    local http_code
    http_code=$(echo "$result" | cut -d'|' -f1)
    local response
    response=$(echo "$result" | cut -d'|' -f2-)

    if [ "$http_code" = "409" ]; then
        # Organization already exists, get its ID
        local orgs_result
        orgs_result=$(api_get "$GRAFANA_URL/api/orgs")
        ORG_ID=$(echo "$orgs_result" | jq -r ".[] | select(.name==\"$ORG_NAME\") | .id")
    elif [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        # Organization created successfully
        ORG_ID=$(echo "$response" | jq -r '.orgId // empty')
    else
        echo "Failed to create org (HTTP $http_code): $response"
        exit 1
    fi

    if [ -z "$ORG_ID" ] || [ "$ORG_ID" = "null" ]; then
        echo "Failed to get org ID for: $ORG_NAME"
        exit 1
    fi
}

# Switch admin user to organization
switch_to_org() {
    local result
    result=$(api_post_simple "$GRAFANA_URL/api/user/using/$ORG_ID")
    local http_code
    http_code=$(echo "$result" | cut -d'|' -f1)

    if [ "$http_code" != "200" ]; then
        echo "Failed to switch admin to org (HTTP $http_code)"
        exit 1
    fi
}

# Create or get service account
create_service_account() {
    local result
    result=$(api_post "$GRAFANA_URL/api/serviceaccounts" "{\"name\":\"$SA_NAME\",\"role\":\"Admin\"}")
    local http_code
    http_code=$(echo "$result" | cut -d'|' -f1)
    local response
    response=$(echo "$result" | cut -d'|' -f2-)

    if [ "$http_code" = "409" ]; then
        local sa_result
        sa_result=$(api_get "$GRAFANA_URL/api/serviceaccounts")
        SA_ID=$(echo "$sa_result" | jq -r ".serviceAccounts[] | select(.name==\"$SA_NAME\") | .id")
    elif [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        SA_ID=$(echo "$response" | jq -r '.id // empty')
    else
        echo "Failed to create service account (HTTP $http_code): $response"
        exit 1
    fi

    if [ -z "$SA_ID" ] || [ "$SA_ID" = "null" ]; then
        echo "Failed to get service account ID"
        exit 1
    fi
}

# Create service account token
create_token() {
    local result
    result=$(api_post "$GRAFANA_URL/api/serviceaccounts/$SA_ID/tokens" "{\"name\":\"$TOKEN_NAME\"}")
    local http_code
    http_code=$(echo "$result" | cut -d'|' -f1)
    local response
    response=$(echo "$result" | cut -d'|' -f2-)

    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
        echo "Failed to create service account token (HTTP $http_code): $response"
        exit 1
    fi

    TOKEN=$(echo "$response" | jq -r '.key // empty')
    if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
        echo "Failed to get token from response: $response"
        exit 1
    fi

    echo "$TOKEN"

    # Write token to shared volume for other services
    if [ -d "/tmp/tokens" ]; then
        echo "$TOKEN" > /tmp/tokens/grafana-service-account-token
        echo "Token written to shared volume"
    fi
}

retry_until_ready
create_org
switch_to_org
create_service_account
create_token