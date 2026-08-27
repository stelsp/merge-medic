#!/bin/bash
# merge-medic bootstrap:
#
#   curl -fsSL https://raw.githubusercontent.com/stelsp/merge-medic/main/get.sh | bash
#
# Clones the repo (default: ~/merge-medic, override with MERGE_MEDIC_DIR) and
# hands over to the interactive `mrwatch setup` wizard, which offers to install
# dependencies, walks through the forge/resolver logins, and fills config.env.
# Prefer to read before you pipe? Same thing by hand:
#
#   git clone https://github.com/stelsp/merge-medic && cd merge-medic
#   bin/mrwatch setup
set -euo pipefail

REPO="https://github.com/stelsp/merge-medic"
DIR="${MERGE_MEDIC_DIR:-$HOME/merge-medic}"

case "$(uname -s)" in
  Darwin|Linux) ;;
  *) echo "merge-medic needs macOS, Linux, or Windows via WSL2 (bash + a scheduler)."; exit 1 ;;
esac

command -v git >/dev/null 2>&1 || {
  echo "git is required first — install it (macOS: xcode-select --install; Debian/Ubuntu: sudo apt-get install -y git) and re-run."
  exit 1
}

if [ -d "$DIR/.git" ]; then
  echo "-> $DIR exists, updating"
  git -C "$DIR" pull --ff-only
else
  echo "-> cloning $REPO -> $DIR"
  git clone "$REPO" "$DIR"
fi

# The wizard is interactive; when this script is piped into bash, stdin is the
# script itself — reattach the terminal.
if [ -t 0 ]; then
  bash "$DIR/bin/mrwatch" setup
else
  bash "$DIR/bin/mrwatch" setup < /dev/tty
fi
