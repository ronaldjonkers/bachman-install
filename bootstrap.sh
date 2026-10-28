#!/usr/bin/env bash
# scripts/bootstrap.sh, het enige shellscript van Bachman (docs/14 stap 2, ADR-020).
#
# Twee manieren om te starten:
#   1. Op een lege Mac, als de gebruiker die Bachman beheert, met één regel (ADR-OLI-1):
#        curl -fsSL https://raw.githubusercontent.com/ronaldjonkers/bachman-install/main/bootstrap.sh | bash
#      Het script staat dan los van de repo (via stdin). Het installeert de Xcode Command Line
#      Tools en Homebrew als ze ontbreken, daarna gh, laat je inloggen bij GitHub in de browser,
#      clonet de private repo naar ~/Developer/Bachman (of $BACHMAN_DIR) en start daar zichzelf
#      opnieuw (exec). Geen token in de URL of het commando.
#   2. Vanuit een clone:  ./scripts/bootstrap.sh [--dry-run]
#
# Idempotent: elke stap controleert eerst of het werk al gedaan is. Logt naar
# ~/bachman-bootstrap.log (nooit de setup-link). Met --dry-run wordt elke stap alleen geprint, ook
# in de one-liner-modus:  curl -fsSL <url> | bash -s -- --dry-run
#
# Alles wordt systeembreed geïnstalleerd (Homebrew, npm -g via Homebrew-node), zodat ook de
# gebruiker bachman-agent, die Ronalds home niet kan lezen, de agent-CLI's kan starten.
#
# Alles staat in main(): bij `curl | bash` leest bash dan eerst het hele script voordat er iets
# draait, en geen enkel commando kan de rest van het script van stdin opeten. Vragen gaan via
# /dev/tty.

set -euo pipefail

main() {
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      echo "gebruik: bootstrap.sh [--dry-run]   (of via stdin: bash -s -- --dry-run)"
      exit 0
      ;;
    *)
      echo "onbekende optie: $arg" >&2
      exit 2
      ;;
  esac
done

LOG="${HOME}/bachman-bootstrap.log"
BACHMAN_DIR="${BACHMAN_DIR:-${HOME}/Developer/Bachman}"
BACHMAN_REPO="${BACHMAN_REPO:-ronaldjonkers/Bachman}"
# Overschrijfbaar voor tests met fakes; in productie de vaste paden.
BREW_BIN="${BACHMAN_BREW_BIN:-/opt/homebrew/bin/brew}"
TTY="${BACHMAN_TTY:-/dev/tty}"
HOMEBREW_INSTALLER="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
CLT_PLACEHOLDER="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
STEP_NO=0
STEP_NAME="start"

FORMULAE=(git gh node pnpm tailscale whisper-cpp ffmpeg tmux fastlane restic)
CASKS=(1password-cli google-chrome 1password)

# Modus: vanuit een clone (pad naar dit script ligt in een Bachman-repo), of los via stdin.
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
REPO_DIR=""
if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]]; then
  candidate="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
  if [[ -f "${candidate}/Cargo.toml" && -d "${candidate}/crates/bachman-cli" ]]; then
    REPO_DIR="$candidate"
  fi
fi
ONE_LINER=0
[[ -z "$REPO_DIR" ]] && ONE_LINER=1

mkdir -p "$(dirname "$LOG")"
touch "$LOG"
trap 'on_error $LINENO' ERR

log "bootstrap gestart (one-liner=${ONE_LINER}, dry-run=${DRY_RUN}, repo=${REPO_DIR:-nog geen})"
if [[ "$ONE_LINER" -eq 1 || -z "${BACHMAN_FROM_ONE_LINER:-}" ]]; then
  say "Dit duurt 15 tot 30 minuten (vooral de Rust-build). De terminal vraagt een paar keer om je wachtwoord en één keer om in te loggen bij GitHub in de browser."
fi

# ---------------------------------------------------------------------------
step "Xcode Command Line Tools"
ensure_clt

step "Homebrew"
ensure_brew

