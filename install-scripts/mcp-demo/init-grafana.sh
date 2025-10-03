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

# Return the service account id by name/login
get_sa_id() {
    api_get "$GRAFANA_URL/api/serviceaccounts/search?perpage=100&page=1&query=$SA_NAME" \
    | jq -r --arg n "$SA_NAME" '.serviceAccounts[] | select(.name==$n or .login==$n or .login=="sa-"+$n) | .id' \
    | head -n1
}

# If a token with TOKEN_NAME already exists, delete it
delete_existing_token() {
    local tokens
    tokens=$(api_get "$GRAFANA_URL/api/serviceaccounts/$SA_ID/tokens" || echo "[]")
    local existing_id
    existing_id=$(echo "$tokens" | jq -r --arg n "$TOKEN_NAME" '.[] | select(.name==$n) | .id' | head -n1)
    if [ -n "${existing_id:-}" ] && [ "$existing_id" != "null" ]; then
        curl -s -X DELETE "$GRAFANA_URL/api/serviceaccounts/$SA_ID/tokens/$existing_id" >/dev/null
    fi
}

# Create or get service account (idempotent; handles 400 ErrAlreadyExists)
create_service_account() {
    local result http_code response
    result=$(api_post "$GRAFANA_URL/api/serviceaccounts" "{\"name\":\"$SA_NAME\",\"role\":\"Admin\"}")
    http_code=$(echo "$result" | cut -d'|' -f1)
    response=$(echo "$result" | cut -d'|' -f2-)

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        SA_ID=$(echo "$response" | jq -r '.id // empty')
    elif [ "$http_code" = "409" ] || { [ "$http_code" = "400" ] && echo "$response" | jq -e '.messageId=="serviceaccounts.ErrAlreadyExists"' >/dev/null 2>&1; }; then
        # Already exists — look it up
        SA_ID="$(get_sa_id)"
    else
        echo "Failed to create service account (HTTP $http_code): $response"
        exit 1
    fi

    if [ -z "${SA_ID:-}" ] || [ "$SA_ID" = "null" ]; then
        # Fallback: try lookup again, just in case
        SA_ID="$(get_sa_id)"
    fi

    if [ -z "${SA_ID:-}" ] || [ "$SA_ID" = "null" ]; then
        echo "Failed to get service account ID for name: $SA_NAME"
        exit 1
    fi
}


# Create service account token (idempotent by deleting same-named token first)
create_token() {
    # Ensure we don't collide on name
    delete_existing_token

    local result http_code response
    result=$(api_post "$GRAFANA_URL/api/serviceaccounts/$SA_ID/tokens" "{\"name\":\"$TOKEN_NAME\",\"secondsToLive\":604800}")
    http_code=$(echo "$result" | cut -d'|' -f1)
    response=$(echo "$result" | cut -d'|' -f2-)

    # If server still says "already exists", delete & recreate once more
    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
        if echo "$response" | jq -e '.messageId=="serviceaccounts.ErrTokenExists" or .message|test("already exists"; "i")' >/dev/null 2>&1; then
            delete_existing_token
            result=$(api_post "$GRAFANA_URL/api/serviceaccounts/$SA_ID/tokens" "{\"name\":\"$TOKEN_NAME\",\"secondsToLive\":604800}")
            http_code=$(echo "$result" | cut -d'|' -f1)
            response=$(echo "$result" | cut -d'|' -f2-)
        fi
    fi

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
