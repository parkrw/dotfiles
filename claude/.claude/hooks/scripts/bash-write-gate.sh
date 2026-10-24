#!/usr/bin/env bash
# bash-write-gate.sh — PreToolUse(Bash) gate.
#
# Permission tiers:
#   reads + read-only git/gh        -> allow (no prompt)
#   redirect or tee into a file     -> allow (no prompt)
#   …into .git, ~/.claude hooks or
#     settings, ~/.config/git, or a
#     gate marker                   -> ask
#   git pull --ff-only, git tag     -> allow (no prompt)
#   local git writes (add, commit,
#     branch, switch, stash, merge,
#     rebase, worktree, reset …), a
#     remote-tracking ref as the
#     other side too                -> allow (no prompt)
#   …that discard uncommitted work,
#     config/remote writes, a
#     pathspec it cannot place in
#     the repo, --no-verify, or an
#     opaque line                   -> ask
#   bulk staging (add -A/-u, commit
#     -a, a whole-tree pathspec)    -> deny (always)
#   new branch whose name is taken
#     on origin, or whose issue is
#     someone else's                -> deny (always)
#   merge/rebase, other pulls       -> allow (default), deny (.claude-merge-off)
#   push of a feature branch, gh
#     pr create                     -> allow (default), deny (.claude-remote-off)
#   other gh writes                 -> ask (default), deny (.claude-remote-off)
#   push to main/master or the
#     default branch, gh pr merge   -> deny, always. No marker changes it.
#   force-push, push of tags,
#     --all/--mirror, a remote
#     branch deletion               -> deny (always)
#   reset --hard, clean -f, rm -rf  -> deny (always)
#
# Two per-repo opt-OUT markers, both files in the repo root. They tighten a
# repo below the default; their absence is the permissive default:
#   .claude-remote-off  push/gh        allow/ask -> deny
#   .claude-merge-off   merge/rebase   allow     -> deny
# Flip them with `claude-gate`.
#
# A compound line is judged segment by segment, wherever the git or gh segment
# sits: it can be auto-approved only when every segment is itself in the allow
# tier and nothing is redirected into a protected path. Command substitution, process
# substitution, backgrounding and newlines can hide an arbitrary command, so
# they block `allow` and the line falls through to the ask/deny rules.
set -e
trap 'echo "bash-write-gate crashed at line $LINENO — command blocked, check the script" >&2; exit 2' ERR
input=$(cat)
cmd=$(echo "$input"  | jq -r '.tool_input.command // ""')
cwd=$(echo "$input"  | jq -r '.cwd // ""'); [[ -z "$cwd" ]] && cwd="$(pwd)"
[[ -z "$cmd" ]] && exit 0
emit(){ jq -n --arg d "$1" --arg r "$2" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'; exit 0; }

# Resolve the git directory for branch checks — `cd <repo> && git commit`
# must check the target repo's branch, not the session cwd.
gitdir="$cwd"
cd_arg=$(echo "$cmd" | sed -nE 's/^[[:space:]]*cd[[:space:]]+([^;&|]+)(&&|;).*/\1/p' \
         | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^["'\'']//; s/["'\'']$//')
if [[ -n "$cd_arg" ]]; then
  cd_arg="${cd_arg/#\~/$HOME}"
  [[ "$cd_arg" != /* ]] && cd_arg="$cwd/$cd_arg"
  gitdir="$cd_arg"
fi
c_arg=$(echo "$cmd" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:]]+).*/\1/p')
if [[ -n "$c_arg" ]]; then
  c_arg="${c_arg/#\~/$HOME}"
  [[ "$c_arg" != /* ]] && c_arg="$gitdir/$c_arg"
  gitdir="$c_arg"
fi

repo_root=$(git -C "$gitdir" rev-parse --show-toplevel 2>/dev/null || true)
remote_off=0; merge_off=0
[[ -n "$repo_root" && -f "$repo_root/.claude-remote-off" ]] && remote_off=1
[[ -n "$repo_root" && -f "$repo_root/.claude-merge-off"  ]] && merge_off=1
cur=$(git -C "$gitdir" branch --show-current 2>/dev/null || true)

remote_gate(){
  if [[ "$remote_off" == 1 ]]; then
    emit deny "$1 blocked — this repo is opted out (.claude-remote-off). Re-enable with: claude-gate remote on"
  else
    emit ask "$1 — needs approval."
  fi
}

# ── segment analysis ──
#
# A compound line is allowable when every one of its segments is independently
# allowable, wherever the git or gh segment sits: `cd $C && git log -3`,
# `echo ---; gh pr view 7 | head` and `for n in 1 2; do gh issue view $n; done`
# all auto-approve, while anything unrecognised falls through to ask/deny.
# Command substitution, process substitution, backgrounding and embedded
# newlines can hide an arbitrary command inside a segment, so they block
# `allow` outright.
#
# Quoted text is blanked before the line is split or searched, so a jq
# filter's `|` and `;` cannot pass for shell syntax and its `>` cannot pass
# for a redirect. Only single quotes are fully literal to the shell — `$(`
# inside "…" still runs — so the substitution check keeps double-quoted text.

blank_quotes(){ # $1=line $2=1 keeps double-quoted text
  printf '%s\n' "$1" | awk -v keepdq="${2:-0}" '
    BEGIN { q = "" }
    { s = $0; out = ""; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q == "") {
          if (c == "\047" || c == "\"") { q = c; out = out c }
          else if (c == "\\") { out = out c substr(s, i + 1, 1); i++ }
          else out = out c
        } else if (q == "\047") {
          if (c == "\047") { q = ""; out = out c }
        } else {
          if (c == "\\") { if (keepdq) out = out c substr(s, i + 1, 1); i++ }
          else if (c == "\"") { q = ""; out = out c }
          else if (keepdq) out = out c
        }
      }
      print out }'
}
bare=$(blank_quotes "$cmd")
bare_dq=$(blank_quotes "$cmd" 1)

opaque=0
echo "$bare_dq" | grep -Eq '\$\(|`'              && opaque=1
echo "$bare"    | grep -Eq '>\(|<\('             && opaque=1
echo "$bare"    | grep -Eq '(^|[^&>])&([^&>]|$)' && opaque=1
[[ "$cmd" == *$'\n'* ]] && opaque=1

segments(){ echo "$bare" | awk '{gsub(/\|\||&&|;|\|/,"\n"); print}'; }

word_of(){ echo "$1" | sed -E 's/^[[:space:]]*//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*([[:space:]]+|$))*//' | awk '{print $1}'; }
git_global='(-C[[:space:]]+[^[:space:]]+|-c[[:space:]]+[^[:space:]]+|--git-dir=[^[:space:]]+|--work-tree=[^[:space:]]+|--no-pager|--paginate|-p)[[:space:]]+'
git_sub_of(){ echo "$1" | sed -E "s/^[[:space:]]*git[[:space:]]+(${git_global})*//" | awk '{print $1}'; }
# Arguments after the subcommand, redirections removed so `2>&1` is not a
# positional word.
git_args_of(){ echo "$1" | sed -E "s/^[[:space:]]*git[[:space:]]+(${git_global})*[^[:space:]]+[[:space:]]*//" \
  | sed -E 's/[[:space:]]*[0-9]*>>?(&[0-9]+|[^[:space:]]*)//g; s/[[:space:]]*<[^[:space:]]+//g'; }

first=$(word_of "$cmd")

# Segments that read or filter — the only ones auto-allowed in compound commands.
# Excludes anything that runs a command handed to it (xargs, eval, sh, find -exec)
# and anything that moves or removes files (mv, cp, export). tee writes only
# its targets, which protected_write vets like a redirect's. sed and yq lose the
# exemption under -i, find under -exec or -delete.
seg_filters='cat|head|tail|less|more|grep|egrep|fgrep|rg|jq|yq|wc|sort|uniq|cut|tr|awk|sed|column|nl|fold|rev|tac|echo|printf|true|false|date|basename|dirname|realpath|readlink|pbcopy|cd|pwd|ls|file|stat|du|df|which|type|test|\[|\[\[|read|seq|diff|cmp|comm|paste|shasum|sleep|find|tee'
seg_git='status|log|diff|show|reflog|shortlog|whatchanged|blame|describe|rev-parse|rev-list|merge-base|name-rev|symbolic-ref|var|cat-file|ls-files|ls-tree|ls-remote|for-each-ref|count-objects|grep|fetch|show-ref|check-ignore'
# A block that has already validated its own subcommand against the remote and
# marker rules adds it here before asking whether the rest of the line is safe.
seg_extra_git=''
seg_extra_gh=''
# Set by the local-write block once every deny and deliberate ask is behind it.
local_ok=0

has_opt(){ echo "$1" | grep -Eq -- "(^|[[:space:]])($2)([[:space:]=]|\$)"; } # $1=args $2=alternation

# Local writes touch only this checkout's refs, index, tree and stash, and the
# reflog keeps every commit they move. What it cannot return is uncommitted
# work, so the shapes that throw that away are refused here and ask. config and
# remote writes stay out too: they can repoint the hooks or the push target.
git_local_ok(){ # $1 = segment
  local sub args w
  sub=$(git_sub_of "$1"); args=$(git_args_of "$1")
  case "$sub" in
    add|stage|commit|branch|merge|rebase|cherry-pick|revert|mv|am|apply|tag) return 0 ;;
    reset)     ! has_opt "$args" '--hard|--merge' ;;
    rm)        ! has_opt "$args" '-[a-zA-Z]*f[a-zA-Z]*|--force' ;;
    switch)    ! has_opt "$args" '-[a-zA-Z]*f[a-zA-Z]*|--force|--discard-changes' ;;
    restore)   has_opt "$args" '-S|--staged' && ! has_opt "$args" '-W|--worktree' ;;
    stash)     ! echo "$args" | grep -Eq '^(drop|clear)([[:space:]]|$)' ;;
    worktree)  ! { echo "$args" | grep -Eq '^remove([[:space:]]|$)' && has_opt "$args" '-[a-zA-Z]*f[a-zA-Z]*|--force'; } ;;
    submodule) ! has_opt "$args" '-[a-zA-Z]*f[a-zA-Z]*|--force' ;;
    checkout)
      has_opt "$args" '-[a-zA-Z]*[fp][a-zA-Z]*|--force|--patch|--' && return 1
      # A word that names no commit is a path, and checking out a path
      # overwrites its uncommitted edits.
      while IFS= read -r w; do
        git -C "$gitdir" rev-parse --verify --quiet "$w^{commit}" >/dev/null || return 1
      done < <(echo "$args" | tr ' \t' '\n\n' | awk '
        take { take = 0; next }
        /^(-b|-B|--orphan)$/ { take = 1; next }
        /^-/ || /^$/ { next }
        { print }')
      return 0 ;;
    *) return 1 ;;
  esac
}

