#!/bin/bash
# Spins up a real Cassandra container with TLS + PasswordAuthenticator
# (mirroring how pmsx-infrastructure's common.tf configures the provider:
# use_ssl = true, root_ca = <CA cert>, username/password), builds this
# provider locally, and runs `terraform plan` against it via dev_overrides.
#
# Usage: ./test/tls-smoke-test.sh
# Requires: docker, openssl, go, terraform. Cleans up after itself unless
# KEEP=1 is set in the environment.

set -euo pipefail

CASSANDRA_IMAGE="cassandra:5.0"
CQL_PORT=19045
CONTAINER_NAME="tfp-cassandra-tls-smoke-test"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
TESTDIR="$(mktemp -d)"

cleanup() {
  if [ "${KEEP:-0}" != "1" ]; then
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -rf "$WORKDIR" "$TESTDIR"
  else
    echo "KEEP=1 set, leaving container '$CONTAINER_NAME' running and workdirs:"
    echo "  cassandra config/certs: $WORKDIR"
    echo "  terraform test dir:     $TESTDIR"
  fi
}
trap cleanup EXIT

echo "==> Generating self-signed CA + server cert (with IP SAN for 127.0.0.1)"
cd "$WORKDIR"

cid=$(docker create "$CASSANDRA_IMAGE")
docker cp "$cid:/etc/cassandra/cassandra.yaml" "$WORKDIR/cassandra.yaml"
docker rm "$cid" >/dev/null

openssl req -x509 -newkey rsa:2048 -days 2 -nodes -keyout ca-key.pem -out ca-cert.pem -subj "/CN=test-ca" 2>/dev/null

cat > san.cnf <<'SAN'
[req]
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
subjectAltName = IP:127.0.0.1
SAN

openssl req -newkey rsa:2048 -nodes -keyout server-key.pem -out server-req.pem \
  -subj "/CN=127.0.0.1" -config san.cnf 2>/dev/null
openssl x509 -req -in server-req.pem -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial \
  -out server-cert.pem -days 2 -extfile san.cnf -extensions v3_req 2>/dev/null

openssl pkcs12 -export -in server-cert.pem -inkey server-key.pem -certfile ca-cert.pem \
  -out keystore.p12 -name cassandra -passout pass:cassandra 2>/dev/null
openssl pkcs12 -export -nokeys -in ca-cert.pem -out truststore.p12 -passout pass:cassandra 2>/dev/null

echo "==> Enabling PasswordAuthenticator + TLS (client + internode) in cassandra.yaml"
sed -i.bak 's/^authenticator:.*/authenticator: PasswordAuthenticator/' cassandra.yaml

python3 - "$WORKDIR/cassandra.yaml" <<'EOF'
import re
import sys

# keystore_password/truststore_password are commented out by default in
# some Cassandra versions (e.g. 5.0) but not others (e.g. 4.1), so the
# password line is matched with an optional leading '#'.
path = sys.argv[1]
content = open(path).read()
replacements = [
    (r"(  # Set to a valid keystore if internode_encryption is dc, rack or all\n"
     r"  keystore: )conf/\.keystore\n"
     r"  #?keystore_password: cassandra\n",
     r"\g<1>/keystore.p12\n  keystore_password: cassandra\n  store_type: PKCS12\n"),
    (r"(  # Set to a valid trustore if require_client_auth is true\n"
     r"  truststore: )conf/\.truststore\n"
     r"  #?truststore_password: cassandra\n",
     r"\g<1>/truststore.p12\n  truststore_password: cassandra\n"),
    (r"(client_encryption_options:\n"
     r"  # Enable client-to-server encryption\n"
     r"  enabled: )false\n",
     r"\g<1>true\n  store_type: PKCS12\n"),
    (r"(  # Set keystore and keystore_password to valid keystores if enabled is true\n"
     r"  keystore: )conf/\.keystore\n"
     r"  #?keystore_password: cassandra\n",
     r"\g<1>/keystore.p12\n  keystore_password: cassandra\n"),
    (r"(  # Set trustore and truststore_password if require_client_auth is true\n)"
     r"  # ?truststore: conf/\.truststore\n"
     r"  # ?truststore_password: cassandra\n",
     r"\g<1>  truststore: /truststore.p12\n  truststore_password: cassandra\n"),
]
for pattern, repl in replacements:
    content, count = re.subn(pattern, repl, content, count=1)
    assert count == 1, f"pattern not found (cassandra.yaml format may have changed): {pattern[:60]!r}"
open(path, "w").write(content)
EOF

echo "==> Starting $CASSANDRA_IMAGE on port $CQL_PORT"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER_NAME" \
  -p "$CQL_PORT:9042" \
  -v "$WORKDIR/cassandra.yaml:/etc/cassandra/cassandra.yaml" \
  -v "$WORKDIR/keystore.p12:/keystore.p12" \
  -v "$WORKDIR/truststore.p12:/truststore.p12" \
  "$CASSANDRA_IMAGE" >/dev/null

echo "==> Waiting for CQL to come up (this takes ~1-2 minutes)"
for _ in $(seq 1 40); do
  if docker logs "$CONTAINER_NAME" 2>&1 | grep -qi "Starting listening for CQL clients"; then
    break
  fi
  sleep 5
done
if ! docker logs "$CONTAINER_NAME" 2>&1 | grep -qi "Starting listening for CQL clients"; then
  echo "Cassandra did not become ready in time, check: docker logs $CONTAINER_NAME"
  exit 1
fi
# default superuser role replication needs a few extra seconds after startup
sleep 12

echo "==> Building provider"
cd "$REPO_ROOT"
go build -o terraform-provider-cassandra .

echo "==> Writing Terraform test config (dev_overrides, no init/registry needed)"
cat > "$TESTDIR/dev.tfrc" <<EOF
provider_installation {
  dev_overrides {
    "registry.siteminderlabs.com/siteminder/cassandra" = "$REPO_ROOT"
  }
  direct {}
}
EOF

CA_CERT_JSON=$(python3 -c "import json; print(json.dumps(open('$WORKDIR/ca-cert.pem').read()))")
cat > "$TESTDIR/main.tf" <<EOF
terraform {
  required_providers {
    cassandra = {
      source = "registry.siteminderlabs.com/siteminder/cassandra"
    }
  }
}

provider "cassandra" {
  username = "cassandra"
  password = "cassandra"
  port     = $CQL_PORT
  hosts    = ["127.0.0.1"]
  use_ssl  = true
  root_ca  = $CA_CERT_JSON
}

data "cassandra_version" "test" {}

output "cassandra_version" {
  value = data.cassandra_version.test.version
}
EOF

echo "==> terraform plan"
cd "$TESTDIR"
TF_CLI_CONFIG_FILE="$TESTDIR/dev.tfrc" terraform plan
