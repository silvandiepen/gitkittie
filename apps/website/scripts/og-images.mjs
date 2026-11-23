#!/usr/bin/env node
/**
 * Makes the share cards in public/og/ — the picture a shared link shows.
 *
 *   npm run og                    every page and article
 *   npm run og -- /blog/a-post    only the paths given
 *
 * Starts Vite on og.html, opens it in headless Chrome over the DevTools protocol, and
 * saves each card at 1200 × 630. The cards are committed: the build only checks that every
 * route has one (build/static-pages.ts), it does not run Chrome.
 *
 * Chrome is found at the usual macOS path; set CHROME to use another.
 */
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createServer } from 'vite'

const root = fileURLToPath(new URL('..', import.meta.url))
const chromePath = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const only = process.argv.slice(2)
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

const server = await createServer({ root, logLevel: 'warn', server: { host: '127.0.0.1', port: 0, strictPort: false } })
await server.listen()
const base = server.resolvedUrls.local[0].replace(/\/$/, '')

const port = 9300 + Math.floor(Math.random() * 500)
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'gitkittie-og-'))
const chrome = spawn(chromePath, ['--headless=new', '--hide-scrollbars', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, 'about:blank'], { stdio: 'ignore' })

try {
  let targets
  for (let attempt = 0; attempt < 75 && !targets; attempt++) {
    try { targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json() } catch { await wait(200) }
  }
  if (!targets) throw new Error(`Chrome did not start at ${chromePath}`)

  const socket = new WebSocket(targets.find((target) => target.type === 'page').webSocketDebuggerUrl)
  await new Promise((resolve) => socket.addEventListener('open', resolve))
  let nextId = 0
  const pending = new Map()
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data)
    if (message.id && pending.has(message.id)) { pending.get(message.id)(message); pending.delete(message.id) }
  })
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++nextId
    pending.set(id, (message) => (message.error ? reject(new Error(`${method}: ${message.error.message}`)) : resolve(message.result)))
    socket.send(JSON.stringify({ id, method, params }))
  })
  const evaluate = async (expression) => {
    const { result, exceptionDetails } = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })
    if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text)
    return result.value
  }
  const open = async (url) => {
    await send('Page.navigate', { url })
    // The entry sets its promises on load; wait for them to exist, then for the card.
    for (let attempt = 0; attempt < 100; attempt++) {
      if (await evaluate('typeof window.__shareCardReady !== "undefined"')) break
      await wait(100)
    }
    await evaluate('window.__shareCardReady')
  }

  await send('Page.enable')
  await send('Emulation.setDeviceMetricsOverride', { width: 1200, height: 630, deviceScaleFactor: 1, mobile: false })

  await open(`${base}/og.html`)
  const cards = (await evaluate('window.__shareCards')).filter((card) => !only.length || only.includes(card.path))
  if (only.length && cards.length !== only.length) throw new Error(`Unknown path in ${only.join(', ')}`)

  for (const card of cards) {
    await open(`${base}/og.html?path=${encodeURIComponent(card.path)}`)
    const { data } = await send('Page.captureScreenshot', { format: 'png', clip: { x: 0, y: 0, width: 1200, height: 630, scale: 1 } })
    const file = path.join(root, 'public', card.file)
    fs.mkdirSync(path.dirname(file), { recursive: true })
    fs.writeFileSync(file, Buffer.from(data, 'base64'))
    console.log(`${card.path} → public${card.file}`)
  }
  socket.close()
} finally {
  chrome.kill()
  await server.close()
  fs.rmSync(profile, { recursive: true, force: true })
}
