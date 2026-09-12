#!/usr/bin/env bash
# bash-write-gate.sh — PreToolUse(Bash) gate.
#
# Permission tiers:
#   reads + read-only git/gh        -> allow (no prompt)
#   create NEW file                 -> allow (no prompt)
#   git pull --ff-only              -> allow (no prompt)
#   local git writes (add, commit)  -> ask
#   new branch whose name is taken
#     on origin, or whose issue is
#     someone else's                -> deny (always)
#   LOCAL merge/rebase              -> ask (default) or deny (.claude-merge-off)
#   overwrite/modify EXISTING file  -> ask
#   remote git writes (push), gh    -> ask (default) or deny (.claude-remote-off)
#   REMOTE merge/rebase, gh pr merge-> deny, always. No marker changes it.
#   force-push, push main, tags    -> deny (always)
#   reset --hard, clean -f, rm -rf  -> deny (always)
#
# Two per-repo opt-OUT markers, both files in the repo root. They tighten a
# repo below the default; their absence is the permissive default:
#   .claude-remote-off  push/gh            ask   -> deny
#   .claude-merge-off   LOCAL merge/rebase allow -> deny
# Neither affects a merge or rebase whose target is a remote ref, and nothing
# permits `gh pr merge`. Those are human-only, permanently.
# Flip both with `claude-gate`.
#
# A compound line is judged segment by segment, wherever the git or gh segment
# sits: it can be auto-approved only when every segment is itself in the allow
# tier and nothing is redirected into a file. Command substitution, process
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
# and anything that writes (tee, mv, cp, export). sed and yq lose the exemption
# under -i, find under -exec or -delete.
seg_filters='cat|head|tail|less|more|grep|egrep|fgrep|rg|jq|yq|wc|sort|uniq|cut|tr|awk|sed|column|nl|fold|rev|tac|echo|printf|true|false|date|basename|dirname|realpath|readlink|pbcopy|cd|pwd|ls|file|stat|du|df|which|type|test|\[|\[\[|read|seq|diff|cmp|comm|paste|shasum|sleep|find'
seg_git='status|log|diff|show|reflog|shortlog|whatchanged|blame|describe|rev-parse|rev-list|merge-base|name-rev|symbolic-ref|var|cat-file|ls-files|ls-tree|ls-remote|for-each-ref|count-objects|grep|fetch|show-ref|check-ignore'
# A block that has already validated its own subcommand against the remote and
# marker rules adds it here before asking whether the rest of the line is safe.
seg_extra_git=''

git_segment_ok(){
  local sub args
  sub=$(git_sub_of "$1"); args=$(git_args_of "$1")
  # --output sends log/diff/show output to a file.
  echo "$args" | grep -Eq -- '(^|[[:space:]])--output(=|[[:space:]])' && return 1
  [[ -n "$seg_extra_git" && "$sub" == "$seg_extra_git" ]] && return 0
  echo "$sub" | grep -Eq "^(${seg_git})$" && return 0
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
writes_a_file(){
  echo "$bare" | grep -oE '[0-9]?>>?[[:space:]]*[^[:space:]&|;<>]+' \
    | sed -E 's/^[0-9]?>>?[[:space:]]*//' \
    | grep -vE '^(/dev/|/tmp/|/private/tmp/|/var/tmp/|/var/folders/)' | grep -q .
}

can_allow(){
  [[ "$opaque" == 1 ]] && return 1
  writes_a_file && return 1
  local seg
  while IFS= read -r seg; do
    segment_ok "$seg" || return 1
  done < <(segments)
  return 0
}

# ── DENY backstop (always, no opt-in) ──
#
# Runs before any block that can emit `allow`, so a compound line pairing an
# allowable command with a denied one is denied on the denied half.

if echo "$cmd" | grep -Eq '\bgit\b([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+push\b'; then
  echo "$cmd" | grep -Eq '(--force-with-lease|--force|[[:space:]]-[a-zA-Z]*f)\b' \
    && emit deny "force-push is never auto-run — do it yourself."
  echo "$cmd" | grep -Eq '[[:space:]]\+[^[:space:]]' \
    && emit deny "force-push (+refspec) is never auto-run — do it yourself."
  echo "$cmd" | grep -Eq '(--tags|--follow-tags)\b' \
    && emit deny "pushing tags is the prod deploy trigger — human-only."
  echo "$cmd" | grep -Eq -- '--no-verify\b' \
    && emit deny "push --no-verify bypasses the pre-push hook — human-only."
  echo "$cmd" | grep -Eq '(^|[[:space:]]|:|/|\+)(main|master)([[:space:]]|:|$)' \
    && emit deny "pushing main/master is human-only (merge deploys dev)."
  case "$cur" in
    main|master|"") emit deny "push from main/master (or an undetermined branch) is human-only." ;;
  esac
  remote_gate "Remote write (push)"