if [[ "$ONE_LINER" -eq 1 ]]; then
  one_liner_phase "$@"
  # Alleen in --dry-run zonder bestaande clone komen we hier: print de rest vanuit dit script.
  REPO_DIR="$BACHMAN_DIR"
fi

# ---------------------------------------------------------------------------
step "Homebrew-formules: ${FORMULAE[*]}"
for f in "${FORMULAE[@]}"; do
  brew_formula "$f"
done

step "Homebrew-casks: ${CASKS[*]}"
for c in "${CASKS[@]}"; do
  brew_cask "$c"
done

# ---------------------------------------------------------------------------
step "rustup met stable toolchain (clippy, rustfmt) en target wasm32-unknown-unknown"
brew_formula rustup
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "  [dry-run] rustup toolchain install stable --profile minimal --component clippy --component rustfmt"
  log "  [dry-run] rustup default stable"
  log "  [dry-run] rustup target add wasm32-unknown-unknown"
else
  export PATH="/opt/homebrew/opt/rustup/bin:${HOME}/.cargo/bin:${PATH}"
  have rustup || fail "rustup niet gevonden na installatie; open een nieuwe terminal en draai het script opnieuw"
  run rustup toolchain install stable --profile minimal --component clippy --component rustfmt
  run rustup default stable
  run rustup target add wasm32-unknown-unknown
  log "  $(rustc --version), $(cargo --version)"
fi

# ---------------------------------------------------------------------------
# Agent-CLI's, systeembreed. Methode volgens de officiële documentatie op 2026-10-27; elk blok
# noemt de bron en controleert met --version. Geen installer-pipes naar een shell: alles via Homebrew of npm -g
# (npm van de Homebrew-node, prefix /opt/homebrew), dus ook leesbaar voor bachman-agent.

# Claude Code: Homebrew-cask, https://code.claude.com/docs/en/setup ("brew install --cask claude-code")
step "Agent-CLI claude (bron: https://code.claude.com/docs/en/setup)"
brew_cask claude-code
check_cli claude

# Codex CLI: Homebrew-formule `codex`, https://learn.chatgpt.com/docs/codex/cli (tab Homebrew)
step "Agent-CLI codex (bron: https://learn.chatgpt.com/docs/codex/cli)"
brew_formula codex
check_cli codex

# Kimi Code CLI: npm -g, https://www.kimi.com/code/docs/kimi-code-cli/guides/getting-started.html
# ("npm install -g @moonshot-ai/kimi-code"; de curl-installer zet hem alleen in de eigen home)
step "Agent-CLI kimi (bron: https://www.kimi.com/code/docs/kimi-code-cli/guides/getting-started.html)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "  [dry-run] npm install -g @moonshot-ai/kimi-code (overgeslagen als 'kimi --version' al werkt)"
elif have kimi; then
  log "  kimi: al aanwezig"
else
  run npm install -g @moonshot-ai/kimi-code
fi
check_cli kimi

# ---------------------------------------------------------------------------
GATEWAY_DEPLOY="${REPO_DIR}/target/gateway-deploy"

step "Repo bouwen: cargo build --release --workspace (het langste deel, 10 tot 20 minuten)"
if [[ "$DRY_RUN" -eq 1 && ! -d "$REPO_DIR" ]]; then
  log "  [dry-run] cd ${REPO_DIR}"
else
  cd "$REPO_DIR"
fi
run cargo build --release --workspace

step "Gateway bouwen: pnpm -C apps/wa-gateway install && pnpm -C apps/wa-gateway build"
run pnpm -C apps/wa-gateway install
run pnpm -C apps/wa-gateway build

step "Gateway als zelfstandige kopie met lockfile-versies: pnpm deploy naar ${GATEWAY_DEPLOY}"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "  [dry-run] rm -rf ${GATEWAY_DEPLOY}"
  log "  [dry-run] pnpm --filter @bachman/wa-gateway deploy --prod --legacy ${GATEWAY_DEPLOY}"
  log "  [dry-run] cp -R apps/wa-gateway/dist ${GATEWAY_DEPLOY}/dist"
