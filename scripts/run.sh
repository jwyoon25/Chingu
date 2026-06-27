#!/usr/bin/env bash
#
# Loads local demo secrets from .env and launches Chingu.
#
# Secrets live in .env (gitignored) — NOT in source, NOT committed. This script
# exports them into the environment so the app can read them via
# ProcessInfo.processInfo.environment. It never prints key values.
#
# Usage:  ./scripts/run.sh            # build + run
#         ./scripts/run.sh build      # build only
#
set -euo pipefail

# Resolve the repo root from this script's location, so it works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="$ROOT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  # `set -a` marks every variable assigned while sourcing for export, so the
  # KEY=value lines in .env become environment variables for `swift run`.
  # We source rather than parse so quoting/`#` comments behave like a shell file.
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "note: no .env found at $ENV_FILE"
  echo "      copy .env.example to .env and fill in your keys, or export them in your shell."
  echo "      (Chingu will still launch; it shows an in-app setup message until keys are set.)"
fi

# Report only PRESENCE, never the value — so logs/CI output can't leak a key.
report_presence() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    echo "  $name: set"
  else
    echo "  $name: (not set)"
  fi
}
echo "secrets:"
report_presence ANTHROPIC_API_KEY
report_presence ELEVENLABS_API_KEY

if [[ "${1:-run}" == "build" ]]; then
  exec swift build
else
  exec swift run Chingu
fi
