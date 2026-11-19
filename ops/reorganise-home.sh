#!/usr/bin/env bash
# Reorganise the home directory into a layout that stays navigable as the
# machine fills up. Run once, after the downloads have finished and before
# you carry on configuring.
#
#   ./reorganise-home.sh            show the plan and change nothing
#   ./reorganise-home.sh --apply    do it
#   ./reorganise-home.sh --undo     put everything back
#   ./reorganise-home.sh --check    list anything still pointing at an old path
#
# A 2 TB drive with a terabyte of weights, a dozen applications, game worlds,
# study notes and a pile of half-finished project ideas becomes unnavigable
# very quickly unless the top level means something. This moves what is
# already here into that shape and repoints everything that referred to the
# old locations.
#
# Ubuntu's own directories - Desktop, Documents, Downloads, Music, Pictures,
# Videos - are left exactly as they are, names and contents both. Everything
# this script creates is lowercase, so the two sets are told apart at a
# glance and nothing has to be reconfigured to keep the desktop working.
#
# The move itself is the cheap part. The whole drive is a single ext4 root -
# /home, /srv and / are the same filesystem - so every move below is a
# rename: instant, atomic, no copying, and a terabyte of models costs the
# same as an empty directory. The script refuses to move anything that would
# cross a filesystem boundary, because that silently becomes a copy.
#
# The expensive part is what points at the old paths: Python virtualenvs bake
# their own absolute path into every script in bin/, ComfyUI records where
# its models are, the voice unit has AI_ROOT written into it. Those are
# rewritten here and verified afterwards.
#
# Nothing outside $HOME is touched. /srv is already structured and keeps its
# meaning, so it is left exactly as it is.
#
# Background: reference/filesystem-map.md

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../ubuntu" && pwd)/common.sh"
require_not_root

MODE=plan
NAME_STYLE=lower

while (( $# )); do
    case "$1" in
        --apply)   MODE=apply; shift ;;
        --undo)    MODE=undo;  shift ;;
        --check)   MODE=check; shift ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

[[ "$(uname -s)" == "Linux" ]] || die "This is for the Ubuntu side, not $(uname -s)."

STATE_DIR="$HOME/.config/ai-workstation"
PATHS_FILE="$STATE_DIR/paths.sh"
MANIFEST="$STATE_DIR/reorganise-manifest.tsv"
mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
# The layout.
#
# Everything below is derived from these. Change a value here and the plan,
# the moves and the generated paths.sh all follow, so this is the only place
# to edit if you want it shaped differently.
AI_NEW="$HOME/ai"                  # all AI: models, apps, cache, output
PROJECTS="$HOME/projects"          # anything you write

# Ubuntu's own directories - Desktop, Documents, Downloads, Music, Pictures,
# Videos - are deliberately left alone. They keep their names, their
# contents and their XDG registration, so the desktop, Firefox and the
# screenshot tool carry on working with no configuration at all.
#
# Everything this script creates is lowercase, which makes the two sets
# tell themselves apart at a glance: capitalised means Ubuntu put it there,
# lowercase means you did.
DOCUMENTS="$HOME/Documents"

NEW_AI_ROOT="$AI_NEW/models"
NEW_APPS="$AI_NEW/apps"
NEW_CACHE="$AI_NEW/cache"
NEW_OUTPUT="$AI_NEW/output"

# Where this kit ends up. It is a git checkout you edit, so it belongs with
# the other things you edit rather than loose in the home directory.
KIT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIT_DST="$PROJECTS/$(basename "$KIT_SRC")"

# Directories to create even when empty, so there is an obvious place to put
# the next thing instead of inventing one at the top level.
SCAFFOLD=(
    "$PROJECTS/web"              "$PROJECTS/games"
    "$PROJECTS/mobile"           "$PROJECTS/experiments"
    "$NEW_AI_ROOT"               "$NEW_APPS"
    "$NEW_CACHE"                 "$NEW_OUTPUT"
    "$DOCUMENTS/studies"         "$DOCUMENTS/notes"
    "$DOCUMENTS/admin"
)

# src <TAB> dst. Only applied where src exists; a machine part-way through
# the setup simply has fewer rows that match.
#
# Order matters. The AI_ROOT contents move into a subdirectory of the
# directory they are already in, so $AI_NEW/models must exist first - the
# scaffold above guarantees that.
read -r -d '' MOVES <<EOF || true
$HOME/ai/strata	$NEW_AI_ROOT/strata
$HOME/ai/gguf	$NEW_AI_ROOT/gguf
$HOME/ai/comfyui	$NEW_AI_ROOT/comfyui
$HOME/ai/voice	$NEW_AI_ROOT/voice
$HOME/ai/hf-cache	$NEW_CACHE
$HOME/ai/.downloads.tsv	$NEW_AI_ROOT/.downloads.tsv
$HOME/apps	$NEW_APPS
EOF

