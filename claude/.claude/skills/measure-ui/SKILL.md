---
name: measure-ui
description: Measure rendered elements in a real headless browser — bounding box, computed styles, text/background contrast, and a cropped screenshot per match — in one command. Use for any visual claim (size, spacing, alignment, color, contrast, overflow) and before/after proof of a UI change. Prefer it over writing a one-off Playwright script. For multi-step interaction (login, clicking through a flow, finding selectors) use playwright-cli instead.
allowed-tools: Bash(node ~/.claude/skills/measure-ui/measure.mjs:*)
---

# measure-ui

One Bash call: load a page, measure every match of each selector, print one JSON line per match, write a cropped PNG per match.

```bash
node ~/.claude/skills/measure-ui/measure.mjs <url|file> <selector>... [options]
```

Run it from the project root (or worktree) so it resolves that project's `@playwright/test` and its downloaded browser. Outside a project it falls back to the global `@playwright/cli` and the installed Chrome.

Selectors are Playwright selectors: CSS, `text=Deploy`, `role=button[name="Deploy"]`, `[data-testid=x]`.

## Options

| Option | Default | Use |
| --- | --- | --- |
| `--theme light\|dark\|both` | `light` | Emulated `prefers-color-scheme`. Use `both` for any color claim. |
| `--viewport WxH[,WxH]` | `1280x800` | One run per viewport, e.g. `390x844,1280x800` for breakpoints. |
| `--state FILE` | | Playwright storageState JSON for an authenticated page (see Auth). |
| `--init JS` | | Runs before page scripts in every run, e.g. `"localStorage.setItem('theme-key','dark')"` when the app's theme is a stored choice rather than the system scheme. |
| `--hover SEL` / `--focus SEL` | | Put an element in that state before measuring. |
| `--wait SEL` | first target | Element to wait for before measuring (15 s cap). |
| `--settle MS` | `0` | Extra wait for animations or late data. |
| `--props a,b` | default set | Replace the reported properties; listed ones are reported even when unset. |
| `--max N` | `3` | Matches reported per selector. |
| `--pad PX` | `8` | Screenshot margin around each match. |
| `--dpr N` | `1` | Screenshot scale. `2` only when sub-pixel detail matters; it quadruples image tokens. |
| `--out DIR` | `$TMPDIR/measure-ui` | Screenshot directory. Pass the session scratchpad. |
| `--no-shot` | | Numbers only. |

## Output

NDJSON on stdout. A header line per run (`run`, final `url`, and `errors` if the page logged any), then one line per match:

```json
{"run":"1280x800 dark","selector":".btn","match":"1/2","text":"Deploy","rect":{"x":24,"y":96,"w":67.5,"h":30},"styles":{"color":"#ffffff","background-color":"#ff7a1a","padding":"6px 12px","border-radius":"6px"},"contrast":{"fg":"#ffffff","bg":"#ff7a1a","ratio":2.61},"shot":"/…/btn-1280-dark-0.png"}
```

- Colors in any syntax (oklch, color(), rgba) are normalized to hex; alpha becomes `#rrggbbaa`.
- Unset values (`none`, `0px`, `normal`, opacity 1, outline/border color with no style) are dropped from the default set.
- `rect` is in viewport pixels after the element is scrolled into view.
- `contrast` composites translucent backgrounds up the ancestor chain to the first opaque one. `bgImage: true` means a gradient or image sits in that chain and the ratio ignores it — check the screenshot.
- A selector with no match prints `"match":"0/0"`, and the exit code is 1. Exit 2 is a usage error.
- An `errors` field or a redirected `url` usually means the page needs auth (`--state`) or the dev server is down.

Read each `shot` PNG with the Read tool to show the cropped element; that pairs the measurement with the screenshot.

## Auth

Never type credentials. Have the user log in once in a visible browser, then save the state:

```bash
mkdir -p ~/.cache/pw-state && chmod 700 ~/.cache/pw-state
playwright-cli -s=auth open --headed https://<host>/
# user logs in, then:
playwright-cli -s=auth state-save ~/.cache/pw-state/<host>.json && chmod 600 ~/.cache/pw-state/<host>.json
playwright-cli -s=auth close
```

Then pass `--state ~/.cache/pw-state/<host>.json`. The file holds live session tokens: keep it out of repos, scratchpads and artifacts. When a run redirects to the login page, the state has expired; repeat the steps.