fi

if echo "$cmd" | grep -Eq '\bgit\b([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+commit\b'; then
  case "$cur" in
    main|master) emit deny "commit on $cur is blocked — create a feature branch first: git switch -c <type>/<kebab-name>." ;;
  esac
fi

# `git pull` is fetch + integrate. The integrate half is a merge or rebase
# against a remote ref, so only --ff-only survives: it can advance a branch
# pointer or fail, never write a merge commit and never rewrite a sha. That
# makes it a local write on top of an already-allowed fetch, so it is allowed.
if echo "$cmd" | grep -Eq '\bgit\b([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+pull\b'; then
  echo "$cmd" | grep -Eq -- '[[:space:]](--rebase|-r)([[:space:]]|=|$)' \
    && emit deny "git pull --rebase is a remote rebase — denied permanently.
If YOU run this yourself: git fetches, then replays your local commits on top of the remote branch with new shas, so ${cur:-your branch} diverges from its pushed copy and the next push needs --force. Use 'git fetch' and inspect first if you only want to see what changed."
  echo "$cmd" | grep -Eq -- '[[:space:]]--ff-only([[:space:]]|$)' \
    || emit deny "plain git pull merges a remote ref into ${cur:-your branch} — denied permanently.
If YOU run this yourself: git fetches, then merges the remote branch into yours, writing a merge commit whenever the two have diverged. Use 'git pull --ff-only', which is allowed, to refuse anything that is not a clean fast-forward."
  seg_extra_git='pull'
  can_allow && emit allow "git pull --ff-only writes only locally — it fast-forwards or fails."
  seg_extra_git=''
  remote_gate "Remote write (pull --ff-only, compound command)"
fi

echo "$cmd" | grep -Eq '\bgh\b.*\bpr\b.*\bmerge\b' && emit deny "gh pr merge is denied permanently — no marker file enables it.
If YOU run this yourself: GitHub merges the PR head into its base branch ON THE SERVER, immediately, and with --delete-branch also deletes the head branch. There is no local undo — reversing it needs a revert PR."
echo "$cmd" | grep -Eq '\bgit\b([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+tag\b' \
  && ! echo "$cmd" | grep -Eq '\btag\b([[:space:]]+(-l|--list|-n)|[[:space:]]*($|[|;&]))' \
  && emit deny "creating tags is the prod deploy trigger — human-only."
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
# analysis does not recognise, such as `$(gh …)`.
echo "$bare" | grep -Eq '(^|[[:space:]&|;(`])gh([[:space:]]|$)' && remote_gate "gh CLI command"