git_segment_ok(){
  local sub args
  sub=$(git_sub_of "$1"); args=$(git_args_of "$1")
  # --output sends log/diff/show output to a file.
  echo "$args" | grep -Eq -- '(^|[[:space:]])--output(=|[[:space:]])' && return 1
  [[ -n "$seg_extra_git" ]] && echo "$sub" | grep -Eq "^(${seg_extra_git})$" && return 0
  echo "$sub" | grep -Eq "^(${seg_git})$" && return 0
  [[ "$local_ok" == 1 ]] && git_local_ok "$1" && return 0
  case "$sub" in
    worktree) echo "$args" | grep -Eq '^list([[:space:]]|$)' ;;
    # Any positional word is a branch to create, move or delete.
    branch)   ! echo "$args" | grep -Eq -- '(^|[[:space:]])([^-[:space:]]|--edit-description|--unset-upstream)' ;;
    tag)      [[ -z "$args" ]] || echo "$args" | grep -Eq '^(-l|--list|-n)' ;;
    config)   echo "$args" | grep -Eq -- '(^|[[:space:]])(--get(-all|-regexp)?|--list|-l|get|list)([[:space:]]|$)' ;;
    remote)   echo "$args" | grep -Eq '^(-v|show|get-url)?([[:space:]]|$)' ;;
    stash)    echo "$args" | grep -Eq '^(list|show)([[:space:]]|$)' ;;
    *)        return 1 ;;
  esac
}

