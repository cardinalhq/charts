#!/bin/bash
# Copyright 2025 CardinalHQ, Inc
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# Lakerunner Install Script
# This script installs Lakerunner with local MinIO and PostgreSQL

# Grafana plugin version
GRAFANA_PLUGIN_VERSION="v2.0.3"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

print_success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
}

print_warning() {
    printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
}

print_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Helper function to conditionally redirect output based on verbose flag
output_redirect() {
    if [ "$VERBOSE" = true ]; then
        cat  # Show output when verbose
    else
        cat >/dev/null 2>&1  # Hide output when not verbose
    fi
}

# Progress indicator function
show_progress() {
    local message="$1"
    local command="$2"
    local timeout="${3:-300}"  # Default 5 minutes

    if [ "$VERBOSE" = true ]; then
        # In verbose mode, just run the command normally
        print_status "$message..."
        eval "$command"
        local exit_code=$?
        if [ $exit_code -eq 0 ]; then
            print_success "$message completed"
        else
            print_error "$message failed"
        fi
        return $exit_code
    fi

    # Start the command in background, redirecting all output
    eval "$command" >/dev/null 2>&1 &
    local cmd_pid=$!

    # Show spinner while command runs
    local spinner_chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local spinner_len=${#spinner_chars}
    local i=0
    local elapsed=0

    while kill -0 $cmd_pid 2>/dev/null; do
        local char=${spinner_chars:$((i % spinner_len)):1}
        printf "\r${BLUE}[INFO]${NC} %s %s (%ds)" "$message" "$char" "$elapsed"
        sleep 1
        i=$((i + 1))
        elapsed=$((elapsed + 1))

        # Check timeout
        if [ $elapsed -ge $timeout ]; then
            kill $cmd_pid 2>/dev/null
            printf "\r${RED}[ERROR]${NC} %s - timed out after %ds\n" "$message" "$timeout"
            return 1
        fi
    done

    # Wait for command to finish and get exit code
    wait $cmd_pid
    local exit_code=$?

    # Clear the progress line and show final status
    printf "\r\033[K"

    if [ $exit_code -eq 0 ]; then
        print_success "$message completed"
    else
        print_error "$message failed"
    fi

    return $exit_code
}

# Wait for pods function that handles non-existent pods
wait_for_pods() {
    local message="$1"
    local selector="$2"
    local namespace="$3"
    local timeout="${4:-300}"

    if [ "$VERBOSE" = true ]; then
        print_status "$message..."
    fi

    local elapsed=0
    local spinner_chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local spinner_len=${#spinner_chars}
    local i=0

    while [ $elapsed -lt $timeout ]; do
        # Check if any pods exist with the selector
        local pod_count=$(kubectl get pods -l "$selector" -n "$namespace" --no-headers 2>/dev/null | wc -l)

        if [ "$pod_count" -gt 0 ]; then
            # Pods exist, now wait for them to be ready
            if [ "$VERBOSE" != true ]; then
                printf "\r\033[K"  # Clear spinner line
            fi

            if kubectl wait --for=condition=ready pod -l "$selector" -n "$namespace" --timeout=$((timeout - elapsed))s >/dev/null 2>&1; then
                if [ "$VERBOSE" != true ]; then
                    print_success "$message completed"
                else
                    print_success "$message"
                fi
                return 0
            else
                if [ "$VERBOSE" != true ]; then
                    print_error "$message failed - pods found but not ready"
                else
                    print_error "$message failed"
                fi
                return 1
            fi
        fi

        # Show spinner only in non-verbose mode
        if [ "$VERBOSE" != true ]; then
            local char=${spinner_chars:$((i % spinner_len)):1}
            printf "\r${BLUE}[INFO]${NC} %s %s (%ds)" "$message" "$char" "$elapsed"
        fi

        sleep 1
        i=$((i + 1))
        elapsed=$((elapsed + 1))
    done

    # Timeout reached
    if [ "$VERBOSE" != true ]; then
        printf "\r${RED}[ERROR]${NC} %s - timed out after %ds (no pods found)\n" "$message" "$timeout"
    else
        print_error "$message - timed out after ${timeout}s (no pods found)"
    fi
    return 1
}

check_prerequisites() {
    print_status "Checking prerequisites..."

    local missing_deps=()

    if ! command_exists kubectl; then
        missing_deps+=("kubectl")
    fi

    if ! command_exists helm; then
        missing_deps+=("helm")
    fi

    if ! command_exists base64; then
        missing_deps+=("base64")
    fi

    if ! command_exists curl; then
        missing_deps+=("curl")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        echo "Please install the missing dependencies and try again."
        echo "Installation guides:"
        echo "  - kubectl: https://kubernetes.io/docs/tasks/tools/"
        echo "  - helm: https://helm.sh/docs/intro/install/"
        echo "  - curl: Usually pre-installed on most systems"
        exit 1
    fi

    if ! kubectl cluster-info >/dev/null 2>&1; then
        print_error "Cannot connect to Kubernetes cluster. Please ensure:"
        echo "  1. You have a Kubernetes cluster running (minikube, kind, etc.)"
        echo "  2. kubectl is configured to connect to your cluster"
        echo "  3. You have the necessary permissions"
        exit 1
    fi

    print_success "All prerequisites are satisfied"
}

check_helm_repositories() {
    if [ "$SKIP_HELM_REPO_UPDATES" != true ]; then
        return 0  # Skip this check if we're going to add/update repos anyway
    fi

    print_status "Pre-flight check: Verifying required helm repositories..."

    local missing_repos=()
    local found_repos=()
    local needed_repos=()

    # Determine which repositories we need based on configuration
    if [ "$INSTALL_MINIO" = true ]; then
        needed_repos+=("minio https://charts.min.io/")
    fi

    # Kafka uses raw manifests now, no helm repo needed

    if [ "$INSTALL_OTEL_DEMO" = true ]; then
        needed_repos+=("open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts")
    fi

    # If no repositories are needed, skip the check
    if [ ${#needed_repos[@]} -eq 0 ]; then
        print_status "No helm repositories required for current configuration"
        return 0
    fi

    # Check each needed repository
    for repo_info in "${needed_repos[@]}"; do
        repo_name=$(echo "$repo_info" | cut -d' ' -f1)
        repo_url=$(echo "$repo_info" | cut -d' ' -f2)

        if helm repo list 2>/dev/null | grep -q "$repo_name.*$repo_url"; then
            found_repos+=("$repo_name")
        else
            missing_repos+=("$repo_info")
        fi
    done

    # Report found repositories
    if [ ${#found_repos[@]} -gt 0 ]; then
        print_success "Found required helm repositories: ${found_repos[*]}"
    fi

    # Report missing repositories and fail if any are missing
    if [ ${#missing_repos[@]} -gt 0 ]; then
        print_error "Missing required helm repositories when --skip-helm-repo-updates is enabled:"
        for repo in "${missing_repos[@]}"; do
            repo_name=$(echo "$repo" | cut -d' ' -f1)
            repo_url=$(echo "$repo" | cut -d' ' -f2)
            echo "  helm repo add $repo_name $repo_url"
        done
        echo
        print_error "Please add the missing repositories and try again, or run without --skip-helm-repo-updates"
        exit 1
    fi

    print_success "All required helm repositories are available"
}

get_input() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"

    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " input
        if [ -z "$input" ]; then
            input="$default"
        fi
    else
        read -p "$prompt: " input
    fi

    eval "$var_name=\"$input\""
}

get_namespace() {
    local default_namespace="lakerunner-demo"

    echo
    echo "=== Namespace Configuration ==="
    echo "Lakerunner will be installed in a Kubernetes namespace."

    get_input "Enter namespace for Lakerunner installation" "$default_namespace" "NAMESPACE"
}

get_infrastructure_preferences() {
    echo
    echo "=== Infrastructure Configuration ==="
    echo "Lakerunner needs a PostgreSQL database and S3-compatible storage."
    echo "You can use local installations or connect to existing infrastructure."
    echo

    get_input "Do you want to install PostgreSQL locally? (Y/n)" "Y" "INSTALL_POSTGRES"
    if [[ "$INSTALL_POSTGRES" =~ ^[Yy]$ ]] || [ -z "$INSTALL_POSTGRES" ]; then
        INSTALL_POSTGRES=true
        print_status "Will install PostgreSQL locally"
    else
        INSTALL_POSTGRES=false
        print_status "Will use existing PostgreSQL"
        get_input "Enter PostgreSQL host" "" "POSTGRES_HOST"
        get_input "Enter PostgreSQL port" "5432" "POSTGRES_PORT"
        get_input "Enter PostgreSQL database name" "lakerunner" "POSTGRES_DB"
        get_input "Enter PostgreSQL username" "lakerunner" "POSTGRES_USER"
        get_input "Enter PostgreSQL password" "" "POSTGRES_PASSWORD"
    fi

    get_input "Do you want to install MinIO locally? (Y/n)" "Y" "INSTALL_MINIO"
    if [[ "$INSTALL_MINIO" =~ ^[Yy]$ ]] || [ -z "$INSTALL_MINIO" ]; then
        INSTALL_MINIO=true
        print_status "Will install MinIO locally"
    else
        INSTALL_MINIO=false
        print_status "Will use existing S3-compatible storage"
        get_input "Enter S3 access key" "" "S3_ACCESS_KEY"
        get_input "Enter S3 secret key" "" "S3_SECRET_KEY"
        get_input "Enter S3 region" "us-east-1" "S3_REGION"
        get_input "Enter S3 bucket name" "lakerunner" "S3_BUCKET"

    fi

    get_input "Do you want to install Kafka locally? (Y/n)" "Y" "INSTALL_KAFKA"
    if [[ "$INSTALL_KAFKA" =~ ^[Yy]$ ]] || [ -z "$INSTALL_KAFKA" ]; then
        INSTALL_KAFKA=true
        print_status "Will install Kafka locally"
    else
        INSTALL_KAFKA=false
        print_status "Will use existing Kafka"
        get_input "Enter Kafka bootstrap servers" "localhost:9092" "KAFKA_BOOTSTRAP_SERVERS"
        get_input "Enter Kafka username (leave empty if no auth)" "" "KAFKA_USERNAME"
        if [ -n "$KAFKA_USERNAME" ]; then
            get_input "Enter Kafka password" "" "KAFKA_PASSWORD"
        fi
    fi

    echo
    echo "=== SQS Configuration (Optional) ==="
    if [ "$INSTALL_MINIO" = true ]; then
        echo "Note: SQS is not needed when using local MinIO. HTTP webhook is sufficient."
        echo "SQS is recommended for production AWS S3 deployments."
        echo
        USE_SQS=false
        print_status "Will use HTTP webhook for event notifications"
    else
        echo "Note: For external S3 storage, you can use either:"
        echo "1. HTTP webhook (simpler, works with any S3-compatible storage)"
        echo "2. SQS queue (recommended for production AWS S3)"
        echo

        get_input "Do you want to configure SQS for event notifications? (y/N)" "N" "USE_SQS"
        if [[ "$USE_SQS" =~ ^[Yy]$ ]]; then
            USE_SQS=true
            print_status "Will configure SQS for event notifications"

            get_input "Enter SQS queue URL" "" "SQS_QUEUE_URL"
            get_input "Enter SQS region" "$S3_REGION" "SQS_REGION"

            echo
            echo "=== SQS Setup Instructions ==="
            echo "You'll need to manually configure:"
            echo "1. S3 bucket notifications to send events to your SQS queue"
            echo "2. SQS queue policy to allow S3 to send messages"
            echo "3. IAM permissions for Lakerunner to read from SQS"
            echo
            echo "For detailed setup instructions, visit:"
            echo "https://github.com/cardinalhq/lakerunner"
            echo
            read -p "Press Enter to continue..."
        else
            USE_SQS=false
            print_status "Will use HTTP webhook for event notifications"
        fi
    fi
}

get_telemetry_preferences() {
    echo
    echo "=== Telemetry Configuration ==="
    echo "Lakerunner can process logs, metrics, and traces."
    echo "Choose which telemetry types you want to enable:"
    echo

    get_input "Enable logs processing? (Y/n)" "Y" "ENABLE_LOGS_CHOICE"
    if [[ "$ENABLE_LOGS_CHOICE" =~ ^[Yy]$ ]] || [ -z "$ENABLE_LOGS_CHOICE" ]; then
        ENABLE_LOGS=true
        print_status "Will enable logs processing"
    else
        ENABLE_LOGS=false
        print_status "Will disable logs processing"
    fi

    get_input "Enable metrics processing? (Y/n)" "Y" "ENABLE_METRICS_CHOICE"
    if [[ "$ENABLE_METRICS_CHOICE" =~ ^[Yy]$ ]] || [ -z "$ENABLE_METRICS_CHOICE" ]; then
        ENABLE_METRICS=true
        print_status "Will enable metrics processing"
    else
        ENABLE_METRICS=false
        print_status "Will disable metrics processing"
    fi

    get_input "Enable traces processing? (Y/n)" "Y" "ENABLE_TRACES_CHOICE"
    if [[ "$ENABLE_TRACES_CHOICE" =~ ^[Yy]$ ]] || [ -z "$ENABLE_TRACES_CHOICE" ]; then
        ENABLE_TRACES=true
        print_status "Will enable traces processing"
    else
        ENABLE_TRACES=false
        print_status "Will disable traces processing"
    fi

    # Ensure at least one telemetry type is enabled
    if [ "$ENABLE_LOGS" = false ] && [ "$ENABLE_METRICS" = false ] && [ "$ENABLE_TRACES" = false ]; then
        print_warning "At least one telemetry type must be enabled. Enabling all three."
        ENABLE_LOGS=true
        ENABLE_METRICS=true
        ENABLE_TRACES=true
    fi

}

get_lakerunner_credentials() {
    echo
    echo "=== Lakerunner Credentials ==="
    echo "Lakerunner needs an organization ID and API key for authentication."
    echo

    get_input "Enter organization ID (or press Enter for default)" "151f346b-967e-4c94-b97a-581898b5b457" "ORG_ID"
    get_input "Enter API key (or press Enter for default)" "test-key" "API_KEY"
}


generate_random_string() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
    else
        cat /dev/urandom 2>/dev/null | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1
    fi
}

install_minio() {
    if [ "$INSTALL_MINIO" = true ]; then
        print_status "Installing MinIO..."

        if helm list -n "$NAMESPACE" -q | grep -q "^minio$"; then
            print_warning "MinIO is already installed. Skipping..."
            return
        fi

        if [ "$SKIP_HELM_REPO_UPDATES" != true ]; then
            helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
            helm repo update >/dev/null 2>&1
        fi

        helm install minio minio/minio \
            --namespace "$NAMESPACE" \
            --set mode=standalone \
            --set replicas=1 \
            --set persistence.enabled=true \
            --set persistence.size=10Gi \
            --set rootUser=minioadmin \
            --set rootPassword=minioadmin \
            --set "buckets[0].name=lakerunner" \
            --set "buckets[0].policy=none" \
            --set resources.requests.memory=512Mi \
            --set resources.requests.cpu=100m \
            --set consoleService.type=ClusterIP \
            --set service.type=ClusterIP | output_redirect

        wait_for_pods "Waiting for MinIO to be ready" "app=minio" "$NAMESPACE" 300

        print_success "MinIO installed successfully"
    else
        print_status "Skipping MinIO installation (using existing S3 storage)"
    fi
}

generate_postgres_manifests() {
    print_status "Generating PostgreSQL manifests..."

    mkdir -p generated

    cat > generated/postgres-manifests.yaml << 'EOF'
---
# ConfigMap with init script to create databases
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init
data:
  init-db.sql: |
    -- Create lakerunner database (main operational database)
    SELECT 'CREATE DATABASE lakerunner' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'lakerunner')\gexec
    -- Create configdb database (configuration storage)
    SELECT 'CREATE DATABASE configdb' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'configdb')\gexec
    -- Create grafana database (Grafana state storage)
    SELECT 'CREATE DATABASE grafana' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'grafana')\gexec
---
# Secret with PostgreSQL credentials
apiVersion: v1
kind: Secret
metadata:
  name: pg-credentials
type: Opaque
stringData:
  username: lakerunner
  password: lakerunnerpass
  postgres-password: lakerunnerpass
---
# Service for PostgreSQL
apiVersion: v1
kind: Service
metadata:
  name: postgres
  labels:
    app: postgres
spec:
  type: ClusterIP
  ports:
    - port: 5432
      targetPort: 5432
      protocol: TCP
      name: postgresql
  selector:
    app: postgres
---
# StatefulSet for PostgreSQL
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  labels:
    app: postgres
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
              name: postgresql
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: pg-credentials
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: pg-credentials
                  key: password
            - name: POSTGRES_DB
              value: lakerunner
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data
            - name: init-scripts
              mountPath: /docker-entrypoint-initdb.d
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          livenessProbe:
            exec:
              command:
                - pg_isready
                - -U
                - lakerunner
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            exec:
              command:
                - pg_isready
                - -U
                - lakerunner
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: init-scripts
          configMap:
            name: postgres-init
  volumeClaimTemplates:
    - metadata:
        name: postgres-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 8Gi
EOF

    print_success "PostgreSQL manifests generated"
}

install_postgresql() {
    if [ "$INSTALL_POSTGRES" = true ]; then
        print_status "Installing PostgreSQL..."

        # Check if PostgreSQL is already installed
        if kubectl get statefulset postgres -n "$NAMESPACE" >/dev/null 2>&1; then
            print_warning "PostgreSQL is already installed. Skipping..."
            return
        fi

        # Generate and apply manifests
        generate_postgres_manifests

        kubectl apply -f generated/postgres-manifests.yaml -n "$NAMESPACE" | output_redirect

        wait_for_pods "Waiting for PostgreSQL to be ready" "app=postgres" "$NAMESPACE" 300

        print_success "PostgreSQL installed successfully"
    else
        print_status "Skipping PostgreSQL installation (using existing database)"
    fi
}

generate_redpanda_manifests() {
    print_status "Generating Redpanda manifests..."

    mkdir -p generated

    cat > generated/redpanda-manifests.yaml << 'EOF'
---
# Headless service for StatefulSet DNS (required for pod DNS resolution)
apiVersion: v1
kind: Service
metadata:
  name: redpanda-headless
  labels:
    app: redpanda
spec:
  type: ClusterIP
  clusterIP: None
  publishNotReadyAddresses: true
  ports:
    - port: 9092
      targetPort: 9092
      protocol: TCP
      name: kafka
    - port: 8081
      targetPort: 8081
      protocol: TCP
      name: schema-registry
    - port: 8082
      targetPort: 8082
      protocol: TCP
      name: http-proxy
    - port: 9644
      targetPort: 9644
      protocol: TCP
      name: admin
    - port: 33145
      targetPort: 33145
      protocol: TCP
      name: rpc
  selector:
    app: redpanda
---
# ClusterIP service for client access
apiVersion: v1
kind: Service
metadata:
  name: redpanda
  labels:
    app: redpanda
spec:
  type: ClusterIP
  ports:
    - port: 9092
      targetPort: 9092
      protocol: TCP
      name: kafka
    - port: 8081
      targetPort: 8081
      protocol: TCP
      name: schema-registry
    - port: 8082
      targetPort: 8082
      protocol: TCP
      name: http-proxy
    - port: 9644
      targetPort: 9644
      protocol: TCP
      name: admin
  selector:
    app: redpanda
---
# StatefulSet for Redpanda (single binary, Kafka-compatible)
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redpanda
  labels:
    app: redpanda
spec:
  serviceName: redpanda-headless
  replicas: 1
  selector:
    matchLabels:
      app: redpanda
  template:
    metadata:
      labels:
        app: redpanda
    spec:
      securityContext:
        fsGroup: 101
      containers:
        - name: redpanda
          image: docker.redpanda.com/redpandadata/redpanda:v24.2.4
          args:
            - redpanda
            - start
            - --kafka-addr=internal://0.0.0.0:9092
            - --advertise-kafka-addr=internal://redpanda-0.redpanda-headless:9092
            - --pandaproxy-addr=internal://0.0.0.0:8082
            - --advertise-pandaproxy-addr=internal://redpanda-0.redpanda-headless:8082
            - --schema-registry-addr=internal://0.0.0.0:8081
            - --rpc-addr=0.0.0.0:33145
            - --advertise-rpc-addr=redpanda-0.redpanda-headless:33145
            - --mode=dev-container
            - --smp=1
            - --memory=1G
            - --overprovisioned
            - --default-log-level=info
          ports:
            - containerPort: 9092
              name: kafka
            - containerPort: 8081
              name: schema-registry
            - containerPort: 8082
              name: http-proxy
            - containerPort: 9644
              name: admin
            - containerPort: 33145
              name: rpc
          volumeMounts:
            - name: redpanda-data
              mountPath: /var/lib/redpanda/data
          resources:
            requests:
              memory: "1Gi"
              cpu: "500m"
            limits:
              memory: "2Gi"
              cpu: "1"
          readinessProbe:
            httpGet:
              path: /v1/status/ready
              port: 9644
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /v1/status/ready
              port: 9644
            initialDelaySeconds: 30
            periodSeconds: 15
  volumeClaimTemplates:
    - metadata:
        name: redpanda-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 8Gi
EOF

    print_success "Redpanda manifests generated"
}

install_kafka() {
    if [ "$INSTALL_KAFKA" = true ]; then
        print_status "Installing Redpanda (Kafka-compatible)..."

        # Check if Redpanda is already installed
        if kubectl get statefulset redpanda -n "$NAMESPACE" >/dev/null 2>&1; then
            print_warning "Redpanda is already installed. Skipping..."
            return
        fi

        # Generate and apply manifests
        generate_redpanda_manifests

        kubectl apply -f generated/redpanda-manifests.yaml -n "$NAMESPACE" | output_redirect

        wait_for_pods "Waiting for Redpanda to be ready" "app=redpanda" "$NAMESPACE" 300

        # Disable auto topic creation so only the setup job creates topics
        print_status "Configuring Redpanda (disabling auto topic creation)..."
        kubectl exec -n "$NAMESPACE" redpanda-0 -- rpk cluster config set auto_create_topics_enabled false | output_redirect

        print_success "Redpanda installed successfully"
    else
        print_status "Skipping Kafka/Redpanda installation (using existing Kafka)"
    fi
}


generate_collector_manifests() {
    print_status "Generating OpenTelemetry Collector manifests..."

    mkdir -p generated

    cat > generated/otel-collector-manifests.yaml << EOF
---
# ConfigMap for OpenTelemetry Collector configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  labels:
    app: otel-collector
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch:
        timeout: 10s
    exporters:
      awss3:
        marshaler: otlp_proto
        s3uploader:
          region: "us-east-1"
          s3_bucket: "$BUCKET_NAME"
          s3_prefix: "otel-raw/$ORG_ID/lakerunner"
          endpoint: "http://minio.$NAMESPACE.svc.cluster.local:9000"
          s3_force_path_style: true
          disable_ssl: true
          compression: gzip
      debug:
        verbosity: basic
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [awss3]
        metrics:
          receivers: [otlp]
          processors: [batch]
          exporters: [awss3]
        logs:
          receivers: [otlp]
          processors: [batch]
          exporters: [awss3]
      telemetry:
        logs:
          level: info
---
# Secret for S3 credentials
apiVersion: v1
kind: Secret
metadata:
  name: otel-collector-s3-credentials
  labels:
    app: otel-collector
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "$ACCESS_KEY"
  AWS_SECRET_ACCESS_KEY: "$SECRET_KEY"
---
# Deployment for OpenTelemetry Collector
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  labels:
    app: otel-collector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.143.0
          args:
            - --config=/etc/otelcol/config.yaml
          ports:
            - containerPort: 4317
              name: otlp-grpc
            - containerPort: 4318
              name: otlp-http
          envFrom:
            - secretRef:
                name: otel-collector-s3-credentials
          volumeMounts:
            - name: config
              mountPath: /etc/otelcol
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
      volumes:
        - name: config
          configMap:
            name: otel-collector-config
---
# Service for OpenTelemetry Collector
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  labels:
    app: otel-collector
spec:
  type: ClusterIP
  ports:
    - port: 4317
      targetPort: 4317
      protocol: TCP
      name: otlp-grpc
    - port: 4318
      targetPort: 4318
      protocol: TCP
      name: otlp-http
  selector:
    app: otel-collector
EOF

    print_success "generated/otel-collector-manifests.yaml generated successfully"
}


install_collector() {
    print_status "Installing OpenTelemetry Collector (demo mode - no redundancy)..."

    # Check if collector is already installed
    if kubectl get deployment otel-collector -n "$NAMESPACE" >/dev/null 2>&1; then
        print_warning "OpenTelemetry Collector is already installed. Skipping..."
        return
    fi

    # Get S3/MinIO credentials and bucket name
    if [ "$INSTALL_MINIO" = true ]; then
        ACCESS_KEY=$(kubectl get secret minio -n "$NAMESPACE" -o jsonpath="{.data.rootUser}" 2>/dev/null | base64 --decode 2>/dev/null || echo "minioadmin")
        SECRET_KEY=$(kubectl get secret minio -n "$NAMESPACE" -o jsonpath="{.data.rootPassword}" 2>/dev/null | base64 --decode 2>/dev/null || echo "minioadmin")
        BUCKET_NAME=${S3_BUCKET:-lakerunner}
    else
        ACCESS_KEY="$S3_ACCESS_KEY"
        SECRET_KEY="$S3_SECRET_KEY"
        BUCKET_NAME="$S3_BUCKET"
    fi

    # Generate and apply manifests
    generate_collector_manifests

    kubectl apply -f generated/otel-collector-manifests.yaml -n "$NAMESPACE" | output_redirect

    wait_for_pods "Waiting for OpenTelemetry Collector to be ready" "app=otel-collector" "$NAMESPACE" 120

    print_success "OpenTelemetry Collector installed successfully"
}


generate_values_file() {
    print_status "Generating lakerunner-values.yaml..."

    # Create generated directory if it doesn't exist
    mkdir -p generated

    # After MinIO is installed and before generating lakerunner-values.yaml, set credentials:
    if [ "$INSTALL_MINIO" = true ]; then
        MINIO_ACCESS_KEY=$(kubectl get secret minio -n "$NAMESPACE" -o jsonpath="{.data.rootUser}" 2>/dev/null | base64 --decode 2>/dev/null || echo "minioadmin")
        MINIO_SECRET_KEY=$(kubectl get secret minio -n "$NAMESPACE" -o jsonpath="{.data.rootPassword}" 2>/dev/null | base64 --decode 2>/dev/null || echo "minioadmin")
    else
        MINIO_ACCESS_KEY="$S3_ACCESS_KEY"
        MINIO_SECRET_KEY="$S3_SECRET_KEY"
    fi

    cat > generated/lakerunner-values.yaml << EOF
# Local development values for lakerunner
# Configured for $([ "$INSTALL_POSTGRES" = true ] && echo "local PostgreSQL" || echo "external PostgreSQL") and $([ "$INSTALL_MINIO" = true ] && echo "local MinIO" || echo "external S3 storage")

# Database configuration
database:
  create: true  # Create the secret with credentials
  secretName: "pg-credentials"
  lrdb:
    host: "$([ "$INSTALL_POSTGRES" = true ] && echo "postgres.$NAMESPACE.svc.cluster.local" || echo "$POSTGRES_HOST")"
    port: $([ "$INSTALL_POSTGRES" = true ] && echo "5432" || echo "$POSTGRES_PORT")
    name: "$([ "$INSTALL_POSTGRES" = true ] && echo "lakerunner" || echo "$POSTGRES_DB")"
    username: "$([ "$INSTALL_POSTGRES" = true ] && echo "lakerunner" || echo "$POSTGRES_USER")"
    password: "$([ "$INSTALL_POSTGRES" = true ] && echo "lakerunnerpass" || echo "$POSTGRES_PASSWORD")"
    sslMode: "$([ "$INSTALL_POSTGRES" = true ] && echo "disable" || echo "require")"  # Disable SSL for local development

# Configuration database
configdb:
  create: true  # Create the secret with credentials
  lrdb:
    host: "$([ "$INSTALL_POSTGRES" = true ] && echo "postgres.$NAMESPACE.svc.cluster.local" || echo "$POSTGRES_HOST")"
    port: $([ "$INSTALL_POSTGRES" = true ] && echo "5432" || echo "$POSTGRES_PORT")
    name: "$([ "$INSTALL_POSTGRES" = true ] && echo "configdb" || echo "$POSTGRES_DB")"
    username: "$([ "$INSTALL_POSTGRES" = true ] && echo "lakerunner" || echo "$POSTGRES_USER")"
    password: "$([ "$INSTALL_POSTGRES" = true ] && echo "lakerunnerpass" || echo "$POSTGRES_PASSWORD")"
    sslMode: "$([ "$INSTALL_POSTGRES" = true ] && echo "disable" || echo "require")"  # Disable SSL for local development

# Storage profiles
storageProfiles:
  source: "config"  # Use config file for storage profiles
  create: true
  yaml:
    - organization_id: "$ORG_ID"
      instance_num: 1
      collector_name: "lakerunner"
      cloud_provider: "aws"  # Always use "aws" for S3-compatible storage (including MinIO)
      region: "$([ "$INSTALL_MINIO" = true ] && echo "local" || echo "$S3_REGION")"
      bucket: "$([ "$INSTALL_MINIO" = true ] && echo "lakerunner" || echo "$S3_BUCKET")"
      use_path_style: true
      $([ "$INSTALL_MINIO" = true ] && echo "endpoint: \"http://minio.$NAMESPACE.svc.cluster.local:9000\"" || echo "# endpoint: \"\"")

# API keys for local development
apiKeys:
  source: "config"  # Use config file for API keys
  create: true
  secretName: "apikeys"
  yaml:
    - organization_id: "$ORG_ID"
      keys:
        - "$API_KEY"

# Cloud provider configuration
cloudProvider:
  provider: "aws"  # Using AWS provider for S3-compatible storage (including MinIO)
  aws:
    region: "$([ "$INSTALL_MINIO" = true ] && echo "us-east-1" || echo "$S3_REGION")"
    create: true
    secretName: "aws-credentials"
    inject: true
    accessKeyId: "$MINIO_ACCESS_KEY"
    secretAccessKey: "$MINIO_SECRET_KEY"

# Kafka topics configuration
kafkaTopics:
  config:
    version: 2
    defaults:
      partitionCount: 1
      replicationFactor: 1

# Kafka configuration
kafka:
$([ "$INSTALL_KAFKA" = true ] && echo "  brokers: \"redpanda.$NAMESPACE.svc.cluster.local:9092\"" || echo "  brokers: \"$KAFKA_BOOTSTRAP_SERVERS\"")
  sasl:
$([ -n "$KAFKA_USERNAME" ] && [ -n "$KAFKA_PASSWORD" ] && echo "    enabled: true" || echo "    enabled: false")
$([ -n "$KAFKA_USERNAME" ] && echo "    username: \"$KAFKA_USERNAME\"" || echo "#   username: \"\"")
$([ -n "$KAFKA_PASSWORD" ] && echo "    password: \"$KAFKA_PASSWORD\"" || echo "#   password: \"\"")
  tls:
    enabled: $([ "$INSTALL_KAFKA" = true ] && echo "false" || echo "true")

# Global configuration
global:
  resources:
    enabled: false # for a POC local install, this allows the components to use whatever they need.
  autoscaling:
    mode: disabled
  env:
    - name: OTEL_EXPORTER_OTLP_ENDPOINT
      value: "http://otel-collector.$NAMESPACE.svc.cluster.local:4318"
    - name: ENABLE_OTLP_TELEMETRY
      value: "true"
    - name: OTEL_METRIC_EXPORT_INTERVAL
      value: "10000"

# PubSub configuration
pubsub:
  HTTP:
    enabled: $([ "$USE_SQS" = true ] && echo "false" || echo "true")
    replicas: 1
  SQS:
    enabled: $([ "$USE_SQS" = true ] && echo "true" || echo "false")
    $([ "$USE_SQS" = true ] && echo "queueURL: \"$SQS_QUEUE_URL\"" || echo "# queueURL: \"\"")
    $([ "$USE_SQS" = true ] && echo "region: \"$SQS_REGION\"" || echo "# region: \"\"")

collector:
  enabled: false
#   resources:
#     requests:
#       cpu: 2000m
#       memory: 2Gi
#     limits:
#       cpu: 2000m
#       memory: 2Gi

setup:
  enabled: true

ingestLogs:
  enabled: $([ "$ENABLE_LOGS" = true ] && echo "true" || echo "false")

ingestMetrics:
  enabled: $([ "$ENABLE_METRICS" = true ] && echo "true" || echo "false")

ingestTraces:
  enabled: $([ "$ENABLE_TRACES" = true ] && echo "true" || echo "false")

compactLogs:
  enabled: $([ "$ENABLE_LOGS" = true ] && echo "true" || echo "false")

compactMetrics:
  enabled: $([ "$ENABLE_METRICS" = true ] && echo "true" || echo "false")

compactTraces:
  enabled: $([ "$ENABLE_TRACES" = true ] && echo "true" || echo "false")

rollupMetrics:
  enabled: $([ "$ENABLE_METRICS" = true ] && echo "true" || echo "false")

# Boxer configuration - single instance running all tasks
boxers:
  instances:
    - name: common
      tasks:
$([ "$ENABLE_LOGS" = true ] && echo "        - compact-logs" || echo "")
$([ "$ENABLE_LOGS" = true ] && echo "        - ingest-logs" || echo "")
$([ "$ENABLE_METRICS" = true ] && echo "        - compact-metrics" || echo "")
$([ "$ENABLE_METRICS" = true ] && echo "        - ingest-metrics" || echo "")
$([ "$ENABLE_METRICS" = true ] && echo "        - rollup-metrics" || echo "")
$([ "$ENABLE_TRACES" = true ] && echo "        - compact-traces" || echo "")
$([ "$ENABLE_TRACES" = true ] && echo "        - ingest-traces" || echo "")

sweeper:
  enabled: true

queryApi:
  enabled: true
  replicas: 1

queryWorker:
  enabled: true
  temporaryStorage:
    size: "8Gi"  # Reduce for local development

# Grafana configuration
grafana:
  enabled: true
  cardinal:
    apiKey: "$API_KEY"
  cardinalPlugin:
    url: "https://github.com/cardinalhq/cardinalhq-lakerunner-datasource/releases/download/$GRAFANA_PLUGIN_VERSION/cardinalhq-lakerunner-datasource.zip;cardinalhq-lakerunner-datasource"
$([ "$INSTALL_POSTGRES" = true ] && cat << 'GRAFANA_DB'
  env:
    - name: GF_DATABASE_TYPE
      value: "postgres"
    - name: GF_DATABASE_HOST
GRAFANA_DB
)
$([ "$INSTALL_POSTGRES" = true ] && echo "      value: \"postgres.$NAMESPACE.svc.cluster.local\"")
$([ "$INSTALL_POSTGRES" = true ] && cat << 'GRAFANA_DB2'
    - name: GF_DATABASE_NAME
      value: "grafana"
    - name: GF_DATABASE_USER
      value: "lakerunner"
    - name: GF_DATABASE_PASSWORD
      value: "lakerunnerpass"
    - name: GF_DATABASE_SSL_MODE
      value: "disable"
GRAFANA_DB2
)

# Debug container configuration
debugger:
  enabled: $([ "$ENABLE_DEBUG_POD" = true ] && echo "true" || echo "false")
EOF

    print_success "generated/lakerunner-values.yaml generated"
}

# Function to install Lakerunner
install_lakerunner() {
    if helm list -n "$NAMESPACE" -q | grep -q "^lakerunner$"; then
        print_warning "Lakerunner is already installed. Skipping..."
        return
    fi

    print_status "Installing Lakerunner in namespace: $NAMESPACE"

    # Build helm command with optional version
    helm_cmd="helm install lakerunner oci://public.ecr.aws/cardinalhq.io/lakerunner"
    if [ -n "$LAKERUNNER_VERSION" ]; then
        helm_cmd="$helm_cmd --version $LAKERUNNER_VERSION"
    fi
    helm_cmd="$helm_cmd --values generated/lakerunner-values.yaml --namespace $NAMESPACE"

    # Run helm install and capture output to temp file
    helm_output_file="/tmp/helm_install_output_$$"
    eval "$helm_cmd" > "$helm_output_file" 2>&1
    helm_exit_code=$?
    echo EXIT CODE: $helm_exit_code
    helm_output=$(cat "$helm_output_file" 2>/dev/null || echo "Failed to read helm output")

    if [ $helm_exit_code -ne 0 ]; then
        print_error "Lakerunner installation failed with exit code: $helm_exit_code"
        echo
        echo "Helm command that failed:"
        echo "$helm_cmd"
        echo
        echo "Error output:"
        echo "$helm_output"
        echo
        print_error "Installation cannot continue. Please resolve the above error and try again."
        rm -f "$helm_output_file"
        exit 1
    fi

    # Clean up temp file on success
    rm -f "$helm_output_file"

    # Show output in verbose mode
    if [ "$VERBOSE" = true ]; then
        echo "$helm_output"
    fi

    print_success "Lakerunner installed successfully in namespace: $NAMESPACE"
}

# Function to wait for services to be ready
wait_for_services() {
    print_status "Waiting for Lakerunner services to be ready in namespace: $NAMESPACE"
    # Check if setup job exists and wait for it to complete
    if kubectl get job lakerunner-setup -n "$NAMESPACE" >/dev/null 2>&1; then
        show_progress "Waiting for setup job to complete" "kubectl wait --for=condition=complete job/lakerunner-setup -n '$NAMESPACE' --timeout=600s" 600
        # Restart boxer to pick up Kafka topics created by setup job
        print_status "Restarting boxer to pick up Kafka topics..."
        kubectl rollout restart deployment/lakerunner-boxer-common -n "$NAMESPACE" 2>/dev/null || true
        kubectl rollout status deployment/lakerunner-boxer-common -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
    else
        print_status "Setup job not found (may have already completed or not needed for upgrade)"
    fi
    wait_for_pods "Waiting for query-api service" "app.kubernetes.io/name=lakerunner,app.kubernetes.io/component=query-api" "$NAMESPACE" 300 || true
    wait_for_pods "Waiting for Grafana service" "app.kubernetes.io/name=lakerunner,app.kubernetes.io/component=grafana" "$NAMESPACE" 300 || true
    print_success "All services are ready in namespace: $NAMESPACE"
}


display_connection_info() {
    print_success "Lakerunner installation completed successfully!"
    echo
    echo "=== Installation Summary ==="
    echo

    echo "Telemetry Configuration:"
    if [ "$ENABLE_LOGS" = true ]; then
        echo "  Logs: Enabled"
    else
        echo "  Logs: Disabled"
    fi
    if [ "$ENABLE_METRICS" = true ]; then
        echo "  Metrics: Enabled"
    else
        echo "  Metrics: Disabled"
    fi
    if [ "$ENABLE_TRACES" = true ]; then
        echo "  Traces: Enabled"
    else
        echo "  Traces: Disabled"
    fi

    echo
    echo "Infrastructure:"
    if [ "$INSTALL_POSTGRES" = true ]; then
        echo "  PostgreSQL: Installed (demo mode)"
    fi

    if [ "$INSTALL_MINIO" = true ]; then
        echo "  Storage: MinIO Installed (demo mode)"
    else
        echo "  Storage: External S3 ($S3_BUCKET)"
    fi

    if [ "$INSTALL_KAFKA" = true ]; then
        echo "  Kafka: Redpanda Installed (demo mode)"
    fi
    echo

    # Demo App Information (only if installed)
    if [ "$INSTALL_OTEL_DEMO" = true ]; then
        echo "=== Demo Applications ==="
        echo "OpenTelemetry demo applications have been installed in the '$NAMESPACE' namespace."
        echo "These apps generate sample telemetry data for testing Lakerunner functionality."
        echo
        echo "To access the demo applications:"
        echo "  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=frontend-proxy -n $NAMESPACE --timeout=300s"
        echo "  kubectl port-forward svc/frontend-proxy 8080:8080 -n $NAMESPACE"
        echo "  Then visit: http://localhost:8080"
        echo
    fi

    # MinIO Console Access (only if MinIO was installed)
    if [ "$INSTALL_MINIO" = true ]; then
        # Get MinIO credentials (official MinIO chart uses rootUser/rootPassword keys)
        MINIO_ACCESS_KEY=$(kubectl get secret minio -n "$NAMESPACE" -o jsonpath="{.data.rootUser}" 2>/dev/null | base64 --decode 2>/dev/null || echo "minioadmin")
        MINIO_SECRET_KEY=$(kubectl get secret minio -n "$NAMESPACE" -o jsonpath="{.data.rootPassword}" 2>/dev/null | base64 --decode 2>/dev/null || echo "minioadmin")

        echo "=== MinIO Console Access ==="
        echo "To access MinIO Console:"
        echo "  kubectl port-forward svc/minio-console 9001:9001 -n $NAMESPACE"
        echo "  Then visit: http://localhost:9001"
        echo "  Access Key: $MINIO_ACCESS_KEY"
        echo "  Secret Key: $MINIO_SECRET_KEY"
        echo
    fi

    # CLI Access
    echo "=== Lakerunner CLI Access ==="
    echo "To use lakerunner-cli:"
    echo "  kubectl port-forward svc/lakerunner-query-api-v2 8080:8080 -n $NAMESPACE"
    echo "  Download CLI from: https://github.com/cardinalhq/lakerunner-cli/releases"
    echo "  Then run: lakerunner-cli --endpoint http://localhost:8080 --api-key $API_KEY"
    echo

    # Grafana Access
    echo "=== Grafana Dashboard Access ==="
    echo "To access Grafana:"
    echo "  kubectl port-forward svc/lakerunner-grafana 3000:3000 -n $NAMESPACE"
    echo "  Then visit: http://localhost:3000"
    echo "  Username: admin"
    echo "  Password: admin"
    echo "  Datasource: Cardinal (pre-configured)"
    echo

    # Debug Pod Access (only if debug pod was enabled)
    if [ "$ENABLE_DEBUG_POD" = true ]; then
        echo "=== PostgreSQL Debug Pod Access ==="
        echo "To connect to the debug pod with psql:"
        echo "  kubectl exec -it deployment/lakerunner-debugger -n $NAMESPACE -- sh -c 'psql -h \\\$LRDB_HOST -p \\\$LRDB_PORT -U \\\$LRDB_USER -d \\\$LRDB_DBNAME'"
        echo "  kubectl exec -it deployment/lakerunner-debugger -n $NAMESPACE -- sh -c 'psql -h \\\$CONFIGDB_HOST -p \\\$CONFIGDB_PORT -U \\\$CONFIGDB_USER -d \\\$CONFIGDB_DBNAME'"
        echo "  All database environment variables are pre-configured in the pod"
        echo
    fi

    # Only show PubSub HTTP endpoint if MinIO was NOT installed and not using SQS
    if [ "$INSTALL_MINIO" = false ] && [ "$USE_SQS" = false ]; then
        echo "=== Event Notification Configuration ==="
        echo "Lakerunner PubSub HTTP Endpoint:"
        echo "  URL: http://lakerunner-pubsub-http.$NAMESPACE.svc.cluster.local:8080/"
        echo
    fi

    echo "=== Generated Values Files ==="
    echo "Configuration files have been generated in the ./generated/ directory:"
    echo "  - lakerunner-values.yaml: Main Lakerunner configuration"
    if [ "$INSTALL_POSTGRES" = true ]; then
        echo "  - postgres-manifests.yaml: PostgreSQL Kubernetes manifests"
    fi
    if [ "$INSTALL_KAFKA" = true ]; then
        echo "  - redpanda-manifests.yaml: Redpanda Kubernetes manifests"
    fi
    if [ "$INSTALL_OTEL_DEMO" = true ]; then
        echo "  - otel-demo-values.yaml: OpenTelemetry demo configuration"
    fi
    echo
    echo "To upgrade your installation later, use:"
    echo "  helm upgrade lakerunner oci://public.ecr.aws/cardinalhq.io/lakerunner \\"
    echo "    --version [NEW_VERSION] \\"
    echo "    --values generated/lakerunner-values.yaml \\"
    echo "    --namespace $NAMESPACE"
    echo

    echo "=== Next Steps ==="

    # Only show MinIO-specific instructions if MinIO was NOT installed
    if [ "$INSTALL_MINIO" = false ]; then
        echo "1. Ensure your S3 bucket '$S3_BUCKET' exists and is accessible"

        if [ "$USE_SQS" = true ]; then
            echo "2. Configure S3 bucket notifications to send events to your SQS queue:"
            echo "   - Queue ARN: arn:aws:sqs:$SQS_REGION:$(echo $SQS_QUEUE_URL | cut -d'/' -f4):$(echo $SQS_QUEUE_URL | cut -d'/' -f5)"
            echo "   - Event types: s3:ObjectCreated:*"
            echo "3. Configure SQS queue policy to allow S3 to send messages"
            echo "4. Ensure IAM permissions for Lakerunner to read from SQS"
        else
            echo "2. Configure event notifications in your S3-compatible storage:"
            echo "   - Add event notification pointing to:"
            echo "     http://lakerunner-pubsub-http.$NAMESPACE.svc.cluster.local:8080/"
            echo "3. The event notification ARN should appear in the bucket configuration"
        fi
    fi

    echo
    echo "For further information, visit: https://github.com/cardinalhq/lakerunner"
    echo

}

ask_install_otel_demo() {
    echo
    echo "=== OpenTelemetry Demo Apps ==="
    echo "Would you like to install the OpenTelemetry demo applications?"
    echo "This will deploy a sample e-commerce application that generates"
    echo "logs, metrics, and traces to demonstrate Lakerunner in action."
    echo

    get_input "Install OTEL demo apps? (y/N)" "N" "INSTALL_OTEL_DEMO"

    if [[ "$INSTALL_OTEL_DEMO" =~ ^[Yy]$ ]]; then
        INSTALL_OTEL_DEMO=true
        print_status "Will install OpenTelemetry demo apps"
    else
        INSTALL_OTEL_DEMO=false
        print_status "Skipping OpenTelemetry demo apps installation"
    fi
}

display_configuration_summary() {
    echo
    echo "=========================================="
    echo "    Configuration Summary"
    echo "=========================================="
    echo

    echo "Namespace: $NAMESPACE"
    echo

    echo "Infrastructure Configuration:"
    if [ "$INSTALL_POSTGRES" = true ]; then
        echo "  PostgreSQL: Local (demo mode - no redundancy)"
    else
        echo "  PostgreSQL: External ($POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB)"
    fi

    if [ "$INSTALL_MINIO" = true ]; then
        echo "  Storage: Local MinIO (demo mode - no redundancy)"
    else
        echo "  Storage: External S3 ($S3_BUCKET)"
    fi

    if [ "$INSTALL_KAFKA" = true ]; then
        echo "  Kafka: Local Redpanda (demo mode - no redundancy)"
    else
        echo "  Kafka: External ($KAFKA_BOOTSTRAP_SERVERS)"
    fi

    if [ "$USE_SQS" = true ]; then
        echo "  Event Notifications: SQS ($SQS_QUEUE_URL)"
    else
        echo "  Event Notifications: HTTP webhook"
    fi
    echo

    echo "Telemetry Configuration:"
    if [ "$ENABLE_LOGS" = true ]; then
        echo "  Logs: Enabled"
    else
        echo "  Logs: Disabled"
    fi
    if [ "$ENABLE_METRICS" = true ]; then
        echo "  Metrics: Enabled"
    else
        echo "  Metrics: Disabled"
    fi
    if [ "$ENABLE_TRACES" = true ]; then
        echo "  Traces: Enabled"
    else
        echo "  Traces: Disabled"
    fi
    echo

    echo "Demo Applications:"
    if [ "$INSTALL_OTEL_DEMO" = true ]; then
        echo "  OpenTelemetry Demo: Will be installed"
    else
        echo "  OpenTelemetry Demo: Will not be installed"
    fi
    echo
}

confirm_installation() {
    echo "=========================================="
    echo "    Installation Confirmation"
    echo "=========================================="
    echo

    get_input "Proceed with installation? (Y/n)" "Y" "CONFIRM_INSTALL"

    if [[ "$CONFIRM_INSTALL" =~ ^[Nn]$ ]]; then
        print_status "Installation cancelled by user"
        exit 0
    fi

    echo
    print_status "Proceeding with installation..."
    echo
}

generate_otel_demo_values() {
    print_status "Generating OTEL demo values file..."

    # Create generated directory if it doesn't exist
    mkdir -p generated

    # Set credentials based on whether MinIO is installed
    if [ "$INSTALL_MINIO" = true ]; then
        # Get MinIO credentials (official MinIO chart uses rootUser/rootPassword keys)
        ACCESS_KEY=$(kubectl get secret minio -n "$NAMESPACE" -o jsonpath="{.data.rootUser}" 2>/dev/null | base64 --decode 2>/dev/null || echo "minioadmin")
        SECRET_KEY=$(kubectl get secret minio -n "$NAMESPACE" -o jsonpath="{.data.rootPassword}" 2>/dev/null | base64 --decode 2>/dev/null || echo "minioadmin")
        BUCKET_NAME=${S3_BUCKET:-lakerunner}
    else
        # Use external S3 credentials
        ACCESS_KEY="$S3_ACCESS_KEY"
        SECRET_KEY="$S3_SECRET_KEY"
        BUCKET_NAME="$S3_BUCKET"
    fi

    cat > generated/otel-demo-values.yaml << EOF
components:
  load-generator:
    resources:
      limits:
        cpu: 250m
        memory: 512Mi
    env:
      - name: LOCUST_WEB_HOST
        value: "0.0.0.0"
      - name: LOCUST_WEB_PORT
        value: "8089"
      - name: LOCUST_USERS
        value: "3"
      - name: LOCUST_SPAWN_RATE
        value: "1"
      - name: LOCUST_HOST
        value: http://frontend-proxy:8080
      - name: LOCUST_HEADLESS
        value: "false"
      - name: LOCUST_AUTOSTART
        value: "true"
      - name: LOCUST_BROWSER_TRAFFIC_ENABLED
        value: "true"
      - name: PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION
        value: python
      - name: FLAGD_HOST
        value: flagd
      - name: FLAGD_OFREP_PORT
        value: "8016"
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: http://otel-collector:4317
opentelemetry-collector:
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch:
        timeout: 10s
    connectors:
      spanmetrics: {}
    exporters:
      awss3/metrics:
        marshaler: otlp_proto
        s3uploader:
$([ "$INSTALL_MINIO" = true ] && echo "          region: \"us-east-1\"" || echo "          region: \"$S3_REGION\"")
          s3_bucket: "$BUCKET_NAME"
          s3_prefix: "otel-raw/$ORG_ID/lakerunner"
$([ "$INSTALL_MINIO" = true ] && echo "          endpoint: \"http://minio.$NAMESPACE.svc.cluster.local:9000\"" || echo "          # endpoint: \"\"")
          compression: "gzip"
$([ "$INSTALL_MINIO" = true ] && echo "          s3_force_path_style: true" || echo "          # s3_force_path_style: false")
$([ "$INSTALL_MINIO" = true ] && echo "          disable_ssl: true" || echo "          # disable_ssl: false")
      awss3/logs:
        marshaler: otlp_proto
        s3uploader:
$([ "$INSTALL_MINIO" = true ] && echo "          region: \"us-east-1\"" || echo "          region: \"$S3_REGION\"")
          s3_bucket: "$BUCKET_NAME"
          s3_prefix: "otel-raw/$ORG_ID/lakerunner"
$([ "$INSTALL_MINIO" = true ] && echo "          endpoint: \"http://minio.$NAMESPACE.svc.cluster.local:9000\"" || echo "          # endpoint: \"\"")
          compression: "gzip"
$([ "$INSTALL_MINIO" = true ] && echo "          s3_force_path_style: true" || echo "          # s3_force_path_style: false")
$([ "$INSTALL_MINIO" = true ] && echo "          disable_ssl: true" || echo "          # disable_ssl: false")
      awss3/traces:
        marshaler: otlp_proto
        s3uploader:
$([ "$INSTALL_MINIO" = true ] && echo "          region: \"us-east-1\"" || echo "          region: \"$S3_REGION\"")
          s3_bucket: "$BUCKET_NAME"
          s3_prefix: "otel-raw/$ORG_ID/lakerunner"
$([ "$INSTALL_MINIO" = true ] && echo "          endpoint: \"http://minio.$NAMESPACE.svc.cluster.local:9000\"" || echo "          # endpoint: \"\"")
          compression: "gzip"
$([ "$INSTALL_MINIO" = true ] && echo "          s3_force_path_style: true" || echo "          # s3_force_path_style: false")
$([ "$INSTALL_MINIO" = true ] && echo "          disable_ssl: true" || echo "          # disable_ssl: false")
    service:
      pipelines:
        metrics:
          receivers: [otlp, spanmetrics]
          processors:
            - batch
          exporters: [awss3/metrics]
        logs:
          receivers: [otlp]
          processors:
            - batch
          exporters: [awss3/logs]
        traces:
          receivers: [otlp]
          exporters: [spanmetrics, awss3/traces]
      telemetry:
        metrics:
          level: none
  extraEnvs:
    - name: AWS_ACCESS_KEY_ID
      value: "$ACCESS_KEY"
    - name: AWS_SECRET_ACCESS_KEY
      value: "$SECRET_KEY"
jaeger:
  enabled: false
prometheus:
  enabled: false
grafana:
  enabled: false
opensearch:
  enabled: false
EOF

    print_success "generated/otel-demo-values.yaml generated successfully"
}

setup_minio_webhooks() {
    if [ "$INSTALL_MINIO" = true ]; then
        print_status "Setting up MinIO webhooks for Lakerunner event notifications..."

        # Get MinIO credentials from secret (official MinIO chart uses rootUser/rootPassword keys)
        MINIO_ACCESS_KEY=$(kubectl get secret minio -n "$NAMESPACE" -o jsonpath="{.data.rootUser}" 2>/dev/null | base64 --decode 2>/dev/null || echo "minioadmin")
        MINIO_SECRET_KEY=$(kubectl get secret minio -n "$NAMESPACE" -o jsonpath="{.data.rootPassword}" 2>/dev/null | base64 --decode 2>/dev/null || echo "minioadmin")
        S3_BUCKET=${S3_BUCKET:-lakerunner}

        # Get the MinIO pod name (official MinIO chart uses statefulset or deployment)
        MINIO_POD=$(kubectl get pods -n "$NAMESPACE" -l app=minio -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
        if [ -z "$MINIO_POD" ]; then
            print_warning "Could not find MinIO pod, trying alternative selector..."
            MINIO_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=minio -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
        fi

        if [ -z "$MINIO_POD" ]; then
            print_error "Could not find MinIO pod. Skipping webhook setup."
            return
        fi

        kubectl exec -n "$NAMESPACE" "$MINIO_POD" -- mc alias set minio http://localhost:9000 $MINIO_ACCESS_KEY $MINIO_SECRET_KEY >/dev/null 2>&1

        if ! kubectl exec -n "$NAMESPACE" "$MINIO_POD" -- mc ls minio/$S3_BUCKET >/dev/null 2>&1; then
            print_warning "$S3_BUCKET bucket does not exist. This should have been created automatically."
            print_status "Attempting to create bucket manually..."
            if kubectl exec -n "$NAMESPACE" "$MINIO_POD" -- mc mb minio/$S3_BUCKET 2>/dev/null; then
                print_success "$S3_BUCKET bucket created successfully"
            else
                print_warning "Failed to create bucket manually, but continuing (may already exist)"
            fi
        else
            print_success "$S3_BUCKET bucket already exists"
        fi

        # Configure webhook notifications
        print_status "Configuring MinIO webhook notifications..."
        if kubectl exec -n "$NAMESPACE" "$MINIO_POD" -- mc admin config set minio notify_webhook:create_object endpoint="http://lakerunner-pubsub-http.$NAMESPACE.svc.cluster.local:8080/" 2>/dev/null; then
            print_success "Webhook configuration set successfully"
        else
            print_warning "Failed to set webhook configuration, continuing..."
        fi

        print_status "Restarting MinIO to apply configuration..."
        # Delete the pod directly to restart (rollout restart doesn't work with ReadWriteOnce PVC)
        kubectl delete pod "$MINIO_POD" -n "$NAMESPACE" >/dev/null 2>&1

        # Wait for new pod to be ready
        sleep 5
        wait_for_pods "Waiting for MinIO to restart" "app=minio" "$NAMESPACE" 120
        print_success "MinIO restarted successfully"

        # Get the new pod name after restart
        MINIO_POD=$(kubectl get pods -n "$NAMESPACE" -l app=minio -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
        if [ -z "$MINIO_POD" ]; then
            MINIO_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=minio -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
        fi

        # Re-setup mc alias after pod restart
        print_status "Re-establishing MinIO connection..."
        kubectl exec -n "$NAMESPACE" "$MINIO_POD" -- mc alias set minio http://localhost:9000 $MINIO_ACCESS_KEY $MINIO_SECRET_KEY >/dev/null 2>&1

        # Add event notification for otel-raw prefix
        print_status "Setting up event notifications..."
        kubectl exec -n "$NAMESPACE" "$MINIO_POD" -- mc event add --event "put" minio/$S3_BUCKET arn:minio:sqs::create_object:webhook --prefix "otel-raw" 2>/dev/null || print_warning "Failed to add otel-raw event notification"

        print_success "MinIO webhooks configured successfully for Lakerunner event notifications"
    else
        print_status "Skipping MinIO webhook setup (using external S3 storage)"
    fi
}

install_otel_demo() {
    if [ "$INSTALL_OTEL_DEMO" = true ]; then
        print_status "Installing OpenTelemetry demo apps..."

        # Check if configured bucket exists (required for OTEL demo to work)
        if [ "$INSTALL_MINIO" = true ]; then
            print_status "Checking if $S3_BUCKET bucket exists in MinIO..."
            MINIO_ACCESS_KEY=$(kubectl get secret minio -n "$NAMESPACE" -o jsonpath="{.data.rootUser}" 2>/dev/null | base64 --decode 2>/dev/null || echo "minioadmin")
            MINIO_SECRET_KEY=$(kubectl get secret minio -n "$NAMESPACE" -o jsonpath="{.data.rootPassword}" 2>/dev/null | base64 --decode 2>/dev/null || echo "minioadmin")

            # Get the MinIO pod name
            MINIO_POD=$(kubectl get pods -n "$NAMESPACE" -l app=minio -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
            if [ -z "$MINIO_POD" ]; then
                MINIO_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=minio -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
            fi

            kubectl exec -n "$NAMESPACE" "$MINIO_POD" -- mc alias set minio http://localhost:9000 $MINIO_ACCESS_KEY $MINIO_SECRET_KEY >/dev/null 2>&1
            if ! kubectl exec -n "$NAMESPACE" "$MINIO_POD" -- mc ls minio/$S3_BUCKET >/dev/null 2>&1; then
                print_error "$S3_BUCKET bucket does not exist. MinIO setup may have failed."
                exit 1
            fi
        else
            print_warning "Using external S3 storage. Please ensure the '$S3_BUCKET' bucket exists."
            print_warning "The OTEL demo apps will fail if the bucket doesn't exist."
        fi

        # Add OpenTelemetry Helm repository
        if [ "$SKIP_HELM_REPO_UPDATES" != true ]; then
            helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
            helm repo update >/dev/null  2>&1
        fi

        local helm_output
        if helm_output=$(helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
            --namespace "$NAMESPACE" \
            --values generated/otel-demo-values.yaml 2>&1); then
            [ "$VERBOSE" = true ] && echo "$helm_output"
            print_success "OpenTelemetry demo apps installed successfully"
        else
            print_error "Failed to install OpenTelemetry demo apps"
            echo "$helm_output"
            print_warning "This may be due to cluster-scoped resources from a previous installation"
            print_warning "Try: kubectl delete clusterrole otel-collector && kubectl delete clusterrolebinding otel-collector"
            return 1
        fi
        echo
        echo "=== OpenTelemetry Demo Apps ==="
        echo "Demo applications have been installed in the '$NAMESPACE' namespace."
        echo "These apps will generate sample telemetry data that will be:"
        echo "1. Collected by the OpenTelemetry Collector"
        echo "2. Exported to object storage"
        echo "3. Processed by Lakerunner"
        echo "4. Available in Grafana dashboard"
        echo
        echo "To access the demo applications, run the following:"
        echo " kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=frontend-proxy -n $NAMESPACE --timeout=300s "
        echo " kubectl port-forward svc/frontend-proxy 8080:8080 -n $NAMESPACE "
        echo "Then visit http://localhost:8080"
        echo "The demo apps will continuously generate logs, metrics, and traces"
        echo "that will flow through Lakerunner for processing and analysis."
        echo
    else
        print_status "Skipping OpenTelemetry demo apps installation"
    fi
}

# Parse command line arguments
parse_args() {
    SIGNALS_FLAG=""
    STANDALONE_FLAG=false
    SKIP_HELM_REPO_UPDATES=false
    VERBOSE=false
    ENABLE_DEBUG_POD=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --signals)
                SIGNALS_FLAG="$2"
                shift 2
                ;;
            --standalone)
                STANDALONE_FLAG=true
                shift
                ;;
            --skip-helm-repo-updates)
                SKIP_HELM_REPO_UPDATES=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --debug-psql-pod)
                ENABLE_DEBUG_POD=true
                shift
                ;;
            --version)
                LAKERUNNER_VERSION="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    echo "Lakerunner Installation Script"
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  --signals SIGNALS         Specify which telemetry signals to enable"
    echo "                            Options: all, logs, metrics, traces"
    echo "                            Multiple signals can be comma-separated"
    echo "                            Examples: --signals all"
    echo "                                     --signals metrics"
    echo "                                     --signals logs,metrics,traces"
    echo "  --standalone              Install in standalone mode with minimal interaction"
    echo "                            Automatically enables logs and metrics, installs all"
    echo "                            local infrastructure (PostgreSQL, MinIO, Kafka)"
    echo "                            Uses default namespace 'lakerunner-demo' and default credentials"
    echo "  --skip-helm-repo-updates  Skip running 'helm repo update' commands during installation"
    echo "                            Useful when helm repos are already up to date or when"
    echo "                            working in environments with restricted network access"
    echo "  --verbose                 Show detailed output from helm install commands"
    echo "                            By default, helm output is hidden to reduce noise"
    echo "  --debug-psql-pod          Enable PostgreSQL debugging container with psql client"
    echo "                            Deploys a pod with database access for troubleshooting"
    echo "  --version VERSION         Pin a specific Lakerunner helm chart version (default: latest)"
    echo "  --help, -h               Show this help message"
    echo
}

# Parse signals from the --signals flag
parse_signals() {
    if [ -n "$SIGNALS_FLAG" ]; then
        # Convert to lowercase and remove spaces
        signals=$(echo "$SIGNALS_FLAG" | tr '[:upper:]' '[:lower:]' | tr -d ' ')

        # Initialize all signals to false
        ENABLE_LOGS=false
        ENABLE_METRICS=false
        ENABLE_TRACES=false

        if [ "$signals" = "all" ]; then
            ENABLE_LOGS=true
            ENABLE_METRICS=true
            ENABLE_TRACES=true
            print_status "Signals: Enabling all telemetry types (logs, metrics, traces)"
        else
            # Split by comma and process each signal
            IFS=',' read -ra SIGNAL_ARRAY <<< "$signals"
            enabled_signals=()

            for signal in "${SIGNAL_ARRAY[@]}"; do
                case "$signal" in
                    logs)
                        ENABLE_LOGS=true
                        enabled_signals+=("logs")
                        ;;
                    metrics)
                        ENABLE_METRICS=true
                        enabled_signals+=("metrics")
                        ;;
                    traces)
                        ENABLE_TRACES=true
                        enabled_signals+=("traces")
                        ;;
                    *)
                        print_error "Invalid signal: $signal"
                        echo "Valid signals are: logs, metrics, traces, all"
                        exit 1
                        ;;
                esac
            done

            if [ ${#enabled_signals[@]} -eq 0 ]; then
                print_error "No valid signals specified"
                exit 1
            fi

            print_status "Signals: Enabling $(IFS=', '; echo "${enabled_signals[*]}")"
        fi

        return 0  # Signals were specified via flag
    else
        return 1  # No signals flag, should ask user
    fi
}

# Configure all settings for standalone mode
configure_standalone() {
    print_status "Configuring standalone installation..."

    # Namespace
    NAMESPACE="lakerunner-demo"

    # Infrastructure - install everything locally
    INSTALL_POSTGRES=true
    INSTALL_MINIO=true
    INSTALL_KAFKA=true

    # Telemetry - use --signals flag if provided, otherwise default to logs and metrics
    if [ -n "$SIGNALS_FLAG" ]; then
        # --signals flag was provided, use parse_signals() to set telemetry
        parse_signals
        print_status "Using signals from --signals flag"
    else
        # No --signals flag, use standalone defaults: logs and metrics enabled, traces disabled
        ENABLE_LOGS=true
        ENABLE_METRICS=true
        ENABLE_TRACES=false
        print_status "Using standalone default signals: logs and metrics"
    fi

    # Event notifications - use HTTP webhook (not SQS)
    USE_SQS=false

    # Credentials - use defaults
    ORG_ID="151f346b-967e-4c94-b97a-581898b5b457"
    API_KEY="test-key"

    # Demo apps - disabled by default in standalone mode
    INSTALL_OTEL_DEMO=false

    print_status "Standalone mode configured:"
    print_status "  Namespace: $NAMESPACE"
    print_status "  Infrastructure: PostgreSQL, MinIO, Kafka (all local)"

    # Build telemetry status message
    telemetry_status=""
    [ "$ENABLE_LOGS" = true ] && telemetry_status="${telemetry_status}Logs "
    [ "$ENABLE_METRICS" = true ] && telemetry_status="${telemetry_status}Metrics "
    [ "$ENABLE_TRACES" = true ] && telemetry_status="${telemetry_status}Traces "

    if [ -z "$telemetry_status" ]; then
        telemetry_status="None enabled"
    else
        telemetry_status="${telemetry_status%% }enabled"  # Remove trailing space and add "enabled"
    fi

    print_status "  Telemetry: $telemetry_status"
    print_status "  Demo apps: Enabled"
    print_status "  Debug pod: $([ "$ENABLE_DEBUG_POD" = true ] && echo "Enabled" || echo "Disabled")"
}

main() {
    # Parse command line arguments
    parse_args "$@"

    echo "=========================================="
    echo "    Lakerunner Installation Script"
    echo "=========================================="
    echo

    check_prerequisites

    # Handle configuration based on flags
    if [ "$STANDALONE_FLAG" = true ]; then
        # Standalone mode - configure everything automatically
        configure_standalone
    else
        # Interactive mode - get all user preferences
        get_namespace
        get_infrastructure_preferences

        # Handle telemetry preferences
        if ! parse_signals; then
            # No --signals flag provided, ask user
            get_telemetry_preferences
        fi

        get_lakerunner_credentials
        ask_install_otel_demo
    fi

    # Display configuration summary
    display_configuration_summary

    # Confirm installation
    confirm_installation

    # Pre-flight check for helm repositories (now that we know the configuration)
    check_helm_repositories

    # Start installation process
    print_status "Starting installation process..."

    # Ensure namespace exists before installing anything
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        kubectl create namespace "$NAMESPACE" >/dev/null 2>&1
        # Set PodSecurity labels to baseline (allows infrastructure components to run)
        kubectl label namespace "$NAMESPACE" \
            pod-security.kubernetes.io/enforce=baseline \
            pod-security.kubernetes.io/enforce-version=latest \
            pod-security.kubernetes.io/warn=baseline \
            pod-security.kubernetes.io/warn-version=latest \
            --overwrite >/dev/null 2>&1
        print_status "Created namespace $NAMESPACE with baseline PodSecurity policy"
    fi

    install_minio
    install_postgresql
    install_kafka
    install_collector

    generate_values_file

    install_lakerunner

    wait_for_services

    # Setup MinIO webhooks for Lakerunner event notifications (required for Lakerunner to function)
    setup_minio_webhooks

    generate_otel_demo_values

    install_otel_demo

    display_connection_info
}

main "$@"
