#!/usr/bin/env node
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { parseArgs } from 'node:util'

const DEFAULT_PROPS = [
  'display', 'box-sizing', 'font-family', 'font-size', 'font-weight', 'line-height', 'letter-spacing',
  'color', 'background-color', 'background-image', 'border-width', 'border-style', 'border-color',
  'border-radius', 'padding', 'margin', 'gap', 'box-shadow', 'outline', 'opacity',
]

const USAGE = `usage: measure.mjs <url|file> <selector>... [options]
  --theme light|dark|both    prefers-color-scheme to emulate (default light)
  --viewport WxH[,WxH...]    one run per viewport (default 1280x800)
  --dpr N                    device scale factor for screenshots (default 1)
  --state FILE               Playwright storageState JSON (auth)
  --init JS                  script run before page scripts, e.g. a localStorage theme key
  --wait SELECTOR            wait for this instead of the first target
  --settle MS                extra wait after load
  --hover SELECTOR           hover before measuring
  --focus SELECTOR           focus before measuring
  --props a,b,c              computed properties to report, replaces the default set
  --max N                    matches reported per selector (default 3)
  --pad PX                   screenshot margin around each match (default 8)
  --out DIR                  screenshot directory (default $TMPDIR/measure-ui)
  --no-shot                  skip screenshots`

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    theme: { type: 'string', default: 'light' },
    viewport: { type: 'string', default: '1280x800' },
    dpr: { type: 'string', default: '1' },
    state: { type: 'string' },
    init: { type: 'string' },
    wait: { type: 'string' },
    settle: { type: 'string', default: '0' },
    hover: { type: 'string' },
    focus: { type: 'string' },
    props: { type: 'string' },
    max: { type: 'string', default: '3' },
    pad: { type: 'string', default: '8' },
    out: { type: 'string', default: join(tmpdir(), 'measure-ui') },
    'no-shot': { type: 'boolean', default: false },
    help: { type: 'boolean', short: 'h', default: false },
  },
})

if (opts.help || positionals.length < 2) {
  console.error(USAGE)
  process.exit(opts.help ? 0 : 2)
}

const [target, ...selectors] = positionals
const url = existsSync(target) ? pathToFileURL(resolve(target)).href : target
const themes = opts.theme === 'both' ? ['light', 'dark'] : [opts.theme]
const viewports = opts.viewport.split(',').map((v) => {
  const [width, height] = v.split('x').map(Number)
  if (!width || !height) fail(`bad viewport: ${v}`)
  return { width, height }
})
const props = opts.props ? opts.props.split(',').map((p) => p.trim()) : DEFAULT_PROPS
const max = Number(opts.max)
const pad = Number(opts.pad)

function fail(message) {
  console.error(message)
  process.exit(2)
}

// The script lives outside any project, so resolve Playwright from the caller's tree first
// to match the browser build that project already installed.
function loadChromium() {
  const fromCwd = createRequire(join(process.cwd(), 'noop.js'))
  for (const id of ['@playwright/test', 'playwright', 'playwright-core']) {
    try {
      return fromCwd(id).chromium
    } catch {}
  }
  try {
    const globalRoot = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim()
    const fromCli = createRequire(join(globalRoot, '@playwright/cli/noop.js'))
    return fromCli('playwright-core').chromium
  } catch {}
  fail('Playwright not found: run from a project with @playwright/test installed, or npm i -g @playwright/cli')
}

function slug(text) {
  return text.replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '').slice(0, 40) || 'el'
}