# ---------------------------------------------------------------------------
# Helpers

# Everything here assumes a rename. A move across filesystems is a copy and
# a delete, which for a terabyte of weights is an hour of IO and a window
# where the data exists in neither place if it is interrupted. Refuse.
same_fs() {
    local a="$1" b="$2" da db
    da="$(stat -c%d "$a" 2>/dev/null || echo x)"
    while [[ ! -e "$b" && "$b" != "/" ]]; do b="$(dirname "$b")"; done
    db="$(stat -c%d "$b" 2>/dev/null || echo y)"
    [[ "$da" == "$db" && "$da" != x ]]
}

short() { printf '%s' "${1/#$HOME/\~}"; }

# ---------------------------------------------------------------------------
# Refuse to run while anything is using the paths.
#
# This is the guard that matters most. Renaming $HOME/ai out from under a
# running download does not fail loudly - the writer keeps its open file
# descriptor and carries on writing into a directory that no longer has the
# name anyone else is looking for. You would find out hours later.
busy_check() {
    local busy=() pat
    for pat in '07-strata.sh' '10-models.sh' 'download-models.sh' \
               'strata launch' 'ComfyUI/main.py' 'llama-server' 'server.py'; do
        pgrep -af -- "$pat" >/dev/null 2>&1 && busy+=("$pat")
    done

    # hf on its own, because the pattern is short enough to match this script.
    pgrep -x hf >/dev/null 2>&1 && busy+=("hf")

    if (( ${#busy[@]} )); then
        err "Something is still using these paths:"
        printf '      %s\n' "${busy[@]}"
        echo
        err "Let the downloads finish first. Check with:  tmux attach -t dl"
        die "Nothing has been changed."
    fi

    if systemctl --user is-active --quiet voice-server.service 2>/dev/null; then
        warn "Stopping voice-server.service for the move."
        if [[ "$MODE" == apply ]]; then
            systemctl --user stop voice-server.service || true
        fi
    fi

    # Explicit, because the last test above returns non-zero whenever the
    # voice server is not running, and this function is called bare under
    # set -e - which would end the run before anything had been done.
    return 0
}

# ---------------------------------------------------------------------------
# A virtualenv records its own absolute path in pyvenv.cfg, in the activate
# scripts and in the shebang of every console script in bin/. Move the
# directory and every one of those points at nothing, which shows up as
# "bad interpreter: No such file or directory" rather than anything that
# mentions the move.
#
# Rewriting them is reliable for venvs made by venv and by uv, both of which
# write the path as plain text. It is verified afterwards rather than
# assumed, and a venv that fails the check is reported as needing its phase
# script re-run - which is a few minutes, not a disaster.
relocate_venv() {
    local venv="$1" old="$2" new="$3" f n=0

    [[ -d "$venv" ]] || return 0

    while IFS= read -r f; do
        sed -i "s|$old|$new|g" "$f"
        n=$((n + 1))
    done < <(grep -rIl --exclude-dir=__pycache__ -- "$old" "$venv" 2>/dev/null || true)

    if "$venv/bin/python" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
        ok "    venv relocated ($n files rewritten): $(short "$venv")"
    else
        warn "    venv at $(short "$venv") did not survive the move."
        warn "    Re-run the phase that built it; the models are untouched."
        REBUILD+=("$venv")
    fi
}

# ---------------------------------------------------------------------------
# Keep the first copy and only the first copy.
#
# A second --apply would otherwise back up the already-rewritten file over
# the original, so the surviving copy describes the new layout and --undo
# restores nothing. Same reasoning as the manifest below: the record of how
# things were has to survive being run again.
backup_once() {
    [[ -e "$1.pre-reorganise" ]] || cp -p "$1" "$1.pre-reorganise"
}

# ---------------------------------------------------------------------------
# Rewrite the old paths in one file.
#
# The obvious version of this is wrong. AI_ROOT moves from ~/ai to ~/ai/models
# and the output directory to ~/ai/output, so the new paths contain the old
# one as a prefix: a blanket  s|~/ai|~/ai/models|  turns ~/ai/comfyui/output
# into ~/ai/models/comfyui/output on the first pass and adds another /models
# on every pass after that.
#
# Naming the directories that actually moved avoids both problems. Nothing
# here matches a path that has already been migrated, which is what makes the
# script safe to run twice.
rewrite_paths() {
    local f="$1" old_ai="$2" old_apps="$3"

    # '#' as the delimiter, not '|'. Paths cannot contain it, and it leaves
    # '|' free to mean alternation - with '|' as the delimiter the groups
    # below would have to escape it, which sed then reads as a literal pipe.
    #
    # Every pattern ends by naming what may follow. That is doing two jobs.
    # It stops ~/apps matching ~/apps-old and ~/ai matching
    # ~/ai-workstation-setup, which would otherwise be rewritten into
    # nonsense like ~/ai/models-workstation-setup. And because the new paths
    # all begin with the old ~/ai followed by a slash, excluding a slash in
    # the final rule is what stops the script rewriting its own output - so
    # running it twice is a no-op rather than appending /models again.
    #
    # The last rule is the one for a bare ~/ai with nothing after it, which
    # is how AI_ROOT appears in the voice unit. Without it that unit keeps
    # pointing at the old root and the voice server finds no models.
    sed -i -E \
        -e "s#${old_apps}(\$|[^[:alnum:]_.-])#${NEW_APPS}\\1#g" \
        -e "s#${old_ai}/comfyui/output#${NEW_OUTPUT}#g" \
        -e "s#${old_ai}/hf-cache#${NEW_CACHE}#g" \
        -e "s#${old_ai}/(strata|gguf|comfyui|voice)#${NEW_AI_ROOT}/\\1#g" \
        -e "s#${old_ai}(\$|[^/[:alnum:]_.-])#${NEW_AI_ROOT}\\1#g" \
        "$f"
}

# ---------------------------------------------------------------------------
# Generated files that have an absolute path written into them. Each is
# produced by a phase script, so re-running that phase would also fix it -
# rewriting in place just saves doing so.
fix_references() {
    local old_ai="$1" old_apps="$2" f

    # ComfyUI: base_path in extra_model_paths.yaml, and the launcher's
    # --output-directory.
    for f in "$NEW_APPS/ComfyUI/extra_model_paths.yaml" \
             "$NEW_APPS/start-comfyui.sh" \
             "$NEW_APPS/start-llama-server.sh" \
             "$NEW_APPS/start-voice.sh"; do
        [[ -f "$f" ]] || continue
        backup_once "$f"
        rewrite_paths "$f" "$old_ai" "$old_apps"
        ok "    rewrote $(short "$f")"
    done

    # The voice user unit carries AI_ROOT and HF_HOME as Environment= lines
    # and the venv python as ExecStart.
    f="$HOME/.config/systemd/user/voice-server.service"
    if [[ -f "$f" ]]; then
        backup_once "$f"
        rewrite_paths "$f" "$old_ai" "$old_apps"
        systemctl --user daemon-reload 2>/dev/null || true
        ok "    rewrote $(short "$f")"
    fi

    # The venvs themselves.
    relocate_venv "$NEW_APPS/ComfyUI/.venv" "$old_apps" "$NEW_APPS"
    relocate_venv "$NEW_APPS/voice/.venv"   "$old_apps" "$NEW_APPS"

    # llama.cpp is compiled C++ with no absolute paths in the binaries, but
    # 04-llama-cpp.sh symlinks the server into ~/.local/bin and that symlink
    # is absolute.
    f="$HOME/.local/bin/llama-server"
    if [[ -L "$f" ]]; then
        local tgt; tgt="$(readlink "$f")"
        if [[ "$tgt" == "$old_apps"* ]]; then
            ln -sfn "${tgt/#$old_apps/$NEW_APPS}" "$f"
            ok "    repointed $(short "$f")"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Tell the rest of the kit where things are now.
#
# This file is the whole migration mechanism. ubuntu/common.sh and status.sh
# read it before applying their own defaults, so writing it switches every
# script at once - and not writing it means an un-migrated machine behaves
# exactly as it did before, which is what makes this safe to pull mid-run.
write_paths_file() {
    cat > "$PATHS_FILE" <<EOF
# Where this machine keeps things. Written by ops/reorganise-home.sh.
#
# Read by ubuntu/common.sh, status.sh and the generated env.sh before any of
# them apply a default, so these win. Unlike env.sh this file is yours: it is
# never regenerated, so edit it if you move something by hand.

export AI_HOME="$AI_NEW"
export AI_ROOT="$NEW_AI_ROOT"
export APPS="$NEW_APPS"
export AI_OUTPUT="$NEW_OUTPUT"
export HF_HOME="$NEW_CACHE"
export HUGGINGFACE_HUB_CACHE="$NEW_CACHE/hub"
EOF
    ok "Wrote $(short "$PATHS_FILE")"
}

# ---------------------------------------------------------------------------
# Anything still naming an old path, after everything above has run. This is
# the honest part of the script: it reports what it could not fix rather
# than claiming the job is complete.
scan_stale() {
    local hits=0 d
    section "References still pointing at the old layout"

    for d in "$HOME/.config" "$HOME/.local/share/applications" "$NEW_APPS" \
             "$HOME/.local/bin" /srv/platform; do
        [[ -d "$d" ]] || continue
        while IFS= read -r f; do
            # The migration's own records are supposed to name both layouts.
            case "$f" in
                *".pre-reorganise"|"$MANIFEST"|"$PATHS_FILE") continue ;;
            esac
            printf '    %s\n' "$(short "$f")"
            hits=$((hits + 1))
        done < <(grep -rIl --exclude-dir=.git --exclude-dir=__pycache__ \
                    -e "$HOME/apps" -e "$HOME/ai/strata" -e "$HOME/ai/gguf" \
                    -e "$HOME/ai/hf-cache" -e "$HOME/ai/comfyui" \
                    "$d" 2>/dev/null || true)
    done

    if (( hits == 0 )); then
        ok "Nothing left referring to the old paths."
    else
        warn "$hits file(s) above still name an old path."
        warn "Most are caches or logs and do not matter. Anything that does"
        warn "can be fixed by re-running the phase that generated it."
    fi
}

# ---------------------------------------------------------------------------
case "$MODE" in

check)
    scan_stale
    exit 0
    ;;

undo)
    [[ -f "$MANIFEST" ]] || die "No manifest at $(short "$MANIFEST") - nothing to undo."

    section "Undoing the reorganisation"
    busy_check

    # Reverse order, so a directory that was moved into another one comes
    # back out before its parent moves.
    tac "$MANIFEST" | while IFS=$'\t' read -r src dst; do
        [[ -n "$src" && "$src" != \#* ]] || continue
        if [[ -e "$dst" && ! -e "$src" ]]; then
            mkdir -p "$(dirname "$src")"
            mv -- "$dst" "$src"
            printf '    %s  <-  %s\n' "$(short "$src")" "$(short "$dst")"
        fi
    done

    # Restore every file that was rewritten in place.
    while IFS= read -r f; do
        mv -- "$f" "${f%.pre-reorganise}"
        ok "    restored $(short "${f%.pre-reorganise}")"
    done < <(find "$HOME/.config" "$HOME/apps" "$NEW_APPS" -name '*.pre-reorganise' \
                2>/dev/null | sort -u || true)

    rm -f "$PATHS_FILE" "$MANIFEST"
    systemctl --user daemon-reload 2>/dev/null || true

    echo
    ok "Back to the previous layout."
    warn "The venvs were rewritten to the new paths and have now been moved"
    warn "back, but not rewritten again. Re-run ubuntu/05-comfyui.sh and"
    warn "ubuntu/06-voice.sh if either refuses to start."
    exit 0
    ;;

plan|apply)
    if [[ "$MODE" == apply ]]; then
        section "Reorganising"
        busy_check
    else
        section "Plan - nothing will be changed"
    fi

    # -----------------------------------------------------------------
    # What would move
    planned=()
    while IFS=$'\t' read -r src dst; do
        [[ -n "$src" ]] || continue
        [[ -e "$src" ]] || continue
        [[ "$src" == "$dst" ]] && continue

        if [[ -e "$dst" ]]; then
            warn "$(short "$dst") already exists - leaving $(short "$src") alone."
            continue
        fi
        if ! same_fs "$src" "$dst"; then
            warn "$(short "$src") is on another filesystem - skipped."
            warn "  Moving it would be a copy, not a rename. Do that by hand."
            continue
        fi
        planned+=("$src	$dst")
    done <<<"$MOVES"

    [[ -d "$KIT_SRC" && ! -e "$KIT_DST" && "$KIT_SRC" != "$KIT_DST" ]] \
        && planned+=("$KIT_SRC	$KIT_DST")

    if (( ${#planned[@]} == 0 )); then
        ok "Nothing to move - the layout is already in place."
    else
        printf '  %-34s %s\n' 'FROM' 'TO'
        for row in "${planned[@]}"; do
            IFS=$'\t' read -r src dst <<<"$row"
            printf '  %-34s %s\n' "$(short "$src")" "$(short "$dst")"
        done
    fi
    echo

    if [[ "$MODE" == plan ]]; then
        cat <<EOF
  Also, with --apply:

    - create the empty structure: projects/{web,games,mobile,experiments},
      ai/{models,apps,cache,output} and Documents/{studies,notes,admin}
    - write ~/.config/ai-workstation/paths.sh so every script in the kit
      uses the new locations
    - rewrite the ComfyUI model paths, the launchers, the voice unit and
      the two Python virtualenvs, then check the venvs still work
    - record every move so --undo can reverse it

  The drive is a single filesystem, so each move is a rename. Even the
  models directory moves in well under a second.

  Run it for real:   ./reorganise-home.sh --apply
EOF
        exit 0
    fi

    # -----------------------------------------------------------------
    # Moving comes before the scaffold so that a destination the scaffold
    # would also create cannot exist yet: mv into an existing directory
    # moves the source inside it instead of renaming, which is a silently
    # wrong result rather than an error. Each move makes its own parent.
    section "Moving"

    # Append, never truncate. The second run has nothing to move, and
    # rewriting the file at that point would leave a header and no rows -
    # silently throwing away the only record of where everything came from.
    [[ -f "$MANIFEST" ]] || printf '# src\tdst\n' > "$MANIFEST"
    for row in "${planned[@]}"; do
        IFS=$'\t' read -r src dst <<<"$row"
        mkdir -p "$(dirname "$dst")"
        mv -- "$src" "$dst"
        printf '%s\t%s\n' "$src" "$dst" >> "$MANIFEST"
        printf '    %s  ->  %s\n' "$(short "$src")" "$(short "$dst")"
    done
    (( ${#planned[@]} )) || info "Nothing needed moving."

    section "Creating the structure"

    # ext4 is case-sensitive, so mkdir ~/projects beside an existing
    # ~/Projects succeeds and leaves two directories one keystroke apart.
    # That is exactly the confusion this script exists to remove.
    for d in "${SCAFFOLD[@]}"; do
        twin="$(dirname "$d")/$(basename "$d" | sed 's/^./\U&/')"
        if [[ "$twin" != "$d" && -d "$twin" && ! -d "$d" ]]; then
            warn "$(short "$twin") already exists - not creating $(short "$d") beside it."
            continue
        fi
        mkdir -p "$d"
    done
    ok "Structure in place."

    section "Repointing what referred to the old paths"
    REBUILD=()
    fix_references "$HOME/ai" "$HOME/apps"
    write_paths_file

    # The reference documentation lives in the kit, so link it where the
    # models are rather than keeping a second copy.
    if [[ -d "$KIT_DST/reference" ]]; then
        ln -sfn "$KIT_DST/reference" "$AI_NEW/docs"
        ok "Linked $(short "$AI_NEW/docs") -> $(short "$KIT_DST/reference")"
    fi

    scan_stale

    # -----------------------------------------------------------------
    section "Done"

    if (( ${#REBUILD[@]} )); then
        warn "These virtualenvs need rebuilding:"
        printf '      %s\n' "${REBUILD[@]}"
        warn "Re-run ubuntu/05-comfyui.sh and/or ubuntu/06-voice.sh."
        echo
    fi

    cat <<EOF
  ~/
  ├── ai/                 everything AI
  │   ├── models/         weights - strata, gguf, comfyui, voice
  │   ├── apps/           ComfyUI, llama.cpp, open-webui, voice, launchers
  │   ├── cache/          Hugging Face cache
  │   ├── output/         generated images and video
  │   └── docs/           -> the kit's reference/
  ├── projects/           web, games, mobile, experiments, and this kit
  │
  ├── Desktop/            Ubuntu's own, untouched
  ├── Documents/          untouched, with studies/ notes/ admin/ added
  ├── Downloads/          untouched
  ├── Music/  Pictures/  Videos/        untouched
  └── ...

  Lowercase is yours, capitalised is Ubuntu's. The desktop, Firefox and the
  screenshot tool keep using the capitalised ones exactly as before.

  /srv is unchanged: platform state, secrets, backups and game worlds.

  Two things to do now:

    1. Open a new terminal, or run:  source ~/.profile
       The current shell still has the old paths exported.

    2. The kit moved. Carry on from its new home:
         cd $(short "$KIT_DST")

  Check it over:   ./status.sh
  Still stale?     ops/reorganise-home.sh --check
  Changed my mind: ops/reorganise-home.sh --undo
EOF
    ;;
esac
