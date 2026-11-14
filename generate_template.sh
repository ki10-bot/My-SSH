#!/bin/bash
# Symlink/Wrapper for generate_template.command (for terminal users who prefer .sh)
# Usage: ./generate_template.sh  or  bash generate_template.sh
exec "$(dirname "$0")/generate_template.command" "$@"