gh_segment_ok(){
  [[ "$remote_off" == 1 ]] && return 1
  [[ -n "$seg_extra_gh" ]] && echo "$1" | grep -Eq '^[[:space:]]*gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' && return 0
  local rest sub act
  rest=$(echo "$1" | sed -E 's/^[[:space:]]*gh[[:space:]]+((-R|--repo|--hostname)[[:space:]]+[^[:space:]]+[[:space:]]+)*//')
  sub=$(echo "$rest" | awk '{print $1}'); act=$(echo "$rest" | awk '{print $2}')
  case "$sub" in
    pr|issue)                  case "$act" in view|list|diff|checks|status) return 0 ;; esac ;;
    run|repo|workflow|release) case "$act" in view|list) return 0 ;; esac ;;
    label)                     case "$act" in list|"") return 0 ;; esac ;;
    auth)                      [[ "$act" == status ]] && return 0 ;;
    search|status|version|--version|help) return 0 ;;
    # gh api defaults to GET; a field, an input file or another method turns
    # it into a write.
    api)
      echo "$rest" | grep -Eq -- '(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]=]|$)' && return 1
      if echo "$rest" | grep -Eq -- '(^|[[:space:]])(-X|--method)([[:space:]]+|=)'; then
        echo "$rest" | grep -Eq -- '(^|[[:space:]])(-X|--method)([[:space:]]+|=)GET([[:space:]]|$)' && return 0
        return 1
      fi
      return 0 ;;
  esac
  return 1
}

segment_ok(){
  local seg="$1" w
  echo "$seg" | grep -Eq -- '--no-verify\b' && return 1
  # An assignment that redirects which binaries or hooks the rest of the line
  # runs is not a read.
  echo "$seg" | grep -Eq '^[[:space:]]*(PATH|GIT_[A-Z_]+|LD_[A-Z_]+|DYLD_[A-Z_]+|BASH_ENV|ENV)=' && return 1
  seg=$(echo "$seg" | sed -E 's/^[[:space:]]*[({][[:space:]]*//; s/[[:space:]]*[)}][[:space:]]*$//')
  w=$(word_of "$seg")
  case "$w" in
    ""|for|done|fi|esac|continue|break|:) return 0 ;;
    case) segment_ok "$(echo "$seg" | sed -E 's/^[[:space:]]*case[[:space:]]+[^[:space:]]+[[:space:]]+in[[:space:]]*//')"; return ;;
    # Control-flow words run the command that follows them.
    do|then|else|if|elif|while|until|!|time)
      segment_ok "$(echo "$seg" | sed -E "s/^[[:space:]]*$w[[:space:]]*//")"; return ;;
    git) git_segment_ok "$seg"; return ;;
    gh)  gh_segment_ok "$seg"; return ;;
    sed|yq) echo "$seg" | grep -Eq -- '(^|[[:space:]])(-i|--in-place)' && return 1 ;;
    find)   echo "$seg" | grep -Eq -- '(^|[[:space:]])-(exec|execdir|ok|okdir|delete|fprint0?|fprintf|fls)([[:space:]]|$)' && return 1 ;;
  esac
  echo "$w" | grep -Eq "^(${seg_filters})$"
}

# A redirect into a file turns a read line into a write. /dev/null and the
# temp dirs are exempt, as in the redirect block at the end.
writes_a_file(){ # $1 = part of the line, default all of it
  echo "${1:-$bare}" | grep -oE '[0-9]?>>?[[:space:]]*[^[:space:]&|;<>]+' \
    | sed -E 's/^[0-9]?>>?[[:space:]]*//' \
    | grep -vE '^(/dev/|/tmp/|/private/tmp/|/var/tmp/|/var/folders/)' | grep -q .
}

# Every file the line redirects or tees into, as written. Single-quoted text
# is blanked first, so awk's `$1 > $2` names no file.
write_targets(){
  echo "$bare_dq" | grep -oE '[0-9&]?>>?[[:space:]]*[^[:space:]&|;<>]+' \
    | sed -E 's/^[0-9&]?>>?[[:space:]]*//' | grep -vE '^&?[0-9-]$' || true
  echo "$bare_dq" | tr '|;&' '\n\n\n' | awk '$1 == "tee" { for (i = 2; i <= NF; i++) if ($i !~ /^-/) print $i }'
}