function measure(el, { props, explicit }) {
  const BORING = new Set(['', 'none', 'normal', 'auto', '0px', 'rgba(0, 0, 0, 0)'])
  const COLOR_FN = /\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\([^()]*\)/g
  const ctx = document.createElement('canvas').getContext('2d', { willReadFrequently: true })
  const rgba = (c) => {
    ctx.clearRect(0, 0, 1, 1)
    ctx.fillStyle = '#000'
    ctx.fillStyle = c
    ctx.fillRect(0, 0, 1, 1)
    const d = ctx.getImageData(0, 0, 1, 1).data
    return [d[0], d[1], d[2], d[3] / 255]
  }
  const hex = ([r, g, b, a]) =>
    '#' + [r, g, b].map((v) => Math.round(v).toString(16).padStart(2, '0')).join('') +
    (a < 1 ? Math.round(a * 255).toString(16).padStart(2, '0') : '')
  const over = (top, bottom) => [0, 1, 2].map((i) => top[i] * top[3] + bottom[i] * (1 - top[3])).concat(1)
  const luminance = (c) => {
    const [r, g, b] = c.slice(0, 3).map((v) => {
      v /= 255
      return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4
    })
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
  }

  const cs = getComputedStyle(el)
  const unset = (p, v) =>
    BORING.has(v) ||
    (p === 'opacity' && v === '1') ||
    (p === 'outline' && cs.outlineStyle === 'none') ||
    (p === 'border-color' && cs.borderStyle === 'none')
  const styles = {}
  for (const p of props) {
    const v = cs.getPropertyValue(p).trim()
    if (!explicit && unset(p, v)) continue
    styles[p] = v.replace(COLOR_FN, (m) => hex(rgba(m)))
  }

  const layers = []
  let bgImage = false
  for (let n = el; n; n = n.parentElement) {
    const s = getComputedStyle(n)
    if (s.backgroundImage !== 'none') bgImage = true
    const c = rgba(s.backgroundColor)
    if (c[3] > 0) layers.push(c)
    if (c[3] >= 1) break
  }
  // Chromium paints an unstyled dark-scheme canvas #121212, not white.
  const darkCanvas = matchMedia('(prefers-color-scheme: dark)').matches &&
    getComputedStyle(document.documentElement).colorScheme.includes('dark')
  let bg = layers.at(-1)?.[3] >= 1 ? layers.pop() : darkCanvas ? [18, 18, 18, 1] : [255, 255, 255, 1]
  for (const c of layers.reverse()) bg = over(c, bg)
  const fg = over(rgba(cs.color), bg)
  const [hi, lo] = [luminance(fg), luminance(bg)].sort((a, b) => b - a)

  const r = el.getBoundingClientRect()
  const round = (v) => Math.round(v * 100) / 100
  return {
    text: (el.innerText || el.getAttribute('aria-label') || '').trim().replace(/\s+/g, ' ').slice(0, 40),
    rect: { x: round(r.x), y: round(r.y), w: round(r.width), h: round(r.height) },
    styles,
    contrast: {
      fg: hex(fg),
      bg: hex(bg),
      ratio: round((hi + 0.05) / (lo + 0.05)),
      ...(bgImage && { bgImage: true }),
    },
  }
}

const chromium = loadChromium()
if (!opts['no-shot']) mkdirSync(opts.out, { recursive: true })

// A Playwright newer than the downloaded browser builds can still drive the installed Chrome.
async function launch() {
  try {
    return await chromium.launch()
  } catch (e) {
    if (!/Executable doesn't exist/.test(e.message)) throw e
    return chromium.launch({ channel: 'chrome' })
  }
}

let missing = false
const browser = await launch()
try {
  for (const viewport of viewports) {
    for (const theme of themes) {
      const context = await browser.newContext({
        viewport,
        deviceScaleFactor: Number(opts.dpr),
        colorScheme: theme,
        ...(opts.state && { storageState: opts.state }),
      })
      if (opts.init) await context.addInitScript(opts.init)
      const page = await context.newPage()
      const errors = []
      page.on('pageerror', (e) => errors.push(e.message))
      page.on('console', (m) => m.type() === 'error' && errors.push(m.text()))

      await page.goto(url, { waitUntil: 'load' })
      await page.locator(opts.wait ?? selectors[0]).first().waitFor({ state: 'visible', timeout: 15000 }).catch(() => {})
      await page.evaluate(() => document.fonts.ready)
      if (Number(opts.settle)) await page.waitForTimeout(Number(opts.settle))
      if (opts.hover) await page.hover(opts.hover)
      if (opts.focus) await page.focus(opts.focus)

      const run = `${viewport.width}x${viewport.height} ${theme}`
      console.log(JSON.stringify({ run, url: page.url(), ...(errors.length && { errors: errors.slice(0, 5) }) }))
      for (const selector of selectors) {
        const locator = page.locator(selector)
        const count = await locator.count()
        if (!count) missing = true
        for (let i = 0; i < Math.min(count, max); i++) {
          const el = locator.nth(i)
          await el.scrollIntoViewIfNeeded().catch(() => {})
          const m = await el.evaluate(measure, { props, explicit: Boolean(opts.props) })
          let shot
          if (!opts['no-shot'] && m.rect.w > 0 && m.rect.h > 0) {
            const x = Math.max(0, m.rect.x - pad)
            const y = Math.max(0, m.rect.y - pad)
            const clip = {
              x,
              y,
              width: Math.min(viewport.width - x, m.rect.x + m.rect.w + pad - x),
              height: Math.min(viewport.height - y, m.rect.y + m.rect.h + pad - y),
            }
            if (clip.width > 0 && clip.height > 0) {
              shot = join(opts.out, `${slug(selector)}-${viewport.width}-${theme}-${i}.png`)
              await page.screenshot({ path: shot, clip })
            }
          }
          console.log(JSON.stringify({ run, selector, match: `${i + 1}/${count}`, ...m, ...(shot && { shot }) }))
        }
        if (!count) console.log(JSON.stringify({ run, selector, match: '0/0' }))
      }
      await context.close()
    }
  }
} finally {
  await browser.close()
}
process.exit(missing ? 1 : 0)
