# Kamare (kamare.koplugin)

**kamare** is a manga reader plugin for [KOReader](https://github.com/koreader/koreader) that 
connects to [Kavita](https://github.com/Kareadita/Kavita).

This KOReader plugin provides a seamless way to read manga from Kavita without going through OPDS, 
featuring a custom renderer that also supports long-strip formats commonly used in manhwa.

## Features

- **Direct Kavita Integration** - Browse your library without OPDS limitations
- **Multiple Reading Modes** - Page, scroll (long-strip), and dual-page modes
- **Smart Prefetching** - Fast page turns through caching
- **Progress Tracking** - Syncs with Kavita and KOReader reading stats
- **Optimized Renderer** - Custom-built for fluid manga reading experience
- **Offline Cache** - Download whole chapters, read them with no connection, sync progress on reconnect

Tested with Kindle Paperwhite (2nd gen) and Kobo Libra Colour.

## What's new in 0.10

0.10 was built in two passes: the cache itself first, then the public API another
plugin can drive.

### Pass 1 — offline cache (Kamare on its own)

- **Whole-chapter downloads.** One request per chapter
  (`/api/Download/chapter`), resumable with HTTP Range, three attempts with
  2/8/20 s backoff. A 403, a multi-file chapter, a non-archive response or a
  page-order mismatch falls back to fetching page by page.
- **Archive extraction that matches Kavita.** Entry order replicates Kavita's
  flatten + natural sort, so page N locally is page N on the server; the page
  list is validated against `file-dimensions` before the archive is accepted.
- **One serial download queue** for the whole plugin: live progress, pause /
  resume / retry, Wi-Fi-only by default, a low-space precheck that pauses
  instead of failing, persisted across restarts and never started automatically.
- **Offline shelf.** Opening the plugin without a connection goes straight to
  the cached series list. Uncached chapters are shown but disabled, and a
  cached chapter opens from disk with zero image requests.
- **Offline reading journal.** Positions are kept in
  `settings/kamare-journal.json` (never deleted with the cache), debounced to
  disk, and pushed back monotonically on reconnect — a position is only pushed
  when it is ahead of the server's.
- **Cache management**: usage, sorting, delete read chapters, update outdated
  chapters, clear per server or everything, optional size cap, and “cache only
  unread chapters” from the series menu.
- **Stable cache identity**: `serverKey` survives URL/name edits and API-key
  rotation, so downloads are not orphaned by a settings change.
- **Simulated offline** switch on devices without a Wi-Fi toggle (marked debug
  in the menu), so the offline paths can be exercised on a desktop emulator.

### Pass 2 — public cache API for Moon

- **Versioned facade**: `require("kamarecache")` exposes `API_VERSION = 1` plus
  a `capabilities` table (`status`, `summary`, `enqueue`, `delete`, `server`,
  `resume`, `queue`, `queue_control`, `index`, `open`, `estimate`, `chapters`,
  `delete_all`). New capabilities are additive; only a breaking change bumps
  the major version.
- **Safe probing**: callers use `pcall(require, "kamarecache")`; a missing
  module, another major version, or a missing capability degrades silently
  instead of raising, and one absent capability only disables that feature.
- **Stable failures**: `nil, code, message` with snake_case codes
  (`unknown_server`, `offline_not_cached`, `viewer_running`, `chapter_open`,
  `not_enough_space`, …). Read-only calls never create a server key and never
  flush settings.
- **Cleanup plan limits**: `chapters()` judges "read" from the journal plus the
  download-time snapshot (old chapters can lose their journal entry), reports
  per-chapter byte estimates, and a `.part` without an index entry is only
  visible to `delete_all()`. Open-chapter protection covers this process only.
- **One writer per process**: Kamare publishes its settings/client at startup
  and adopts any store/journal/queue a caller built first, so there is never a
  second queue writing the same cache.
- **Server mirroring and viewer hand-off**: `register_server` mirrors another
  plugin's base URL + API key; `open` decides cache-first vs. stream, offline
  refusal, and the start page, and it owns the viewer lifecycle. The `on_next`
  hook fires after the viewer has closed, so a caller may open the next chapter
  directly from it.
- **Documented deviations**: `open` builds the read (journal) tier even when
  `start_page` is explicit, so the offline session is not lost;
  `queue_pause` on an empty queue returns `true` and the state honestly stays
  `idle`.

## Screenshots

<table>
<tr>
<td align="center" valign="top">
<img src="doc/main-screen.png" alt="Library home">
<br><b>Library Home</b>
<br>Browse by On Deck, Recently Updated, and Want to Read
</td>
<td align="center" valign="top">
<img src="doc/series-screen.png" alt="Chapter list">
<br><b>Chapter List</b>
<br>View all chapters with progress tracking
</td>
</tr>
</table>

## Reading Modes

<table>
<tr>
<td align="center" valign="top">
<img src="doc/page-mode.png" alt="Page mode">
<br><b>Page Mode</b>
<br>Classic single-page view
</td>
<td align="center" valign="top">
<img src="doc/scroll-mode.png" alt="Scroll mode">
<br><b>Scroll Mode</b>
<br>For webtoons and long-strip formats
</td>
<td align="center" valign="top">
<img src="doc/dual-page-mode.png" alt="Dual page mode">
<br><b>Dual Page Mode</b>
<br>More Book like horizontally or on wider screens
</td>
</tr>
</table>

## Installation & Setup

1. Download the latest `kamare.koplugin.zip` from the [releases page](https://github.com/fpammer/kamare.koplugin/releases/latest).
2. Extract the ZIP and copy the `kamare.koplugin` folder into the `plugins` directory of your KOReader installation.
3. Restart KOReader to load the plugin.
4. Open the plugin from the KOReader menu (🔍) and add your Kavita server from the burger menu (top-left).:
<p align="center">
<img src="doc/server-setup.png" width="500" alt="Server setup">
</p>
5. Enter a server name, URL (with protocol eg. https://kavita.hostname.zone), and Kavita API key

### Getting Your Kavita API Key

1. Log into your Kavita web interface
2. Go to **Settings** → **Account** → **API Key**
3. Generate a new key if needed and type it to the setup dialog

## Offline cache

Kamare can download whole Kavita chapters (one cbz per chapter), read them
without a network connection, and push the reading position back to Kavita on
reconnect. The cache lives under `kamare/cache/<serverKey>/` in the KOReader
data directory; reading progress stays in `settings/kamare-journal.json` and is
never deleted together with cached pages.

- Cache entries: long-press a chapter/volume in the series page, or use the
  top-left menu for whole-series downloads (whole series, unread only, from the
  current chapter on, or the next N volumes).
- Manage storage: top-left menu → **Cached chapters** (usage, sorting, delete
  read chapters, update outdated chapters, clear cache, optional size limit).
- Offline: opening the plugin without a connection goes straight to the cached
  shelf. Uncached chapters are shown but disabled.
- Reconnect: pending positions are pushed once (monotonic rule: a position is
  only pushed when it is ahead of the server's). Offline reading time stays
  local; Kavita sessions still get one normal 1-page activity per push, so
  Kavita's offline page counts stay low by design.

### Cache API for other plugins

The cache is also a versioned API, so another plugin (Moon's Kavita source is
the intended consumer) can download, inspect and open cached chapters without
re-implementing any of it. See [What's new in 0.10](#pass-2--public-cache-api-for-moon)
for the capability list and error-code contract.

Releases inject the plugin version into `kamareversion.lua`; a plain checkout
reports `0.10.0-dev`. The cache API version is independent of the plugin
version (`API_VERSION = 1`, plugin 0.10.x).

## Development

```sh
./spec/run.sh            # all specs
./spec/run.sh queue      # one file (substring match)
```

The runner boots a KOReader emulator LuaJIT runtime (`v2026.07.2-207`) with the
real `rapidjson`, `libarchive` and `lfs` modules. It needs no network: the only
socket traffic is a loopback fixture. If the default runtime path does not
exist, point `KOREADER_DIR` at a KOReader tree that contains `luajit` and
`common/`:

```sh
KOREADER_DIR=/path/to/koreader ./spec/run.sh
```

## Configuration

Access settings while reading by tapping the screen. Customize your experience:

- **View Modes**: Switch between scroll, page, and dual-page modes
- **Page Direction**: LTR or RTL
- **Prefetching**: Prefetch next pages for smooth reading
- **Render Quality**: Balance between quality and speed (also helps with older devices, or crazy files)

Settings are remembered **per series**: once you change something while reading a
series, opening any chapter of it again restores that configuration. Series you
never customized keep following the global defaults. Per-series values are
stored in `settings/kamare_books.lua` (delete an entry, or the whole file, to
fall back to the global defaults).

<details>
<summary><b>View all settings</b></summary>

<table>
<tr>
<td align="center" valign="top">
<img src="doc/settings-general.png" alt="General settings">
<br><b>General</b>
</td>
<td align="center" valign="top">
<img src="doc/settings-page.png" alt="Page settings">
<br><b>Page</b>
</td>
<td align="center" valign="top">
<img src="doc/settings-zoom.png" alt="Zoom settings">
<br><b>Zoom</b>
</td>
</tr>
</table>

</details>
