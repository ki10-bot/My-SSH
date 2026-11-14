#!/bin/bash
cd "$(dirname "$0")" || exit 1
if [[ ! -f "control-panel/config.json" ]]; then
  echo "Kein config.json — bitte zuerst gen.command ausführen"
  read -p "Enter..."
  exit 1
fi
echo "Starte Control Panel..."
# Finde freien Port
PORT=8787
for p in 8787 8788 8789 8888 8000; do
  if ! lsof -i :$p >/dev/null 2>&1; then PORT=$p; break; fi
done
echo "http://localhost:$PORT"
python3 control-panel/server.py $PORT &
PID=$!
sleep 1
# Öffne Browser
if command -v open >/dev/null 2>&1; then open "http://localhost:$PORT"; fi
echo "Control Panel läuft (PID $PID) — CTRL+C zum Beenden"
wait $PID
