#!/usr/bin/env bash
# Dependencias: Python 3.9+, AWS CLI e Terraform.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/scripts/cleanup-lab.py" --environment "${ENV:-dev}" "$@"
