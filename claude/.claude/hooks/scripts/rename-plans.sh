#!/usr/bin/env bash
# rename-plans.sh — Rename freshly-created plan files from their random
# placeholder name (e.g. glimmering-twirling-sky.md) to a slug of their
# first `# H1` heading (e.g. task-7b-order-vdc-end-to-end.md).
#
# Wired as a Stop hook. Only touches plan files modified AFTER the marker
# file was created at install time, so the pre-existing backlog is left
# alone ("going forward" only). Idempotent: a file already matching its
# heading slug is skipped.
source "$HOME/.claude/hooks/scripts/common.sh"
check_disabled

PLANS_DIR="$HOME/.claude/plans"
MARKER="$HOOKS_DIR/.rename-plans-since"

[[ -d "$PLANS_DIR" ]] || exit 0
[[ -f "$MARKER" ]] || exit 0

# Slugify: lowercase, non-alphanumeric runs -> "-", trim, cap at 60 chars.
slugify() {
    local s
    s="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
        | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
    s="${s:0:60}"
    printf '%s' "$s" | LC_ALL=C sed -E 's/-+$//'
}

renamed=0
msg=""
while IFS= read -r f; do
    [[ -f "$f" ]] || continue

    # First line of the form "# Title" (single hash). No match -> skip.
    title="$(grep -m1 -E '^# ' "$f" 2>/dev/null | sed -E 's/^# +//')" || true
    [[ -n "$title" ]] || continue

    slug="$(slugify "$title")"
    [[ -n "$slug" ]] || continue

    base="$(basename "$f" .md)"
    # A -N suffix from an earlier collision rename still counts as "already
    # named": without this, same-heading files reshuffle every session.
    [[ "$base" == "$slug" || "$base" =~ ^"$slug"-[0-9]+$ ]] && continue

    target="$PLANS_DIR/$slug.md"
    if [[ -e "$target" ]]; then
        n=2
        while [[ -e "$PLANS_DIR/$slug-$n.md" ]]; do n=$((n + 1)); done
        target="$PLANS_DIR/$slug-$n.md"
    fi

    if mv "$f" "$target" 2>/dev/null; then
        log_info "renamed $(basename "$f") -> $(basename "$target")"
        renamed=$((renamed + 1))
        msg+="📝 Plan renamed: ${base}.md → $(basename "$target")"$'\n'
    else
        log_error "failed to rename $(basename "$f")"
    fi
done < <(find "$PLANS_DIR" -maxdepth 1 -name '*.md' -newer "$MARKER" 2>/dev/null)

# Surface the rename(s) to the user. A Stop hook's plain stdout is fed to
# Claude as context, not shown to the user — systemMessage is the field the
# UI renders. Skip silently if jq is unavailable (the rename still happened).
if [[ "$renamed" -gt 0 ]] && command -v jq &>/dev/null; then
    jq -n --arg m "${msg%$'\n'}" '{systemMessage: $m}'
fi

exit 0
