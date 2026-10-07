// uTP is deliberately disabled (no native build for linux/musl/arm64 + Node 24).
// An empty export makes WebTorrent report UTP_SUPPORT = false without logging a stack trace.
module.exports = {}
