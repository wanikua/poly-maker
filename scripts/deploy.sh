#!/usr/bin/env bash
# One-shot deploy for poly-maker: install tooling, clone, configure, verify,
# then start the live bot in the background.
#
# Usage (macOS / Linux / WSL):
#   PK=0x<private-key> BROWSER_ADDRESS=0x<deposit-address> bash deploy.sh
# or:
#   curl -LsSf https://raw.githubusercontent.com/wanikua/poly-maker/claude/polymarket-trading-bot-218da4/scripts/deploy.sh \
#     | PK=0x... BROWSER_ADDRESS=0x... bash
#
# Aborts before going live if doctor, livetest, or moneydoctor fails.
set -euo pipefail

: "${PK:?set PK=0x<private key of the signer wallet>}"
: "${BROWSER_ADDRESS:?set BROWSER_ADDRESS=0x<Polymarket deposit address>}"

BRANCH="${POLYMAKER_BRANCH:-claude/polymarket-trading-bot-218da4}"
REPO="${POLYMAKER_REPO:-https://github.com/wanikua/poly-maker.git}"
DIR="${POLYMAKER_DIR:-$HOME/poly-maker}"

command -v git >/dev/null || { echo "error: git is required"; exit 1; }
command -v curl >/dev/null || { echo "error: curl is required"; exit 1; }

if ! command -v uv >/dev/null; then
  echo "== installing uv =="
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

echo "== fetching code ($BRANCH) =="
if [ -d "$DIR/.git" ]; then
  git -C "$DIR" fetch origin "$BRANCH"
  git -C "$DIR" checkout "$BRANCH"
  git -C "$DIR" pull --ff-only origin "$BRANCH"
else
  git clone -b "$BRANCH" "$REPO" "$DIR"
fi
cd "$DIR"

echo "== installing dependencies =="
uv sync

echo "== writing .env (never committed; file mode 600) =="
umask 077
printf 'PK=%s\nBROWSER_ADDRESS=%s\n' "$PK" "$BROWSER_ADDRESS" > .env

echo "== preflight: doctor =="
uv run polymaker doctor

echo "== preflight: livetest (free — deep post-only order + cancel) =="
uv run polymaker livetest

echo "== preflight: moneydoctor (a few cents — real fill round-trip) =="
uv run polymaker moneydoctor

echo "== starting live bot =="
mkdir -p logs
nohup uv run polymaker run > logs/run.out 2>&1 &
echo $! > polymaker.pid
sleep 5
if ! kill -0 "$(cat polymaker.pid)" 2>/dev/null; then
  echo "error: bot exited immediately — last log lines:"
  tail -20 logs/run.out
  exit 1
fi
tail -5 logs/run.out || true

cat <<DONE

Bot is LIVE (pid $(cat polymaker.pid)).
  status:   cd $DIR && uv run polymaker status
  logs:     tail -f $DIR/logs/run.out
  stop:     kill \$(cat $DIR/polymaker.pid) && cd $DIR && uv run polymaker cancel-all
Note: if this machine sleeps or the process dies, the exchange heartbeat
auto-cancels all resting orders — you are never left quoting unattended.
DONE