# A local file write is allowed anywhere but where the gates themselves live:
# a write there could repoint a hook, drop a marker or rewrite settings, which
# would turn off the remote protections. Prints `protected` for such a target,
# `unresolved` for one behind a variable the gate cannot expand, which it
# neither allows nor asks about, or nothing.
write_risk(){
  local t risk=""
  while IFS= read -r t; do
    t=${t//\"/}; t=${t//\'/}
    [[ -z "$t" ]] && continue
    t=${t/#\~/$HOME}
    t=${t//\$\{HOME\}/$HOME}; t=${t//\$HOME/$HOME}
    t=${t//\$\{TMPDIR\}/${TMPDIR:-/tmp}}; t=${t//\$TMPDIR/${TMPDIR:-/tmp}}
    t=${t//\$\{PWD\}/$gitdir}; t=${t//\$PWD/$gitdir}
    if [[ "$t" == *[\$\`]* ]]; then risk=unresolved; continue; fi
    [[ "$t" != /* ]] && t="$gitdir/$t"
    case "$t" in
      /dev/*) ;;
      */.git|*/.git/*|*/.claude/settings*.json|*/.claude/hooks/*|*/.config/git/*|\
      */.claude-remote-off|*/.claude-merge-off|*/.claude-ftl) echo protected; return ;;
    esac
  done < <(write_targets)
  echo "$risk"
}
risk=$(write_risk)

# A line whose git and gh segments are all allowable, chained to commands the
# gate does not know (a build, a test run): nothing here for the gate to ask
# about, so Claude Code's own permission rules judge the rest.
git_part_ok(){
  [[ "$opaque" == 1 || "$risk" == protected ]] && return 1
  local seg local_ok=1
  while IFS= read -r seg; do
    segment_ok "$seg" && continue
    echo "$seg" | grep -Eq '(^|[[:space:](])(git|gh)([[:space:]]|$)' && return 1
  done < <(segments)
  return 0
}

can_allow(){
  [[ "$opaque" == 1 ]] && return 1
  [[ -n "$risk" ]] && return 1
  local seg
  while IFS= read -r seg; do
    segment_ok "$seg" || return 1
  done < <(segments)
  return 0
}

# A line that chains a read to a write asks as a whole, and a refusal drops the
# read with it; split, the read runs unprompted. A list element is a read when
# every pipeline stage is one and a stage does more than move or print. The
# blocks' own seg_extra grants are not reads here.
reads_beside_a_write(){
  [[ "$opaque" == 1 ]] && return 1
  local seg_extra_git='' seg_extra_gh='' local_ok=0
  local el stage w reads=0 writes=0 is_read real
  while IFS= read -r el; do
    [[ -z "${el//[[:space:]]/}" ]] && continue
    case "$(word_of "$el")" in for|while|until|if|case|do|then|else|elif|fi|done|esac) return 1 ;; esac
    is_read=1; real=0
    while IFS= read -r stage; do
      if ! segment_ok "$stage" || writes_a_file "$stage"; then is_read=0; break; fi
      w=$(word_of "$(echo "$stage" | sed -E 's/^[[:space:]]*[({][[:space:]]*//')")
      case "$w" in cd|echo|printf|true|false|:|pwd|date|sleep|test|\[|\[\[|read) ;; *) real=1 ;; esac
    done < <(echo "$el" | tr '|' '\n')
    if [[ "$is_read" == 0 ]]; then writes=1
    elif [[ "$real" == 1 ]]; then reads=1
    fi
  done < <(echo "$bare" | awk '{gsub(/\|\||&&|;/,"\n"); print}')
  [[ "$reads" == 1 && "$writes" == 1 ]]
}

# ── DENY backstop (always, no opt-in) ──
#
# Runs before any block that can emit `allow`, so a compound line pairing an
# allowable command with a denied one is denied on the denied half.

# Prints the word that makes a git add/stage/commit on the line stage more
# than the paths it names, `?` for a word the gate cannot read, or nothing.
# The line is split into words as the shell splits it: quotes and backslashes
# removed, comments and heredoc bodies dropped, redirections and their targets
# skipped. A `$`, backtick or brace expansion and a leading `~` become \001,
# since what they expand to is unknown here. A short cluster ends at commit's
# first option that takes a value, so -qam is -a but -mam is a message.
bulk_staging(){ # $1 = command line
  printf '%s\n' "$1" | awk -v root="$repo_root" -v root2="$root_alias" '
    function hit(w) { if (!hitw) hitw = w }
    # 1 when np is nr, above it or inside it; rel is then the path below nr.
    function under(np, nr) {
      rel = ""
      if (np == "" || index(nr "/", np "/") == 1) return 1
      if (index(np, nr "/") != 1) return 0
      rel = substr(np, length(nr) + 2); return 1
    }
    # git takes any unambiguous prefix of a long option.
    function long(w, name, min) { w = substr(w, 3); sub(/=.*/, "", w); return length(w) >= min && index(name, w) == 1 }
    # Drops empty and . components; sets dots when one is .. and globs when
    # every other component is made of *, ? and [...] globs alone.
    function norm(p,   n, c, k, out, t) {
      n = split(p, c, "/"); out = ""; dots = 0; globs = 1
      for (k = 1; k <= n; k++) {
        if (c[k] == "" || c[k] == ".") continue
        if (c[k] == "..") dots = 1
        else { t = c[k]; gsub(/\[[!^]?\]?[^]]*\]/, "?", t); if (t !~ /^[*?]+$/) globs = 0 }
        out = out (out == "" ? "" : "/") c[k]
      }
      return out
    }
    function pathspec(p,   w, mg, np, nr) {
      w = p
      if (index(p, X)) { segu = 1; return }
      # Pathspec magic: :/ and :(top) anchor at the root, so the path after
      # them is what counts. Exclude magic stages everything it does not name.
      if (p ~ /^:\(/) {
        mg = substr(p, 3); sub(/\).*/, "", mg); p = substr(p, length(mg) + 4)
        if (mg "," !~ /^((top|icase|literal|glob),)+$/) { segu = 1; return }
      } else if (p ~ /^:/) {
        match(p, /^:[\/!^]*:?/); mg = substr(p, 2, RLENGTH - 1); p = substr(p, RLENGTH + 1)
        if (mg ~ /[!^]/) { segu = 1; return }
      } else if (p ~ /^\//) {
        # Outside the root as either spelling has it, the path may still
        # reach it through some other symlink.
        np = norm(p); if (dots) { segu = 1; return }
        if (!under(np, norm(root)) && !(root2 != "" && under(np, norm(root2)))) { segu = 1; return }
        if (rel == "") { hit(w); return }
        p = rel
      }
      np = norm(p)
      if (np == "" || globs) hit(w)
      else if (dots) segu = 1
    }
    function arg(w,   i, c, e) {
      if (take) { take = 0; return }
      if (!paths && w == "--") { paths = 1; return }
      if (!paths && w ~ /^--./) {
        e = index(w, "="); if (index(w, X) && (!e || index(w, X) < e)) { segu = 1; return }
        if (long(w, "pathspec-from-file", 11)) { segu = 1; take = !e; return }
        # commit also has --no-date, so --no-d is ambiguous there.
        if (long(w, "no-dry-run", op == "commit" ? 5 : 4)) { dry = 0; return }
        if (long(w, "dry-run", op == "commit" ? 2 : 1)) { dry = 1; return }
        if (op == "commit") {
          if (w == "--all") hit(w)
          else if (w ~ /^--(message|file|reuse-message|reedit-message|template|author|date|cleanup|fixup|squash|trailer)$/) take = 1
        } else if (long(w, "all", 1) || long(w, "update", 1) || long(w, "renormalize", 3) || long(w, "no-ignore-removal", 11)) hit(w)
        return
      }
      if (!paths && w ~ /^-./) {
        for (i = 2; i <= length(w); i++) {
          c = substr(w, i, 1)
          if (c == X) { segu = 1; return }
          if (op != "commit") { if (c == "n") dry = 1; else if (c == "A" || c == "u") hit(w); continue }
          if (c == "a") { hit(w); return }
          if (index("mFCct", c)) { take = (i == length(w)); return }
          if (index("Su", c)) return
        }
        return
      }
      pathspec(w)
    }
    # Control words and assignments run the command after them. A launcher
    # runs one further on, past options whose values are not knowable here,
    # so its command is the next git word.
    function segment(   k) {
      k = 1
      while (k <= nw && (words[k] ~ /^(if|then|else|elif|do|while|until|time|!|\{|\})$/ || words[k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) k++
      if (words[k] ~ /^(command|builtin|exec|env|nohup|nice|xargs|sudo)$/)
        while (k <= nw && words[k] !~ /^(.*\/)?git$/) k++
      if (words[k] !~ /^(.*\/)?git$/) return
      for (k++; k <= nw; k++) {
        if (words[k] !~ /^-/) break
        if (words[k] ~ /^(-C|-c|--git-dir|--work-tree|--namespace|--config-env|--attr-source)$/) k++
      }
      op = words[k]
      if (op != "add" && op != "stage" && op != "commit") return
      # Every word is read before judging: git lets the last of -n and
      # --no-dry-run win, wherever the bulk flag sits.
      paths = take = dry = segu = 0; hitw = ""
      for (k++; k <= nw; k++) arg(words[k])
      if (dry) return
      if (hitw != "" && found == "") found = hitw
      if (segu) unsure = 1
    }
    function endword() {
      if (inword) {
        if (skip) skip = 0
        else if (hdpend) { delim[++nd] = w; dash[nd] = hdash; hdpend = 0 }
        else words[++nw] = w
      }
      w = ""; inword = 0
    }
    function endseg() { endword(); if (nw) segment(); nw = 0 }
    function redirect(i,   op) {
      if (inword && w ~ /^[0-9]+$/) { w = ""; inword = 0 } else endword()
      # <( and >( are process substitutions: a command, not a target.
      if (substr(s, i + 1, 1) == "(") return i + 1
      if (substr(s, i, 3) == "<<<") { skip = 1; return i + 3 }
      if (substr(s, i, 2) == "<<") { i += 2; hdash = (substr(s, i, 1) == "-"); hdpend = 1; return i + hdash }
      while (index("<>&|", substr(s, i, 1))) { op = op substr(s, i, 1); i++ }
      if (op ~ /&$/ && substr(s, i, 1) ~ /[0-9-]/) { while (substr(s, i, 1) ~ /[0-9-]/) i++; return i }
      skip = 1; return i
    }
    function bodies(i,   k, e, t) {
      for (k = 1; k <= nd; k++)
        while (i <= n) {
          e = index(substr(s, i), "\n"); if (!e) e = n - i + 2
          t = substr(s, i, e - 1); i += e
          if (dash[k]) sub(/^\t+/, "", t)
          if (t == delim[k]) break
        }
      nd = 0; return i
    }
    # Index just past the $( … ) that opens at i. Its quotes, nested
    # substitutions and heredoc bodies are skipped whole, so their parens and
    # quotes cannot end it early or leak into the enclosing word.
    function subst(i,   depth, c, q2, dl, dd, e, t) {
      depth = 1; i += 2
      while (i <= n) {
        c = substr(s, i, 1)
        if (q2 == "\047") { if (c == "\047") q2 = ""; i++; continue }
        if (c == "\\") { i += 2; continue }
        if (substr(s, i, 2) == "$(") { i = subst(i); continue }
        if (c == "`") { i = backtick(i); continue }
        if (q2 == "\"") { if (c == "\"") q2 = ""; i++; continue }
        if (c == "\047" || c == "\"") { q2 = c; i++; continue }
        if (substr(s, i, 2) == "<<" && substr(s, i, 3) != "<<<") {
          i += 2; dd = (substr(s, i, 1) == "-"); i += dd
          while (substr(s, i, 1) ~ /[ \t]/) i++
          if (match(substr(s, i), /^["\047\\]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) { dl = substr(s, i, RLENGTH); i += RLENGTH; gsub(/["\047\\]/, "", dl) }
          continue
        }
        if (c == "\n" && dl != "") {
          i++
          while (i <= n) {
            e = index(substr(s, i), "\n"); if (!e) e = n - i + 2
            t = substr(s, i, e - 1); i += e
            if (dd) sub(/^\t+/, "", t)
            if (t == dl) break
          }
          dl = ""; continue
        }
        if (c == "(") depth++
        else if (c == ")" && !--depth) return i + 1
        i++
      }
      return i
    }
    # 1 when the { at i opens a brace expansion: a , or .. at its own level
    # before the } that closes it, all within one word.
    function brace(i,   depth, c, e, list) {
      for (; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\") { i++; continue }
        if (c == "\047") { e = index(substr(s, i + 1), "\047"); if (!e) return 0; i += e; continue }
        if (c == "\"") { for (i++; i <= n && substr(s, i, 1) != "\""; i++) if (substr(s, i, 1) == "\\") i++; continue }
        if (index(" \t\n;&|()<>", c)) return 0
        if (c == "{") depth++
        else if (c == "}" && !--depth) return list
        else if (depth == 1 && (c == "," || substr(s, i, 2) == "..")) list = 1
      }
      return 0
    }
    function backtick(i) {
      for (i++; i <= n && substr(s, i, 1) != "`"; i++) if (substr(s, i, 1) == "\\") i++
      return i + 1
    }
    { s = s $0 "\n" }
    END {
      X = "\001"; n = length(s); i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (q == "\047") {
          e = index(substr(s, i), "\047"); if (!e) e = n - i + 2
          w = w substr(s, i, e - 1); q = ""; i += e; continue
        }
        if (q == "\"") {
          if (substr(s, i, 2) == "$(") { w = w X; i = subst(i); continue }
          if (c == "`") { w = w X; i = backtick(i); continue }
          if (c == "\"") q = ""
          else if (c == "\\") { d = substr(s, i + 1, 1); if (index("$`\"\\\n", d)) { if (d != "\n") w = w d; i++ } else w = w c }
          else if (c == "$") w = w X
          else w = w c
          i++; continue
        }
        if (c == "\\") { d = substr(s, i + 1, 1); if (d != "\n") { w = w d; inword = 1 } i += 2; continue }
        if (c == "\047" || c == "\"") { q = c; inword = 1; i++; continue }
        if (c == "#" && !inword) { while (i <= n && substr(s, i, 1) != "\n") i++; continue }
        if (c == " " || c == "\t") { endword(); i++; continue }
        if (c == "\n") { endseg(); i = bodies(i + 1); continue }
        if (c == "<" || c == ">" || substr(s, i, 2) == "&>") { i = redirect(i); continue }
        if (index(";&|()", c)) { endseg(); i++; continue }
        if (substr(s, i, 2) == "$(") { w = w X; inword = 1; i = subst(i); continue }
        if (c == "`") { w = w X; inword = 1; i = backtick(i); continue }
        if (c == "$" || (c == "~" && !inword) || (c == "{" && brace(i))) c = X
        w = w c; inword = 1; i++
      }
      endseg()
      if (found) print found; else if (unsure) print "?"
    }'
}

# git resolves symlinks in the root it reports (macOS /var and /tmp are
# links), so the gate also knows the root as the line's directory spells it.
root_alias=""
if [[ -n "$repo_root" ]]; then
  phys=$(cd "$gitdir" 2>/dev/null && pwd -P) || phys=""
  case "$phys/" in
    "$repo_root"/*) below=${phys#"$repo_root"}; [[ "$gitdir" == *"$below" ]] && root_alias=${gitdir%"$below"} ;;
  esac
fi
# Ahead of the push block, whose ask would otherwise mask this deny.
staging=$(bulk_staging "$cmd")
[[ -n "$staging" && "$staging" != "?" ]] && emit deny "bulk staging ($staging) sweeps in whatever else is in the tree — stage named paths: git add <path>… then git commit."

# A push to any branch but trunk is allowed. pre-push is the backstop for what
# text cannot see: under CLAUDECODE it denies trunk, the default branch, tags,
# deletions and non-fast-forward pushes from the ref list git hands it.
if echo "$cmd" | grep -Eq '\bgit\b([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+push\b'; then
  echo "$cmd" | grep -Eq '(--force-with-lease|--force|[[:space:]]-[a-zA-Z]*f)\b' \
    && emit deny "force-push is never auto-run — do it yourself."
  echo "$cmd" | grep -Eq '[[:space:]]\+[^[:space:]]' \
    && emit deny "force-push (+refspec) is never auto-run — do it yourself."
  echo "$cmd" | grep -Eq '(--tags|--follow-tags)\b' \
    && emit deny "pushing tags is the prod deploy trigger — human-only."
  echo "$cmd" | grep -Eq -- '--no-verify\b|hooks[Pp]ath' \
    && emit deny "a push that skips or repoints the pre-push hook is human-only."
  echo "$cmd" | grep -Eq -- '(--all|--mirror|--delete|--prune)\b|[[:space:]]-[a-zA-Z]*d\b|[[:space:]]:[^[:space:]]' \
    && emit deny "pushing every branch, or deleting a remote branch, is human-only."
  default_branch=$(git -C "$gitdir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  default_branch=${default_branch#origin/}
  echo "$cmd" | grep -Eq "(^|[[:space:]]|:|/|\\+)(main|master${default_branch:+|$default_branch})([[:space:]]|:|\$)" \
    && emit deny "pushing main/master or the default branch is human-only (merge deploys dev)."
  case "$cur" in
    main|master|"") emit deny "push from main/master (or an undetermined branch) is human-only." ;;
  esac
  [[ "$cur" == "$default_branch" ]] && emit deny "push from the default branch '$cur' is human-only."
  seg_extra_git='push'
  [[ "$remote_off" != 1 ]] && can_allow && emit allow "git push of a feature branch."
  seg_extra_git=''
  remote_gate "Remote write (push)"
fi

if echo "$cmd" | grep -Eq '\bgit\b([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+commit\b'; then
  case "$cur" in
    main|master) emit deny "commit on $cur is blocked — create a feature branch first: git switch -c <type>/<kebab-name>." ;;
  esac
fi

# `git pull` is fetch + integrate. The integrate half is a local merge or
# rebase, so it follows the merge/rebase opt-out; --ff-only writes no merge
# commit and rewrites no sha, so it survives even that.
if echo "$cmd" | grep -Eq '\bgit\b([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+pull\b'; then
  [[ "$merge_off" == 1 ]] && ! echo "$cmd" | grep -Eq -- '[[:space:]]--ff-only([[:space:]]|$)' \
    && emit deny "git pull merges or rebases — this repo is opted out (.claude-merge-off). Use 'git pull --ff-only', or re-enable with: claude-gate merge on"
  seg_extra_git='pull'
  can_allow && emit allow "git pull writes only local history."
  seg_extra_git=''
  remote_gate "Remote write (pull, compound command)"
fi

echo "$cmd" | grep -Eq '\bgh\b[^|;&]*\bpr[[:space:]]+merge\b' && emit deny "gh pr merge is denied permanently — no marker file enables it.
If YOU run this yourself: GitHub merges the PR head into its base branch ON THE SERVER, immediately, and with --delete-branch also deletes the head branch. There is no local undo — reversing it needs a revert PR."
echo "$cmd" | grep -Eq '\bgh\b[^|;&]*\b(pr[[:space:]]+update-branch|repo[[:space:]]+sync)\b' \
  && emit deny "gh pr update-branch and gh repo sync write to a remote branch on the server — denied permanently. Run it yourself."
# gh api defaults to GET; a field, an input file or another method makes it a
# write. These endpoints and mutations move a branch or commit onto one.
if echo "$cmd" | grep -Eq '\bgh\b[^|;&]*\bapi\b' \
   && echo "$cmd" | grep -Eq '(git/refs|/merges\b|/merge-upstream|/branches/|/pulls/[^/[:space:]]+/(merge|update-branch)|/contents/|mergePullRequest|mergeBranch|(create|update|delete)Refs?\b|createCommitOnBranch|enablePullRequestAutoMerge|updatePullRequestBranch)' \
   && echo "$cmd" | grep -Eq -- '(^|[[:space:]])(-f|-F|--field|--raw-field|--input|-X|--method)([[:space:]=]|$)' \
   && ! echo "$cmd" | grep -Eq -- '(^|[[:space:]])(-X|--method)([[:space:]]+|=)GET([[:space:]]|$)'; then
  emit deny "gh api write to a ref, merge, branch or contents endpoint moves a remote branch — denied permanently. Run it yourself."
fi
echo "$cmd" | grep -Eq '\bgit\b.*\breset\b.*--hard'          && emit deny "git reset --hard discards work — run it yourself."
echo "$cmd" | grep -Eq '\bgit\b.*\bclean\b.*-[a-zA-Z]*f'     && emit deny "git clean -f deletes untracked files — run it yourself."
echo "$cmd" | grep -Eq '\brm\b[^|;&]*-[a-zA-Z]*(rf|fr)'      && emit deny "rm -rf is not allowed."
echo "$cmd" | grep -Eq '\bshred\b'                           && emit deny "shred irreversibly destroys files — run it yourself."

# ── read-only lines ──
#
# Every segment reads (git, gh or a filter) and nothing is redirected into a
# file: allow, whatever the line starts with. Lines without git or gh are left
# to Claude Code's own permission rules.
if echo "$bare" | grep -Eq '(^|[[:space:]&|;(`])(git|gh)([[:space:]]|$)' && can_allow; then
  emit allow "Read-only git/gh command."
fi

# ── gh ──
#
# A gh line not allowed above is a remote write or a shape the segment
# analysis does not recognise, such as `$(gh …)`. Opening a PR is allowed;
# merging one never is.
if [[ "$remote_off" != 1 ]] \
   && echo "$bare" | grep -Eq '(^|[[:space:]&|;(])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'; then
  seg_extra_gh=1
  can_allow && emit allow "gh pr create."
  seg_extra_gh=''
fi
echo "$bare" | grep -Eq '(^|[[:space:]&|;(`])gh([[:space:]]|$)' && remote_gate "gh CLI command"

# ── merge / rebase ──
#
# Both rewrite only local history, whether the other side is a local branch or
# a remote-tracking ref, so the local-write block below allows them unless the
# repo opts out. `(merge|rebase)([[:space:]]|$)` rather than \b: \b matches
# before the hyphen in merge-base and rebase-related plumbing, which are
# read-only.
if [[ "$merge_off" == 1 ]] \
   && echo "$cmd" | grep -Eq '\bgit\b([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+(merge|rebase)([[:space:]]|$)'; then
  emit deny "Local git merge/rebase blocked — this repo is opted out (.claude-merge-off). Re-enable with: claude-gate merge on"
fi

# ── creating a branch that already exists on the remote ──
#
# Two people picking up one issue produce two branches with one name: yours
# local, theirs on origin with a PR already open. Nothing is lost until someone
# force-pushes, and by then the work is duplicated. Deny at creation instead.
#
# Placed before the dirty-tree block below so a collision denies rather than
# asks. The git-hook halves are post-checkout (a warning, because git cannot
# veto a branch) and ownership_gate in pre-push (the clobber denial itself).
#
# Fails closed: an origin it cannot reach is an `ask`, not an `allow`.
nb_args=""
if echo "$cmd" | grep -Eq '\bgit\b([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+worktree[[:space:]]+add\b'; then
  nb_args=$(echo "$cmd" | sed -E 's/.*worktree[[:space:]]+add([[:space:]]|$)//')
elif echo "$cmd" | grep -Eq '\bgit\b([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+(switch|checkout)([[:space:]]|$)'; then
  # Args are taken from after the subcommand, so a leading `git -c key=val`
  # cannot be mistaken for `switch -c <branch>`.
  nb_args=$(echo "$cmd" | sed -E 's/.*[[:space:]](switch|checkout)([[:space:]]|$)//')
fi

new_branch=""
if [[ -n "$nb_args" ]]; then
  new_branch=$(printf '%s' "$nb_args" | tr ' \t' '\n\n' | awk '
    /^(-b|-B|-c|-C|--create|--force-create|--create-branch)=/ { sub(/^[^=]*=/, ""); print; exit }
    /^(-b|-B|-c|-C|--create|--force-create|--create-branch)$/ { take = 1; next }
    take && length($0) { print; exit }')
  new_branch=${new_branch%%[;\|\&]*}
  new_branch=$(echo "$new_branch" | tr -d "\"'")
fi

if [[ -n "$new_branch" && -n "$repo_root" ]]; then
  gh_here=0; command -v gh >/dev/null 2>&1 && gh_here=1
  gh_in_repo(){ ( cd "$gitdir" >/dev/null 2>&1 && gh "$@" ) 2>/dev/null; }

  ls_rc=0
  ls_out=$(git -C "$gitdir" ls-remote --exit-code --heads origin "$new_branch" 2>/dev/null) || ls_rc=$?

  if [[ "$ls_rc" == 0 ]]; then
    sha=$(printf '%s\n' "$ls_out" | awk '{print $1; exit}')
    who=""
    if git -C "$gitdir" cat-file -e "$sha^{commit}" 2>/dev/null; then
      who=$(git -C "$gitdir" log -1 --format='%an <%ae>, %ad' --date=short "$sha" 2>/dev/null) || who=""
    fi
    prs=""
    if [[ "$gh_here" == 1 ]]; then
      prs=$(gh_in_repo pr list --head "$new_branch" --state open --json number,author,title \
            --jq '.[] | "  #\(.number) by \(.author.login) — \(.title)"') || prs=""
    fi
    # The remote tip's author names the owner when the commit has been fetched
    # here; otherwise the PR line below is the only attribution available.
    emit deny "origin already has a branch named '$new_branch'${who:+, remote tip by $who}.
${prs:+Open PR on that head:
$prs
}Creating a local branch of the same name duplicates work that already exists, and the two copies can only be reconciled by a force-push that discards one side.
To work on theirs:  git fetch origin && git switch $new_branch
Otherwise pick a branch name that is yours alone."

  elif [[ "$ls_rc" != 2 ]]; then
    # 2 means the remote simply has no such branch. Anything else — no network,
    # no such remote, auth failure — leaves the question unanswered.
    emit ask "Could not reach origin to check whether '$new_branch' already exists there (git ls-remote exited $ls_rc).
Approve only if you know that name is free. A duplicate of a teammate's branch is reconcilable only by a force-push."
  fi

  # A branch named for an issue claims that issue. Someone else's open PR or
  # assignment on it means the work is already taken.
  issue=$(printf '%s' "$new_branch" | sed -nE 's#^([0-9]+)([^0-9].*)?$#\1#p')
  if [[ -n "$issue" && "$gh_here" == 1 ]]; then
    ipr=$(gh_in_repo pr list --search "$issue" --state open --json number,author,title,headRefName \
          --jq '.[] | "  #\(.number) on \(.headRefName) by \(.author.login) — \(.title)"') || ipr=""
    [[ -n "$ipr" ]] && emit deny "issue #$issue already has an open PR:
$ipr
Starting '$new_branch' duplicates it. Review or build on that PR's head instead:
  git fetch origin && git switch <the head branch above>"

    iv_rc=0
    iv=$(gh_in_repo issue view "$issue" --json state,assignees \
         --jq '.state + "\t" + ([.assignees[].login] | join(","))') || iv_rc=$?
    if [[ "$iv_rc" == 0 && -n "$iv" ]]; then
      istate=${iv%%$'\t'*}; iassign=${iv#*$'\t'}
      if [[ "$istate" == "OPEN" ]]; then
        me=$(gh_in_repo api user --jq .login) || me=""
        if [[ -z "$iassign" ]]; then
          emit ask "issue #$issue is open and unassigned. Assign yourself first so nobody else picks it up:
  gh issue edit $issue --add-assignee @me
Approve to create '$new_branch' anyway."
        elif [[ -z "$me" ]] || ! printf '%s' "$iassign" | tr ',' '\n' | grep -qxF "$me"; then
          emit deny "issue #$issue is assigned to $iassign, not you${me:+ ($me)}.
Starting '$new_branch' duplicates their work. Ask them, or take an issue that is yours."
        fi
      fi
    fi
  fi
fi

# ── branch switch with a dirty tree ──
#
# Uncommitted changes follow you across a switch and land on the branch you
# arrive at, quietly mixing unrelated work together. A worktree gives the new
# branch its own checkout and leaves the dirty one untouched.
if echo "$cmd" | grep -Eq '\bgit\b([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+(switch|checkout)([[:space:]]|$)'; then
  sw=$(echo "$cmd" | grep -oE '(switch|checkout)([[:space:]]|$)' | head -1 | tr -d '[:space:]')
  swargs=$(echo "$cmd" | sed -E "s/.*[[:space:]]${sw}([[:space:]]|\$)//")
  target=$(echo "$swargs" | tr ' ' '\n' | grep -vE '^-|^$' | head -1)

  # `git checkout -- <path>` and `git checkout <path>` restore files and change
  # no branch, so they are none of this gate's business. git switch takes no
  # paths, so only checkout needs the distinction.
  restore=0
  if [[ "$sw" == checkout ]]; then
    echo "$swargs" | grep -Eq '(^|[[:space:]])--([[:space:]]|$)' && restore=1
    [[ -n "$target" && -e "$gitdir/$target" ]] \
      && ! git -C "$gitdir" show-ref --verify --quiet "refs/heads/$target" && restore=1
  fi

  if [[ "$restore" == 0 && -n "$repo_root" && -n "$target" && "$target" != "$cur" ]]; then
    dirty=$(git -C "$gitdir" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${dirty:-0}" -gt 0 ]]; then
      emit ask "$dirty uncommitted file(s) will follow this switch onto '$target' and become part of that branch's work.
If they belong to ${cur:-the branch you are on}, leave them here and give the new work its own checkout:
  git worktree add ../$(basename "$repo_root")-${target//\//-} -b $target
Approve only if the uncommitted changes are meant to move."
    fi
  fi
fi

# Every deny is above this point, so asking here cannot mask one.
[[ "$risk" == protected ]] && emit ask "Writes into .git, the Claude hooks or settings, git's global hooks, or a gate marker — needs approval."
[[ "$staging" == "?" ]] && emit ask "git add/commit with a pathspec the gate cannot place in the repo — it may expand to the whole tree."

# ── local git writes ──
#
# Every deny, and every ask the gate means to put to the human, is above this
# point. What is left that touches only this checkout runs: staging, commits,
# branches, switches, stashes, worktrees, local merges and rebases. A segment
# git_local_ok refuses, an opaque line or a redirect into a file falls through.
local_ok=1
can_allow && emit allow "Local git write — touches only this checkout."
local_ok=0

# ── git classification ──
#
# Reads and plain local writes were allowed above; what is left discards work,
# rewrites config, or is a shape the segment analysis could not clear.

if [[ "$first" == "git" ]]; then
  git_part_ok && exit 0
  sub=$(git_sub_of "$bare")
  case "$sub" in
    add|stage|commit|switch|checkout|restore|reset|merge|rebase|cherry-pick|revert|rm|mv|am|apply|submodule|clean)
      emit ask "Local git write ($sub) — needs approval." ;;
    worktree|branch|config|remote|stash)
      git_segment_ok "$(segments | head -1)" || emit ask "Local git write ($sub) — needs approval." ;;
  esac
  exit 0
fi

# touch / mkdir are pure create
if [[ "$first" == "touch" || "$first" == "mkdir" ]] && can_allow; then
  emit allow "Creating files/directories."
fi

[[ -n "$(write_targets)" ]] && can_allow && emit allow "Local file write."

exit 0
