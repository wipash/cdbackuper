#!/usr/bin/env bash
set -euo pipefail

# This script generates deploy.yaml from deploy.yaml.template by injecting cd-importer.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/cd-importer.sh"
TEMPLATE_FILE="${SCRIPT_DIR}/deploy.yaml.template"
OUTPUT_FILE="${SCRIPT_DIR}/deploy.yaml"

# Check that the script file exists
if [[ ! -f "$SCRIPT_FILE" ]]; then
  echo "Error: $SCRIPT_FILE not found"
  exit 1
fi

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Error: $TEMPLATE_FILE not found"
  exit 1
fi

# Use awk to process the template and inject the script
awk -v script_file="$SCRIPT_FILE" '
/@@SCRIPT_PLACEHOLDER@@/ {
  while ((getline line < script_file) > 0) {
    print "    " line
  }
  close(script_file)
  next
}
{ print }
' "$TEMPLATE_FILE" > "$OUTPUT_FILE"

echo "✓ Generated $OUTPUT_FILE from template"
