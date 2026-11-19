#!/usr/bin/env bash
# Run both suites against a live VM.
#   BXC_SANDBOX_ID=sbx_... ./tests/run.sh
# Needs: node>=18, nvim>=0.10, chafa, and a BoxCompute API key (see README > Auth).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

: "${BXC_SANDBOX_ID:?set BXC_SANDBOX_ID to a large (desktop-capable) sandbox}"
export BXC_HOME="${BXC_HOME:-$HOME/.omp/bxc}"
export BXC_SANDBOX_ID

echo "== MCP server suite =="
node tests/mcp-smoke.mjs || fail=1

echo
echo "== plugin UI suite =="
nvim --headless --clean -l tests/ui-smoke.lua || fail=1

echo
if [[ "${fail:-0}" == "0" ]]; then
  echo "both suites passed"
else
  echo "at least one suite failed"
  exit 1
fi