else
  run rm -rf "$GATEWAY_DEPLOY"
  run pnpm --filter @bachman/wa-gateway deploy --prod --legacy "$GATEWAY_DEPLOY"
  # pnpm deploy volgt de npm-pakregels en laat het gitignored `dist/` weg; apart erbij.
  run rm -rf "${GATEWAY_DEPLOY}/dist"
  run cp -R apps/wa-gateway/dist "${GATEWAY_DEPLOY}/dist"
  [[ -f "${GATEWAY_DEPLOY}/dist/main.js" && -d "${GATEWAY_DEPLOY}/node_modules" ]] || fail "gateway-deploy onvolledig"
fi

step "Webinterface bouwen: cargo-leptos 0.3.11 en cargo leptos build --project bachman-web --release"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "  [dry-run] cargo install cargo-leptos --version 0.3.11 --locked (overgeslagen als die versie er al is)"
  log "  [dry-run] rustup target add wasm32-unknown-unknown"
  log "  [dry-run] cargo leptos build --project bachman-web --release"
else
  if cargo leptos --version 2>/dev/null | grep -q "0\.3\.11"; then
    log "  cargo-leptos 0.3.11: al aanwezig"
  else
    run cargo install cargo-leptos --version 0.3.11 --locked
  fi
  run rustup target add wasm32-unknown-unknown
  run cargo leptos build --project bachman-web --release
  [[ -d target/site/pkg ]] || fail "target/site/pkg ontbreekt na cargo leptos build"
fi

# ---------------------------------------------------------------------------
# Tailscale is niet nodig om te beginnen (ADR-020), wel aanbevolen voor de telefoon. Mislukt het
# starten van de daemon, dan gaat de installatie door.
step "Tailscale-daemon starten (aanbevolen, niet nodig om te beginnen): sudo brew services start tailscale"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "  [dry-run] sudo brew services start tailscale"
else
  run sudo brew services start tailscale || log "  waarschuwing: Tailscale-daemon niet gestart; later via de wizard (Later, Tailscale)"
fi

step "Installeren als root: sudo ./target/release/bachman install --repo \"${REPO_DIR}\" --no-setup-url"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "  [dry-run] sudo ./target/release/bachman install --repo ${REPO_DIR} --no-setup-url"
else
  [[ -x ./target/release/bachman ]] || fail "./target/release/bachman ontbreekt na de build"
  run sudo ./target/release/bachman install --repo "$REPO_DIR" --no-setup-url
fi

step "Controle: agent-CLI's werken als bachman-agent"
for cli in claude codex kimi; do
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] sudo -u bachman-agent -H ${cli} --version"
  else
    run sudo -u bachman-agent -H "$cli" --version
  fi
done

# ---------------------------------------------------------------------------
# De setup-link bevat een eenmalig token (ADR-OLI-2): alleen naar de terminal en de browser,
# nooit naar het log.
step "Wizard openen op deze Mac (eenmalige setup-link, 24 uur geldig)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "  [dry-run] sudo /opt/bachman/bin/bachman setup-url (de link komt alleen in de terminal, niet in het log)"
  log "  [dry-run] open http://127.0.0.1:7420/setup?token=<verborgen>"
else
  setup_link=""
  if setup_link="$(sudo /opt/bachman/bin/bachman setup-url)"; then
    say ""
    say "Wizard op deze Mac (eenmalig, 24 uur geldig):"
    say "  ${setup_link}"
    log "  setup-link getoond (niet gelogd)"
    open "$setup_link" || log "  waarschuwing: browser niet geopend; open de link hierboven zelf"
  else
    log "  geen setup-link (wizard al klaar?); open de webinterface via Tailscale"
  fi
  setup_link=""
fi

step "WhatsApp koppelen"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "  [dry-run] sudo /opt/bachman/bin/bachman whatsapp pair (QR in de terminal, alleen als dat commando bestaat; anders via de wizard)"
elif /opt/bachman/bin/bachman whatsapp pair --help >/dev/null 2>&1; then
  say "Scan de QR-code met WhatsApp op de telefoon met het Bachman-nummer (Gekoppelde apparaten, Apparaat koppelen)."
  # De terminal van Ronald als stdin is bedoeld; sudo hoeft die niet te openen.
  # shellcheck disable=SC2024
  sudo /opt/bachman/bin/bachman whatsapp pair <"$TTY" || log "  waarschuwing: koppelen in de terminal mislukt; gebruik de wizard"
