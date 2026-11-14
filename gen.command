#!/bin/bash
# RemoteGate — Ultra simple
cd "$(dirname "$0")" || exit 1
chmod +x generator/generate.sh 2>/dev/null || true
bash generator/generate.sh
STATUS=$?
echo ""
read -p "Enter zum Schließen… " _
exit $STATUS
