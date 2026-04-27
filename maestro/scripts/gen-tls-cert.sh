#!/usr/bin/env bash
# Generate a self-signed TLS cert + key suitable for feeding into the
# maestro chart's inline TLS path:
#
#   maestro.tls.cert.autoGenerate=false
#   maestro.tls.cert.crt=<contents of tls.crt>
#   maestro.tls.cert.key=<contents of tls.key>
#
# The cert covers a single IPv4 address (1.2.3.4 dotted-quad) as a
# Subject Alternative Name. Use this for IP-only POC bastion deployments
# where DNS isn't an option. Browsers will still warn (it's self-signed),
# but the cert chain validates against the IP rather than failing on a
# CN/SAN mismatch.
#
# Usage:
#   scripts/gen-tls-cert.sh <ipv4> [--out-dir <dir>] [--days <n>] [--extra-san <san>...]
#
# Examples:
#   scripts/gen-tls-cert.sh 1.2.3.4
#   scripts/gen-tls-cert.sh 10.0.42.7 --out-dir /tmp/maestro-tls --days 730
#   scripts/gen-tls-cert.sh 1.2.3.4 --extra-san DNS:bastion.local --extra-san IP:10.0.0.1
#
# Outputs <out-dir>/tls.crt and <out-dir>/tls.key (defaults to ./).
# Prints a copy-pasteable `helm install --set-file ...` snippet on stdout.

set -euo pipefail

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

IP=""
OUT_DIR="."
DAYS=365
EXTRA_SANS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage 0
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --days)
      DAYS="$2"
      shift 2
      ;;
    --extra-san)
      EXTRA_SANS+=("$2")
      shift 2
      ;;
    -*)
      echo "error: unknown flag: $1" >&2
      usage 1 >&2
      ;;
    *)
      if [[ -n "$IP" ]]; then
        echo "error: only one IPv4 argument is supported (got '$IP' and '$1')" >&2
        exit 1
      fi
      IP="$1"
      shift
      ;;
  esac
done

if [[ -z "$IP" ]]; then
  echo "error: missing required IPv4 address argument" >&2
  usage 1 >&2
fi

# Strict 1.2.3.4 dotted-quad with 0-255 in each octet. Anything else
# (DNS names, CIDR notation, IPv6) is rejected so the operator gets a
# clear error rather than a cert with a useless SAN.
if ! [[ "$IP" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "error: '$IP' is not a 1.2.3.4 dotted-quad IPv4 address" >&2
  exit 1
fi
for octet in "${BASH_REMATCH[@]:1}"; do
  if (( octet > 255 )); then
    echo "error: '$IP' has an octet > 255" >&2
    exit 1
  fi
done

if ! command -v openssl >/dev/null 2>&1; then
  echo "error: openssl not found in PATH" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
CRT="$OUT_DIR/tls.crt"
KEY="$OUT_DIR/tls.key"
CFG="$(mktemp -t gen-tls-cert.XXXXXX.cnf)"
trap 'rm -f "$CFG"' EXIT

SAN="IP:${IP}"
for s in "${EXTRA_SANS[@]:-}"; do
  [[ -z "$s" ]] && continue
  SAN="${SAN},${s}"
done

cat >"$CFG" <<EOF
[req]
distinguished_name=req_distinguished_name
prompt=no
req_extensions=v3
[req_distinguished_name]
CN=${IP}
[v3]
subjectAltName=${SAN}
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$KEY" -out "$CRT" \
  -days "$DAYS" -extensions v3 -config "$CFG" >/dev/null 2>&1

chmod 0600 "$KEY"
chmod 0644 "$CRT"

cat <<EOF
Wrote:
  cert: $CRT
  key:  $KEY
SAN:    ${SAN}
Expiry: $(openssl x509 -in "$CRT" -noout -enddate | sed 's/^notAfter=//')

Feed into the maestro chart with:
  helm upgrade --install <release> oci://public.ecr.aws/cardinalhq.io/maestro \\
    --values values-local.yaml \\
    --set maestro.tls.enabled=true \\
    --set maestro.tls.cert.autoGenerate=false \\
    --set-file maestro.tls.cert.crt=$CRT \\
    --set-file maestro.tls.cert.key=$KEY
EOF