else
  log "  koppel WhatsApp in de wizard (stap WhatsApp)"
fi

log "bootstrap klaar (${STEP_NO} stappen). Log: ${LOG}"
say "Nog nodig om te beginnen: GitHub, Claude Code, WhatsApp en Eigenaar in de wizard. Daarna meldt de wizard: Bachman kan aan de slag."
}

# ---------------------------------------------------------------------------
# Hulpfuncties

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  echo "$line"
  echo "$line" >>"$LOG"
}

# Alleen naar de terminal (bijvoorbeeld de setup-link), nooit naar het log.
say() {
  echo "$*"
}

step() {
  STEP_NO=$((STEP_NO + 1))
  STEP_NAME="$*"
  log "STAP ${STEP_NO}: $*"
}

on_error() {
  local code=$?
  log "FOUT in stap ${STEP_NO} (${STEP_NAME}), regel ${1}, exitcode ${code}. Log: ${LOG}"
  exit "$code"
}

# Voert een commando uit, of print het alleen bij --dry-run.
run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] $*"
    return 0
  fi
  log "  \$ $*"
  "$@" 2>&1 | tee -a "$LOG"
  return "${PIPESTATUS[0]}"
}

# Interactief commando: stdin van de terminal, uitvoer niet via tee (vragen blijven zichtbaar).
run_tty() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] $*"
    return 0
  fi
  log "  \$ $*"
  "$@" <"$TTY"
}

have() { command -v "$1" >/dev/null 2>&1; }

fail() {
  log "FOUT: $*"
  exit 1
}

# Xcode Command Line Tools. Zelfde route als de officiële Homebrew-installer
# (https://github.com/Homebrew/install, install.sh): zonder venster via softwareupdate met een
# placeholder-bestand; lukt dat niet, dan `xcode-select --install` (venster) en wachten tot
# `xcode-select -p` slaagt.
ensure_clt() {
  if xcode-select -p >/dev/null 2>&1; then
    log "  Xcode CLT: $(xcode-select -p)"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] sudo touch ${CLT_PLACEHOLDER}"
    log "  [dry-run] softwareupdate -l (label 'Command Line Tools' zoeken) en sudo softwareupdate -i <label>"
    log "  [dry-run] sudo xcode-select --switch /Library/Developer/CommandLineTools"
    log "  [dry-run] terugval: xcode-select --install en wachten tot xcode-select -p slaagt"
    return 0
  fi
  log "  Xcode CLT ontbreken; installeren via softwareupdate (kan 5 tot 15 minuten duren)"
  sudo touch "$CLT_PLACEHOLDER"
  local label
  label="$(softwareupdate -l 2>/dev/null | grep -B 1 -E 'Command Line Tools' | awk -F'*' '/^ *\*/ {print $2}' | sed -e 's/^ *Label: //' -e 's/^ *//' | sort -V | tail -n1 || true)"
  if [[ -n "$label" ]]; then
    run sudo softwareupdate -i "$label" || log "  waarschuwing: softwareupdate faalde, terugval op xcode-select --install"
  fi
  sudo rm -f "$CLT_PLACEHOLDER"
  if ! xcode-select -p >/dev/null 2>&1; then
    log "  \$ xcode-select --install (er opent een venster: kies Installeer)"
    xcode-select --install >/dev/null 2>&1 || true
    local waited=0
    until xcode-select -p >/dev/null 2>&1; do
      if [[ "$waited" -ge 3600 ]]; then
        fail "Xcode Command Line Tools na een uur nog niet klaar; installeer ze en draai het script opnieuw"
      fi
      sleep 10
      waited=$((waited + 10))
    done
  fi
  sudo xcode-select --switch /Library/Developer/CommandLineTools 2>/dev/null || true
  log "  Xcode CLT: $(xcode-select -p)"
}