# ── merge / rebase ──
#
# `(merge|rebase)([[:space:]]|$)` rather than \b: \b matches before the hyphen
# in merge-base and rebase-related plumbing, which are read-only.
if echo "$cmd" | grep -Eq '\bgit\b([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+(merge|rebase)([[:space:]]|$)'; then
  remotes=$(git -C "$gitdir" remote 2>/dev/null | paste -sd'|' -)
  [[ -z "$remotes" ]] && remotes='origin|upstream'

  # Each merge/rebase segment is tested on its own arguments — reading to the
  # end of the line would mistake a URL in a later command for a remote ref.
  op=""; is_remote=0
  while IFS= read -r seg; do
    s=$(git_sub_of "$seg")
    case "$s" in merge|rebase) ;; *) continue ;; esac
    [[ -z "$op" ]] && op="$s"
    args=$(echo "$seg" | sed -E "s/.*[[:space:]]${s}([[:space:]]|\$)//")

    # --abort/--continue/etc. steer an in-flight operation; they resolve local
    # state and never reach a remote, so they sit in the local tier.
    echo "$args" | grep -Eq -- '--(abort|quit|continue|skip|edit-todo|show-current-patch)\b' && continue

    echo "$args" | grep -Eq "(^|[[:space:]=])($remotes)/"                && { op="$s"; is_remote=1; break; }
    echo "$args" | grep -Eq '(^|[[:space:]=])(FETCH_HEAD|refs/remotes/)' && { op="$s"; is_remote=1; break; }
    echo "$args" | grep -Eq '(https?://|git@|ssh://|git://)'             && { op="$s"; is_remote=1; break; }
    # Bare `git rebase` rebases onto @{upstream} — a remote-tracking ref.
    if [[ "$s" == rebase ]] && ! echo "$args" | tr ' ' '\n' | grep -qE '^[^-][^[:space:]]*'; then
      op="$s"; is_remote=1; break
    fi
  done < <(echo "$cmd" | awk '{gsub(/\|\||&&|;|\|/,"\n"); print}')
  [[ -z "$op" ]] && op=merge

  if [[ "$is_remote" == 1 && "$op" == merge ]]; then
    emit deny "Remote merge is denied permanently — no marker file enables it.
If YOU run this yourself: git replays the remote-tracking ref's commits into ${cur:-your current branch} and writes a merge commit (or fast-forwards). Nothing is sent to the server, but your local history changes and the next push carries those commits; conflicts can land in your working tree. Undo with 'git merge --abort' mid-conflict, or 'git reset --hard ORIG_HEAD' once it has committed."
  fi
  if [[ "$is_remote" == 1 && "$op" == rebase ]]; then
    emit deny "Remote rebase is denied permanently — no marker file enables it.
If YOU run this yourself: git rewrites your local commits on top of the remote ref, giving each replayed commit a NEW sha. ${cur:-Your branch} then diverges from its pushed copy, so the next push is rejected unless forced. Undo with 'git rebase --abort' mid-flight, or 'git reset --hard ORIG_HEAD' after it finishes."
  fi

  [[ "$merge_off" == 1 ]] &&
    emit deny "Local git $op blocked — this repo is opted out (.claude-merge-off). Re-enable with: claude-gate merge on"
  emit ask "Local git $op — needs approval."
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

# ── git classification ──
#
# Read-only lines were allowed above; what is left is a local write or a read
# in a shape the segment analysis could not clear.

if [[ "$first" == "git" ]]; then
  sub=$(git_sub_of "$bare")
  case "$sub" in
    add|commit|switch|checkout|restore|reset|cherry-pick|revert|rm|mv|am|apply|submodule|clean)
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

# redirect / tee — split create (allow) vs overwrite-existing (ask)
targets=""
echo "$cmd" | grep -Eq '>[^&]|^>|>$' && targets+=$'\n'$(echo "$cmd" | grep -oE '[0-9&]?>>?[[:space:]]*[^[:space:]&|;<>]+' | sed -E 's/^[0-9&]?>>?[[:space:]]*//')
[[ "$first" == "tee" ]] && targets+=$'\n'$(echo "$cmd" | sed -E 's/^[[:space:]]*tee[[:space:]]+//' | tr ' ' '\n' | grep -vE '^-')

if [[ -n "$(echo "$targets" | tr -d '[:space:]')" ]]; then
  any_exist=0; any_new=0
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    case "$t" in /tmp/*|/private/tmp/*|/var/tmp/*|/var/folders/*|/dev/*) continue;; esac
    e="${t/#\~/$HOME}"; [[ "$e" != /* ]] && e="$cwd/$e"
    if [[ -e "$e" ]]; then any_exist=1; else any_new=1; fi
  done <<< "$targets"
  if [[ "$any_exist" == 1 ]]; then
    emit ask "Redirect/tee targets an existing file — would overwrite/modify it. Approve only if intended."
  fi
  base=$(basename "$first" 2>/dev/null || echo "$first")
  if [[ "$any_new" == 1 ]] && can_allow && ! echo "$base" | grep -Eq '^(rm|rmdir|mv|cp|chmod|chown|chgrp|ln|truncate|sed|dd|shred|git|gh)$'; then
    emit allow "Creating a new file (target does not exist)."
  fi
fi

exit 0
