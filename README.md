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

Tested with Kindle Paperwhite (2nd gen) and Kobo Libra Colour.

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
  top-left menu for whole-series downloads.
- Manage storage: top-left menu → **Cached chapters** (usage, sorting, delete
  read chapters, update outdated chapters, clear cache, optional size limit).
- Offline: opening the plugin without a connection goes straight to the cached
  shelf. Uncached chapters are shown but disabled.
- Reconnect: pending positions are pushed once (monotonic rule: a position is
  only pushed when it is ahead of the server's). Offline reading time stays
  local; Kavita sessions still get one normal 1-page activity per push, so
  Kavita's offline page counts stay low by design.

Releases inject the plugin version into `kamareversion.lua`; checkouts report
`0.10.0-dev`. The cache module (`kamarecache`) is versioned independently:
`API_VERSION = 1` with a `capabilities` table, so other plugins can probe it
with `pcall(require, "kamarecache")` and degrade silently when it is absent.

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
