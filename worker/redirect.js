/**
 * Short URL for the toolkit launchers.
 *
 *   https://ops.omfgnickss.workers.dev      -> Menu.ps1  (PowerShell)
 *   https://ops.omfgnickss.workers.dev/sh   -> menu.sh   (Bash)
 *   https://ops.omfgnickss.workers.dev/install -> install.sh
 *
 * It serves the file's contents rather than issuing a redirect: `irm` and
 * `curl -L` both follow redirects, but proxying keeps the response type under
 * our control and survives clients that do not follow them.
 *
 * The code itself stays on GitHub — this is only a shortener, so what runs is
 * always the versioned, auditable file.
 */
const RAW = 'https://raw.githubusercontent.com/omfgnick/ops-toolkit/main'

const FILES = {
  '/': 'Menu.ps1',
  '/ps': 'Menu.ps1',
  '/sh': 'menu.sh',
  '/bash': 'menu.sh',
  '/install': 'install.sh',
}

const HELP = `ops-toolkit — https://github.com/omfgnick/ops-toolkit

  PowerShell:  & ([scriptblock]::Create((irm "https://ops.omfgnickss.workers.dev")))
  Bash:        curl -fsSL https://ops.omfgnickss.workers.dev/sh | bash
  Installer:   curl -fsSL https://ops.omfgnickss.workers.dev/install | bash

Paths: /  /ps  /sh  /bash  /install
`

export default {
  async fetch(request) {
    const url = new URL(request.url)
    const file = FILES[url.pathname.replace(/\/+$/, '') || '/']

    if (!file) {
      return new Response(HELP, {
        status: 404,
        headers: { 'Content-Type': 'text/plain; charset=utf-8' },
      })
    }

    const upstream = await fetch(`${RAW}/${file}`, {
      // Short cache: keeps this fast without holding a stale launcher for long.
      cf: { cacheTtl: 300, cacheEverything: true },
    })

    if (!upstream.ok) {
      return new Response(`Could not fetch ${file} from GitHub (${upstream.status}).\n`, {
        status: 502,
        headers: { 'Content-Type': 'text/plain; charset=utf-8' },
      })
    }

    return new Response(upstream.body, {
      headers: {
        // text/plain so a browser shows the source instead of downloading it —
        // anyone piping this into a shell should be able to read it first.
        'Content-Type': 'text/plain; charset=utf-8',
        'Cache-Control': 'public, max-age=300',
        'X-Source': `${RAW}/${file}`,
      },
    })
  },
}
