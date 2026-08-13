#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build_dir=${REQUEST_BUILD_DIR:-"$project_dir/build"}
test_dir=$(mktemp -d)
http_port=${REQUEST_TEST_HTTP_PORT:-0}
https_port=${REQUEST_TEST_HTTPS_PORT:-0}
mtls_port=${REQUEST_TEST_MTLS_PORT:-0}
http_pid=
https_pid=
mtls_pid=

cleanup() {
    if [[ -n "$http_pid" ]]; then
        kill "$http_pid" 2>/dev/null || true
        wait "$http_pid" 2>/dev/null || true
    fi
    if [[ -n "$https_pid" ]]; then
        kill "$https_pid" 2>/dev/null || true
        wait "$https_pid" 2>/dev/null || true
    fi
    if [[ -n "$mtls_pid" ]]; then
        kill "$mtls_pid" 2>/dev/null || true
        wait "$mtls_pid" 2>/dev/null || true
    fi
    rm -rf "$test_dir"
}

trap cleanup EXIT

cmake -S "$project_dir" -B "$build_dir" -DCMAKE_BUILD_TYPE=Debug
cmake --build "$build_dir" --parallel

cat >"$test_dir/openssl.cnf" <<'EOF'
[req]
distinguished_name = distinguished_name
x509_extensions = extensions
prompt = no

[distinguished_name]
CN = localhost

[extensions]
subjectAltName = DNS:localhost
EOF

openssl req \
    -x509 \
    -newkey rsa:2048 \
    -nodes \
    -keyout "$test_dir/server.key" \
    -out "$test_dir/server.crt" \
    -days 1 \
    -config "$test_dir/openssl.cnf" \
    >/dev/null 2>&1

python3 "$project_dir/tests/fixtures/server.py" \
    --port "$http_port" \
    >"$test_dir/http.log" 2>&1 &
http_pid=$!

python3 "$project_dir/tests/fixtures/server.py" \
    --host 127.0.0.1 \
    --port "$https_port" \
    --cert "$test_dir/server.crt" \
    --key "$test_dir/server.key" \
    >"$test_dir/https.log" 2>&1 &
https_pid=$!

python3 "$project_dir/tests/fixtures/server.py" \
    --host 127.0.0.1 \
    --port "$mtls_port" \
    --cert "$test_dir/server.crt" \
    --key "$test_dir/server.key" \
    --client-ca "$test_dir/server.crt" \
    >"$test_dir/mtls.log" 2>&1 &
mtls_pid=$!

for _ in $(seq 1 100); do
    if [[ -s "$test_dir/http.log" && -s "$test_dir/https.log" &&
        -s "$test_dir/mtls.log" ]]; then
        break
    fi
    sleep 0.02
done

http_port=$(head -n 1 "$test_dir/http.log")
https_port=$(head -n 1 "$test_dir/https.log")
mtls_port=$(head -n 1 "$test_dir/mtls.log")

if [[ ! "$http_port" =~ ^[0-9]+$ || ! "$https_port" =~ ^[0-9]+$ ||
    ! "$mtls_port" =~ ^[0-9]+$ ]]; then
    cat "$test_dir/http.log"
    cat "$test_dir/https.log"
    cat "$test_dir/mtls.log"
    exit 1
fi

export LUA_PATH="$project_dir/lua/?.lua;$project_dir/lua/?/init.lua;;"
export LUA_CPATH="$build_dir/?.so;$build_dir/?/?.so;;"
export REQUEST_TEST_URL="http://127.0.0.1:$http_port"
export REQUEST_TEST_HTTPS_URL="https://localhost:$https_port"
export REQUEST_TEST_MTLS_URL="https://localhost:$mtls_port"
export REQUEST_TEST_CA_FILE="$test_dir/server.crt"
export REQUEST_TEST_CLIENT_CERT_FILE="$test_dir/server.crt"
export REQUEST_TEST_CLIENT_KEY_FILE="$test_dir/server.key"

cd "$project_dir"
luajit tests/unit_spec.lua
luajit tests/integration_spec.lua