# Homebrew met de officiële installer (https://brew.sh). Die vraagt Ronalds wachtwoord; stdin
# komt van de terminal, anders schakelt hij over op NONINTERACTIVE en weigert hij sudo.
ensure_brew() {
  if [[ -x "$BREW_BIN" ]]; then
    eval "$("$BREW_BIN" shellenv)"
  fi
  if have brew; then
    log "  Homebrew: $(command -v brew)"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] /bin/bash -c \"\$(curl -fsSL ${HOMEBREW_INSTALLER})\" (officiële installer, vraagt je wachtwoord)"
    log "  [dry-run] eval \"\$(/opt/homebrew/bin/brew shellenv)\""
    return 0
  fi
  log "  \$ /bin/bash -c \"\$(curl -fsSL ${HOMEBREW_INSTALLER})\""
  /bin/bash -c "$(curl -fsSL "$HOMEBREW_INSTALLER")" <"$TTY"
  [[ -x "$BREW_BIN" ]] || fail "Homebrew niet gevonden op ${BREW_BIN} na installatie"
  eval "$("$BREW_BIN" shellenv)"
  log "  Homebrew: $(command -v brew)"
}

# brew_formula <naam>: installeert als hij ontbreekt.
brew_formula() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] brew install $1 (overgeslagen als al aanwezig)"
  elif brew list --formula -1 2>/dev/null | grep -qx "$1"; then
    log "  $1: al aanwezig"
  else
    run brew install "$1"
  fi
}

brew_cask() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] brew install --cask $1 (overgeslagen als al aanwezig)"
  elif brew list --cask -1 2>/dev/null | grep -qx "$1"; then
    log "  $1: al aanwezig"
  else
    run brew install --cask "$1"
  fi
}

check_cli() {
  # $1 commando
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] $1 --version"
    return 0
  fi
  hash -r
  if have "$1"; then
    log "  $1 --version: $("$1" --version 2>&1 | head -n 1)"
  else
    fail "$1 niet gevonden na installatie; open een nieuwe terminal (PATH) en draai het script opnieuw"
  fi
}

# One-liner-modus: gh, inloggen bij GitHub, de private repo clonen en het script uit de clone
# starten. Keert alleen terug in --dry-run zonder bestaande clone.
one_liner_phase() {
  step "GitHub CLI (gh)"
  if have gh; then
    log "  gh: $(command -v gh)"
  else
    brew_formula gh
  fi

  step "Inloggen bij GitHub (browser, geen token in het commando)"
  if have gh && gh auth status --hostname github.com >/dev/null 2>&1; then
    log "  gh: al ingelogd"
  else
    say "Er opent een browser. Log in bij GitHub met het account dat toegang heeft tot ${BACHMAN_REPO} en vul de code uit de terminal in."
    run_tty gh auth login --hostname github.com --web --git-protocol https
  fi
  run gh auth setup-git --hostname github.com

  step "Repo clonen naar ${BACHMAN_DIR}"
  if [[ -d "${BACHMAN_DIR}/.git" ]]; then
    log "  ${BACHMAN_DIR}: al aanwezig"
    run git -C "$BACHMAN_DIR" pull --ff-only || log "  waarschuwing: git pull lukte niet; verder met de bestaande clone"
  else
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  [dry-run] mkdir -p $(dirname "$BACHMAN_DIR")"
    else
      mkdir -p "$(dirname "$BACHMAN_DIR")"
    fi
    run gh repo clone "$BACHMAN_REPO" "$BACHMAN_DIR"
  fi

  step "Verder met het script uit de clone"
  local next="${BACHMAN_DIR}/scripts/bootstrap.sh"
  if [[ -f "$next" ]]; then
    log "  -> exec ${next} $* (verder in de clone)"
    export BACHMAN_FROM_ONE_LINER=1
    exec bash "$next" "$@" </dev/null
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] exec ${next} $* (na de clone; hieronder de rest vanuit dit script)"
    return 0
  fi
  fail "${next} ontbreekt na de clone"
}

main "$@"
