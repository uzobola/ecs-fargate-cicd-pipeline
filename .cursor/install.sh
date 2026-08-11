#!/usr/bin/env bash
# Idempotent Cloud Agent bootstrap for the ECS Fargate CI/CD sample apps.
#
# The frontend and backend intentionally pin different Node.js majors, so both
# runtimes are installed via nvm and each app's dependencies are installed with
# the runtime it actually targets:
#   backend  -> Node 24      (Express; see backend/.nvmrc and backend/Dockerfile)
#   frontend -> Node 16.20.2 (CRA / react-scripts 4; see frontend/.nvmrc)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

BACKEND_NODE="24"
FRONTEND_NODE="16.20.2"

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"

nvm install "$BACKEND_NODE"
nvm install "$FRONTEND_NODE"

echo "==> Installing backend dependencies (Node ${BACKEND_NODE})"
( cd "$REPO_ROOT/backend" && nvm exec "$BACKEND_NODE" npm ci )

echo "==> Installing frontend dependencies (Node ${FRONTEND_NODE})"
# --legacy-peer-deps matches the committed lockfile (see frontend/Dockerfile).
( cd "$REPO_ROOT/frontend" && nvm exec "$FRONTEND_NODE" npm ci --legacy-peer-deps )

echo "==> Dependency installation complete."
