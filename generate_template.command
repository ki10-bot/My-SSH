#!/bin/bash
# RemoteGate — GENERATE TEMPLATE (Mac Finder double-click)
# ➡️  DOPPELKLICK HIER → Wizard startet (auf Mac generiert!)
# This is the entry point "arrow" — directly at repo root, no searching.
#
# What it does:
#   cd to repo, run generator/generate.sh (bash, no PowerShell needed)
#   or generator/New-RemoteGateDeployment.ps1 if pwsh available
#
# Double-click in Finder → Terminal opens → wizard prompts
# Or terminal: ./generate_template.command

# Ensure we run from repo root (where this file lives)
cd "$(dirname "$0")" || exit 1
REPO_ROOT="$(pwd)"

# Colors
GREEN='\033[32m'
CYAN='\033[36m'
YELLOW='\033[33m'
RESET='\033[0m'

echo -e "${CYAN}"
echo "  ➡️  RemoteGate — GENERATE_TEMPLATE.command"
echo "  Doppelklick erkannt — starte Generator (Mac)…"
echo -e "${RESET}"
echo "Repo: $REPO_ROOT"
echo ""

# Check template exists
if [[ ! -f "$REPO_ROOT/templates/RemoteGate-Deployment.template.ps1" ]]; then
  echo -e "${YELLOW}Fehler: templates/RemoteGate-Deployment.template.ps1 nicht gefunden${RESET}"
  echo "Hast du das komplette Repo heruntergeladen? (git clone ...)"
  read -p "Enter zum Schließen…" _
  exit 1
fi

# Prefer bash generator (works everywhere on Mac without pwsh)
GENERATOR_SH="$REPO_ROOT/generator/generate.sh"
GENERATOR_PS="$REPO_ROOT/generator/New-RemoteGateDeployment.ps1"

# Ensure executable
chmod +x "$GENERATOR_SH" 2>/dev/null || true

# If launched from Finder, Terminal may close quickly — keep open on error
KEEP_OPEN=true

# Try PowerShell Core first (if installed, more features), then bash
if command -v pwsh &>/dev/null && [[ -f "$GENERATOR_PS" ]]; then
  echo -e "${GREEN}→ Starte PowerShell Wizard (pwsh gefunden)…${RESET}"
  echo "  (Bash geht auch: bash generator/generate.sh)"
  read -p "PowerShell (p) oder Bash (b) nutzen? [b]: " choice
  if [[ "$choice" == "p" || "$choice" == "P" ]]; then
    pwsh -File "$GENERATOR_PS"
    STATUS=$?
  else
    bash "$GENERATOR_SH"
    STATUS=$?
  fi
elif [[ -f "$GENERATOR_SH" ]]; then
  echo -e "${GREEN}→ Starte Bash Wizard (Mac, kein PowerShell nötig)…${RESET}"
  bash "$GENERATOR_SH"
  STATUS=$?
elif [[ -f "$GENERATOR_PS" ]] && command -v powershell &>/dev/null; then
  echo -e "${GREEN}→ Starte PowerShell Wizard…${RESET}"
  powershell -File "$GENERATOR_PS"
  STATUS=$?
else
  echo -e "${YELLOW}Kein Generator gefunden — versuche direkt bash…${RESET}"
  bash "$GENERATOR_SH" 2>/dev/null || {
    echo "Fehler: generator/generate.sh fehlt"
    read -p "Enter zum Schließen…" _
    exit 1
  }
  STATUS=$?
fi

echo ""
if [[ $STATUS -eq 0 ]]; then
  echo -e "${GREEN}✅ Fertig! Prüfe dist/RemoteGate-Final.ps1 und Yandex URL oben.${RESET}"
else
  echo -e "${YELLOW}Wizard beendet mit Code $STATUS — Logs oben prüfen.${RESET}"
fi

if [[ "$KEEP_OPEN" == "true" ]]; then
  echo ""
  read -p "Enter zum Schließen…" _
fi
exit $STATUS
