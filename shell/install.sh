#!/usr/bin/env bash
# Put gist's manual and completions where each shell already looks.
#
# Everything installed here is minted by `gist --generate` from the same flag
# table the parser dispatches on, so there is no second description of the CLI
# to drift. The artifacts are written once under zig-out/share/ and then
# symlinked into place, which means a rebuild refreshes every install site at
# once — the same arrangement editor/install.sh uses for the Vim plugin.
#
# Only a shell that exists on this machine is touched, an existing real file is
# never replaced with a link, and re-running is a no-op. GIST_SHELL_INSTALL=0
# skips the whole thing.
set -uo pipefail

warn() { printf '\033[0;33m!\033[0m  %s\n' "${1}"; }
note() { printf '\033[0;32m✓\033[0m  %s\n' "${1}"; }

# Announced rather than silent: this runs inside `make install-gist`, where an
# inherited opt-out would otherwise look identical to the feature not existing.
if [[ ${GIST_SHELL_INSTALL:-1} == 0 ]]; then
  warn "GIST_SHELL_INSTALL=0 — leaving the manual and completions uninstalled"
  exit 0
fi

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
gist="${here}/zig-out/bin/gist"
share="${here}/zig-out/share"
[[ -x ${gist} ]] || exit 0

data="${XDG_DATA_HOME:-${HOME}/.local/share}"
conf="${XDG_CONFIG_HOME:-${HOME}/.config}"

# $1 --generate target · $2 path under zig-out/share
mint() {
  local out="${share}/${2}"
  mkdir -p "$(dirname -- "${out}")" || return 1
  "${gist}" --generate "${1}" > "${out}" || return 1
}

# $1 source under zig-out/share · $2 destination path
place() {
  local src="${share}/${1}" dest="${2}"
  if [[ -e ${dest} && ! -L ${dest} ]]; then
    warn "${dest} exists and is not a symlink — leaving it alone"
    return 1
  fi
  mkdir -p "$(dirname -- "${dest}")" && ln -sfn "${src}" "${dest}"
}

# ── the manual ───────────────────────────────────────────────────────────
if mint man man/man1/gist.1 && place man/man1/gist.1 "${data}/man/man1/gist.1"; then
  note "man: gist(1) → ${data}/man/man1/gist.1"
  case ":$(manpath 2> /dev/null):" in
    *":${data}/man:"*) ;;
    *) warn "  ${data}/man is not on your manpath — add it to \$MANPATH" ;;
  esac
fi

# ── zsh ──────────────────────────────────────────────────────────────────
# Prefer a directory zsh already reads. Falling back to the XDG location and
# saying so beats guessing at a system prefix the user does not own.
if command -v zsh > /dev/null 2>&1 && mint complete-zsh zsh/site-functions/_gist; then
  dest=''
  fpath="$(zsh -c 'print -l $fpath' 2> /dev/null)" || fpath=''
  while read -r dir; do
    [[ -d ${dir} && -w ${dir} && ${dir} == */site-functions ]] && dest="${dir}" && break
  done <<< "${fpath}"
  advise="${dest}"
  [[ -n ${dest} ]] || dest="${data}/zsh/site-functions"
  if place zsh/site-functions/_gist "${dest}/_gist"; then
    note "zsh: grouped completion → ${dest}/_gist"
    [[ -n ${advise} ]] || warn "  add it yourself: fpath=(${dest} \$fpath) before compinit"
    # compinit caches which #compdef tags exist, not the function body, so a
    # dump written before this link would not know _gist is there. The dump is
    # pure cache — the next shell rebuilds it — but drop it out loud rather
    # than silently deleting a file in someone's home directory.
    if compgen -G "${HOME}/.zcompdump*" > /dev/null; then
      rm -f "${HOME}"/.zcompdump*
      note "  cleared ~/.zcompdump so compinit sees it (rebuilt on next shell)"
    fi
  fi
fi

# ── bash ─────────────────────────────────────────────────────────────────
# bash-completion 2.x autoloads this XDG directory by name, so a file called
# `gist` there needs no wiring at all.
if command -v bash > /dev/null 2>&1 && mint complete-bash bash-completion/completions/gist; then
  if place bash-completion/completions/gist "${data}/bash-completion/completions/gist"; then
    note "bash: completion → ${data}/bash-completion/completions/gist"
  fi
fi

# ── fish ─────────────────────────────────────────────────────────────────
if command -v fish > /dev/null 2>&1 && mint complete-fish fish/completions/gist.fish; then
  if place fish/completions/gist.fish "${conf}/fish/completions/gist.fish"; then
    note "fish: completion → ${conf}/fish/completions/gist.fish"
  fi
fi

# ── PowerShell ───────────────────────────────────────────────────────────
# No autoloaded directory exists, so this one is dot-sourced by hand.
if command -v pwsh > /dev/null 2>&1 && mint complete-powershell powershell/gist.ps1; then
  if place powershell/gist.ps1 "${data}/gist/gist.ps1"; then
    note "pwsh: completion → ${data}/gist/gist.ps1"
    warn "  add to \$PROFILE: . ${data}/gist/gist.ps1"
  fi
fi

exit 0
