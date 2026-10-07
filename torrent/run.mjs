// Hardened WebTorrent runner. The real kill switch is the tunnel container's firewall. This
// file only (1) refuses to start unless traffic provably exits via WARP and (2) tears down if
// that stops being true. It also turns off every feature that talks to the LAN or router, and
// serves an HTTP stream (for VLC etc.) that the tunnel container publishes on the host's
// 127.0.0.1 only.
import WebTorrent from 'webtorrent'

const TORRENT_ID = process.env.TORRENT_ID
const STREAM = process.env.STREAM === '1'
const STREAM_PORT = Number(process.env.STREAM_PORT || 8888)
// Host and container ports are the same, so this is also the URL that works on the host.
const STREAM_HOST = '127.0.0.1'
const TRACE_URL = 'https://www.cloudflare.com/cdn-cgi/trace'
const CHECK_EVERY_MS = 30_000
const MAX_FAILED_CHECKS = 2

if (!TORRENT_ID) {
  console.error('TORRENT_ID is required (magnet link, .torrent URL or infohash)')
  process.exit(2)
}

async function trace () {
  const res = await fetch(TRACE_URL, { signal: AbortSignal.timeout(10_000) })
  return Object.fromEntries((await res.text()).trim().split('\n').map(l => l.split('=')))
}

async function assertWarp () {
  const t = await trace()
  if (t.warp !== 'on' && t.warp !== 'plus') throw new Error(`egress is not WARP (warp=${t.warp}, ip=${t.ip})`)
  return t
}

const t = await assertWarp().catch(err => {
  console.error(`[guard] refusing to start: ${err.message}`)
  process.exit(1)
})
console.log(`[guard] egress ok: ip=${t.ip} colo=${t.colo} warp=${t.warp}`)

const client = new WebTorrent({
  natUpnp: false,          // never ask the router to open ports
  natPmp: false,
  lsd: false,              // no BEP14 multicast on the local network
  utp: false,              // native uTP isn't built (--ignore-scripts); be explicit
  tracker: { wrtc: false } // no WebRTC: ICE host candidates would leak container/LAN IPs
})

// Stream server. `hostname` rejects requests whose Host header isn't 127.0.0.1:<port> (blocks
// DNS-rebinding from web pages). `origin` is set to the server's own origin so other websites
// open in your browser can't read it via CORS. (Don't pass `origin: false`: webtorrent 3.0.21
// treats any falsy value as '*', i.e. allow all origins.) Media players send no Origin header.
if (STREAM) {
  client.createServer({ hostname: STREAM_HOST, origin: `http://${STREAM_HOST}:${STREAM_PORT}` })
    .listen(STREAM_PORT, '0.0.0.0')
}

let failed = 0
const guard = setInterval(async () => {
  try {
    await assertWarp()
    failed = 0
  } catch (err) {
    failed++
    console.error(`[guard] check ${failed}/${MAX_FAILED_CHECKS} failed: ${err.message}`)
    if (failed >= MAX_FAILED_CHECKS) shutdown(1, 'WARP egress lost')
  }
}, CHECK_EVERY_MS)

let shuttingDown = false
function shutdown (code, why) {
  if (shuttingDown) return
  shuttingDown = true
  console.log(`[guard] shutting down: ${why}`)
  clearInterval(guard)
  client.destroy(() => process.exit(code))
  setTimeout(() => process.exit(code), 5_000).unref()
}
process.on('SIGTERM', () => shutdown(0, 'SIGTERM'))
process.on('SIGINT', () => shutdown(0, 'SIGINT'))
client.on('error', err => shutdown(1, `client error: ${err.message}`))

function printStreamURLs (torrent) {
  const base = `http://${STREAM_HOST}:${STREAM_PORT}`
  const files = [...torrent.files].sort((a, b) => b.length - a.length)
  console.log('[stream] open in VLC (Media → Open Network Stream) or any player:')
  console.log(`[stream] ▶ ${base}${files[0].streamURL}`)
  for (const f of files.slice(1)) console.log(`[stream]   ${base}${f.streamURL}  (${f.name}, ${(f.length / 1e6).toFixed(1)} MB)`)
}

client.add(TORRENT_ID, { path: '/downloads' }, torrent => {
  console.log(`[torrent] ${torrent.name} (${(torrent.length / 1e6).toFixed(1)} MB, ${torrent.files.length} files)`)
  if (STREAM) printStreamURLs(torrent)
  const progress = setInterval(() => {
    console.log(`[torrent] ${(torrent.progress * 100).toFixed(1)}%  ↓${(torrent.downloadSpeed / 1e6).toFixed(2)} MB/s  ↑${(torrent.uploadSpeed / 1e6).toFixed(2)} MB/s  peers=${torrent.numPeers}`)
  }, 5_000)
  torrent.on('done', () => {
    clearInterval(progress)
    console.log(`[torrent] done → /downloads/${torrent.name}`)
    if (!STREAM) shutdown(0, 'download complete')
    else console.log('[torrent] download complete; still streaming and seeding — press Ctrl-C to stop')
  })
})
