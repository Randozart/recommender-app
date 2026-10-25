#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

compiler="${BRIEVC:-brievc}"
stdlib_dir="${BRIEV_STDLIB:-}"
dataset_dir="${MOVIELENS_DIR:-}"
data_file="${UDATA_PATH:-${dataset_dir:+$dataset_dir/u.data}}"
item_file="${UITEM_PATH:-${dataset_dir:+$dataset_dir/u.item}}"
db_user="${PGUSER:-briev_test}"
db_name="${PGDATABASE:-briev_recommender_test}"
backend_port="${PORT:-8080}"
frontend_port="${FRONTEND_PORT:-8081}"
backend_out="$repo_root/target/recommender-demo"
frontend_out="$repo_root/target/recommender-web"

command -v "$compiler" >/dev/null 2>&1 || {
    echo "Briev compiler not found. Set BRIEVC to its executable path." >&2
    exit 1
}
[[ -n "$stdlib_dir" && -d "$stdlib_dir" ]] || {
    echo "Set BRIEV_STDLIB to the compatible Briev lib/std directory." >&2
    exit 1
}
command -v python3 >/dev/null 2>&1 || {
    echo "Required command not found: python3" >&2
    exit 1
}
[[ -n "$data_file" && -f "$data_file" ]] || {
    echo "Set UDATA_PATH or MOVIELENS_DIR to the MovieLens u.data file." >&2
    exit 1
}
[[ -n "$item_file" && -f "$item_file" ]] || {
    echo "Set UITEM_PATH or MOVIELENS_DIR to the MovieLens u.item file." >&2
    exit 1
}

mkdir -p "$backend_out" "$frontend_out"
echo "Building recommender backend..."
"$compiler" build examples/recommender/server.bv --stdlib-path "$stdlib_dir" --out "$backend_out"
echo "Building browser frontend..."
"$compiler" build examples/recommender/app.rbv --stdlib-path "$stdlib_dir" --split --out "$frontend_out"

backend="$backend_out/server"
[[ -x "$backend" ]] || {
    echo "Backend executable was not produced at $backend" >&2
    exit 1
}

export PGUSER="$db_user" PGDATABASE="$db_name"
export UDATA_PATH="$data_file" UITEM_PATH="$item_file" PORT="$backend_port"
python3 -m http.server "$frontend_port" --bind 127.0.0.1 --directory "$frontend_out" &
http_pid=$!
cleanup() {
    kill "$http_pid" 2>/dev/null || true
    wait "$http_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Frontend: http://localhost:$frontend_port/app.html"
echo "Backend:  http://127.0.0.1:$backend_port"
echo "Database: $db_user@$db_name (local PostgreSQL on 127.0.0.1:5432)"
echo "Keep this terminal open; press Ctrl+C to stop the demo."
"$backend"
