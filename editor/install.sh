#!/usr/bin/env bash
# Put the gist plugin where an installed editor already looks.
#
# Vim 8 and Neovim both load every directory under `pack/*/start/` with no
# configuration and no plugin manager, so a symlink there is the whole install:
# the checkout stays the source of truth and `git pull` updates the plugin.
# Only an editor that exists on this machine is touched — nobody gets a ~/.vim
# they never asked for — and an existing real directory is left alone rather
# than replaced. Re-running is a no-op. GIST_VIM_INSTALL=0 skips it entirely.
set -uo pipefail

[[ ${GIST_VIM_INSTALL:-1} == 0 ]] && exit 0

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
plugin="${here}/vim"
[[ -d ${plugin} ]] || exit 0

warn() { printf '\033[0;33m!\033[0m  %s\n' "${1}"; }
note() { printf '\033[0;32m✓\033[0m  %s\n' "${1}"; }

# $1 editor binary · $2 package root · $3.. argv that runs :helptags headlessly
link() {
  local editor="${1}" pack="${2}" dest
  command -v "${editor}" > /dev/null 2>&1 || return 0
  dest="${pack}/gist"
  if [[ -e ${dest} && ! -L ${dest} ]]; then
    warn "${dest} exists and is not a symlink — leaving it; :help gist-install"
    return 0
  fi
  if ! mkdir -p "${pack}" || ! ln -sfn "${plugin}" "${dest}"; then
    warn "could not link the gist plugin into ${pack}"
    return 0
  fi
  shift 2
  "${@}" > /dev/null 2>&1
  note "${editor}: gist plugin linked (${dest}) — :help gist"
}

link vim "${HOME}/.vim/pack/gist/start" \
  vim -es -u NONE -i NONE -c "helptags ${plugin}/doc" -c 'qall!'
link nvim "${XDG_DATA_HOME:-${HOME}/.local/share}/nvim/site/pack/gist/start" \
  nvim --headless -u NONE -i NONE -c "helptags ${plugin}/doc" -c 'qall!'

exit 0
