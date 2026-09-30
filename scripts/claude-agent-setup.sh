#!/usr/bin/env bash
#
# claude-agent-setup.sh — install third-party Claude Code tooling alongside
# Headroom's rtk hook registration, in an order that keeps both working.
#
# Background
# ----------
# `scripts/install.sh` installs rtk to ~/.headroom/bin/rtk and then runs
# `rtk init --global --auto-patch`, which registers rtk's hooks in
# ~/.claude/settings.json. Shell commands issued by the agent are filtered by
# that hook, which is what AGENTS.md's "always prefix with rtk" rule relies on.
#
# The awesome-claude-code-setup kit (cassler/awesome-claude-code-setup) writes
# its own ~/.claude/settings.json, but only when that file does not already
# exist. So the install order decides which hook configuration survives:
#
#   rtk first, kit second  -> kit sees an existing settings.json and skips it.
#                             rtk's hooks stay intact. This is what we want.
#   kit first, rtk second  -> rtk auto-patches a settings.json that already
#                             carries the kit's post-edit/notify hooks.
#
# This script enforces the first order and refuses to run the kit blind.
#
# It also replaces the kit's 54-line global ~/.claude/CLAUDE.md with a compact
# version. That file is loaded into every session in every project, so its cost
# is paid continuously; the long-form category and tool listings it ships are
# discoverable on demand via `ch help` instead.
#
# Usage:
#   scripts/claude-agent-setup.sh [--skip-kit] [--dry-run]
#
set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
RTK_BIN="${HOME}/.headroom/bin/rtk"
KIT_URL="https://raw.githubusercontent.com/cassler/awesome-claude-code-setup/main/setup.sh"

SKIP_KIT=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --skip-kit) SKIP_KIT=1 ;;
    --dry-run)  DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

log()  { printf '  %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] $*"
  else
    "$@"
  fi
}

# --- Step 1: rtk must be registered before the kit runs ---------------------

echo "==> Checking rtk hook registration"

if [[ ! -x "$RTK_BIN" ]]; then
  die "rtk is not installed at ${RTK_BIN}.
Run Headroom's installer first so rtk registers its Claude hooks:

    scripts/install.sh

Then re-run this script. Installing the kit before rtk leaves rtk
auto-patching a settings.json that already carries the kit's hooks."
fi

log "rtk found at ${RTK_BIN}"

# `rtk init` is idempotent; re-running guarantees the hooks are present even if
# a previous kit install or a hand edit removed them.
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "[dry-run] ${RTK_BIN} init --global --auto-patch"
elif "$RTK_BIN" init --global --auto-patch >/dev/null 2>&1; then
  log "rtk hooks registered in ${CLAUDE_DIR}/settings.json"
else
  warn "rtk init failed; continuing, but verify hooks manually with 'rtk init --global'"
fi

# --- Step 2: install the third-party kit ------------------------------------

if [[ "$SKIP_KIT" -eq 1 ]]; then
  echo "==> Skipping awesome-claude-code-setup (--skip-kit)"
else
  echo "==> Installing awesome-claude-code-setup"

  if [[ -f "${CLAUDE_DIR}/settings.json" ]]; then
    log "settings.json exists; kit will preserve it (expected)"
  else
    warn "no settings.json yet — the kit will install its own hook config.
    Re-run 'rtk init --global --auto-patch' afterwards to restore rtk's hooks."
  fi

  kit_script="$(mktemp -t claude-kit-setup.XXXXXX.sh)"
  trap 'rm -f "$kit_script"' EXIT

  curl -fsSL -o "$kit_script" "$KIT_URL" \
    || die "failed to download the kit installer from ${KIT_URL}"

  # The upstream installer runs with `set +e` and prompts on stdin; closing
  # stdin makes every prompt take its default (yes) without hanging.
  run bash "$kit_script" </dev/null
fi

# --- Step 3: trim the global CLAUDE.md --------------------------------------

echo "==> Trimming global CLAUDE.md"

claude_md="${CLAUDE_DIR}/CLAUDE.md"

if [[ ! -f "$claude_md" ]]; then
  log "no ${claude_md}; nothing to trim"
else
  before_lines="$(wc -l < "$claude_md" | tr -d ' ')"
  backup="${claude_md}.pre-trim.$(date +%Y%m%d_%H%M%S)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would back up to ${backup} and rewrite (${before_lines} lines)"
  else
    cp "$claude_md" "$backup"

    # Preserve anything the user added under <ch:user-customizations>.
    user_block=""
    if grep -q '<ch:user-customizations>' "$claude_md"; then
      user_block="$(
        sed -n '/<ch:user-customizations>/,/<\/ch:user-customizations>/p' "$claude_md" \
          | sed '1d;$d'
      )"
    fi

    cat > "$claude_md" <<'EOF'
# Claude helper scripts

<ch:aliases>
ch   -> helper entrypoint; run `ch help` or `ch <category> help` for the
        full command list. Do not inline that listing here — it is only
        needed at the moment a helper is used.
chp  -> project overview
chs  -> code search
</ch:aliases>

<ch:rtk-precedence>
rtk filters shell output via its globally registered Claude hook, so helper
commands are compressed without an explicit `rtk` prefix. Do not wrap helper
invocations in `rtk proxy ...`; that double-handles output already filtered by
the hook. Prefix raw shell commands with `rtk` as AGENTS.md describes.
</ch:rtk-precedence>

<ch:user-customizations>
EOF

    if [[ -n "$user_block" ]]; then
      printf '%s\n' "$user_block" >> "$claude_md"
    fi

    printf '%s\n' '</ch:user-customizations>' >> "$claude_md"

    after_lines="$(wc -l < "$claude_md" | tr -d ' ')"
    log "rewrote ${claude_md}: ${before_lines} -> ${after_lines} lines"
    log "backup at ${backup}"
  fi
fi

# --- Step 4: verify ---------------------------------------------------------

echo "==> Verifying"

if [[ -f "${CLAUDE_DIR}/settings.json" ]]; then
  if grep -q 'rtk' "${CLAUDE_DIR}/settings.json" 2>/dev/null; then
    log "OK: rtk hooks present in settings.json"
  else
    warn "settings.json has no rtk reference. Re-run:
    ${RTK_BIN} init --global --auto-patch"
  fi
else
  warn "no ${CLAUDE_DIR}/settings.json found"
fi

[[ -d "${CLAUDE_DIR}/scripts" ]]  && log "OK: helper scripts in ${CLAUDE_DIR}/scripts"
[[ -d "${CLAUDE_DIR}/commands" ]] && log "OK: slash commands in ${CLAUDE_DIR}/commands"

echo
echo "Done. Reload your shell to pick up the helper aliases:"
echo "    source ~/.zshrc   # or ~/.bashrc"
