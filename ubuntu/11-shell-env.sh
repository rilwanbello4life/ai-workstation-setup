#!/usr/bin/env bash
# Phase 8.10 - put the kit's environment into every shell, not just login ones.
#
#   ./11-shell-env.sh          write it and wire up ~/.profile and ~/.bashrc
#   ./11-shell-env.sh --show   print what the shell would get, change nothing
#
# Writes ~/.config/ai-workstation/env.sh and makes both ~/.profile and
# ~/.bashrc source it, so AI_ROOT, HF_HOME, the /srv paths, KUBECONFIG and
# ~/.local/bin on PATH are present in a desktop terminal as well as a login
# shell.
#
# Earlier versions of this kit appended the exports directly to ~/.profile
# from two separate scripts. ~/.profile is read by login shells only, so a
# terminal opened on the desktop had none of it - which looks exactly like a
# broken install the first time you open a terminal after a reboot and find
# `strata` is not a command. This script also removes those older inline
# blocks, after backing the file up, so there is one definition instead of
# three.
#
# Safe to re-run. Nothing here needs sudo.
#
# Background: reference/filesystem-map.md

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_not_root

if [[ "${1:-}" == "--show" ]]; then
    tmp="$(mktemp)"
    _write_env_file "$tmp"
    section "What a shell would get"
    sed 's/^/  /' "$tmp"
    rm -f "$tmp"
    exit 0
fi

[[ "$(uname -s)" == "Linux" ]] || die "This is for the Ubuntu side, not $(uname -s)."

section "Shell environment"
ensure_shell_env

section "Check"

# Source it in a clean child shell rather than trusting this one, which
# already has everything exported by common.sh.
env -i HOME="$HOME" PATH=/usr/bin:/bin bash -lc "
    . '$SHELL_ENV_FILE'
    printf '  %-26s %s\n' AI_ROOT \"\$AI_ROOT\" HF_HOME \"\$HF_HOME\" \
        SRV_ROOT \"\$SRV_ROOT\" PLATFORM_DIR \"\$PLATFORM_DIR\" \
        BACKUP_DIR \"\$BACKUP_DIR\" KUBECONFIG \"\$KUBECONFIG\"
    case \":\$PATH:\" in
        *\":\$HOME/.local/bin:\"*) echo '  ~/.local/bin               on PATH' ;;
        *) echo '  ~/.local/bin               MISSING from PATH' ;;
    esac
" || warn "Could not evaluate $SHELL_ENV_FILE in a clean shell."

cat <<EOF

  Open a new terminal to pick this up, or in this one:

      . $SHELL_ENV_FILE

  K8S_DIR is not set here on purpose - server/common.sh works it out from
  the location of the script being run, so it survives moving the repo.
EOF
