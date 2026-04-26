#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec dart run backend/server.dart
