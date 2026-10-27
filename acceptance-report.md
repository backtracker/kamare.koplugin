# Acceptance report — Kamare offline cache

Design: `spec.md` + `issues/01`–`09` (scratch copies at `/tmp/opencode/kamare-offline/spec/`).
Integration branch: `feat/kavita-offline-cache`, plugin version `0.10.0`, cache API `1`.

## How to run the automated part

```sh
./spec/run.sh            # all specs
./spec/run.sh store      # one file (substring match)
```

The runner boots the KOReader emulator LuaJIT runtime (`v2026.07.2-207`) with the real
`rapidjson`, `libarchive` and `lfs` modules. It uses no external network; the only socket
traffic is a loopback HTTP fixture (`spec/fixtures/range_server.py`) used by the file-sink
tests. Last run: **297 assertions passed, 0 failed**.

There is no Kavita API key on this machine, so anything that requires a real server is
listed as manual below.

## Automated coverage

| ID | Coverage | Where |
| --- | --- | --- |
| A1 | Full archive download to a file, byte count == Content-Length | `spec/asyncfetch_spec.lua` (loopback file) |
| A2 | Range resume appends the exact remaining bytes | `spec/asyncfetch_spec.lua` |
| A4 | Page order for flat + nested archives, duplicate basenames, 126-dir style tree; validation against a fileName list | `spec/archive_spec.lua` |
| A5 | Extracted page bytes equal the source bytes (byte-for-byte) | `spec/archive_spec.lua` |
| A6 | File sink never accumulates the body (returns `body == nil`, writes incrementally); chunked bodies stream to disk | `spec/asyncfetch_spec.lua` |
| A8 | `pagesBytes` is the real extracted size; usage accounting sums pages + meta + cover + `.part` | `spec/archive_spec.lua`, `spec/store_spec.lua` |
| A9 | No `meta.json` when extraction/validation fails or is interrupted | `spec/queue_spec.lua` (failures), store contract tests |
| A10 | Page-order mismatch falls back to per-page (`source = "per-page"`) | `spec/queue_spec.lua` |
| A11 | Multi-file chapters skip the archive and use per-page | `spec/queue_spec.lua` |
| A12 | HTTP 403 falls back to per-page | queue fallback branch (covered by the same per-page tests; the 403 trigger itself is manual) |
| A13 | Non-archive extension uses per-page | `spec/queue_spec.lua` (`_needs_per_page`) |
| B5 | Start page: journal > snapshot > 1, clamped | `spec/cacheutil_spec.lua` |
| B6 | Snapshot fallback | `spec/cacheutil_spec.lua` |
| B11 | Missing `dims` uses the document's default page size and shows a refresh hint | viewer fallback + `spec/archive_spec.lua` (meta shape) |
| C2 | PageNum semantics unchanged (`physical-1`, last page `physical`) | viewer code path unchanged; journal stores the POSTed value (`spec/journal_spec.lua`) |
| C3 | Local behind remote → superseded, no POST | `spec/journal_spec.lua` |
| C4 | Local ahead → exact PageNum pushed | `spec/journal_spec.lua` |
| C6 | Journal disk debounce 20 s, 20-page forced flush | `spec/journal_spec.lua` |
| C8 | Corrupt journal renamed and rebuilt | `spec/journal_spec.lua` |
| C9 | 300/90-day limits, pending never evicted, pushed 7-day retention | `spec/journal_spec.lua` |
| C10 | Cache deleted → pending position still syncs (journal self-contained) | `spec/journal_spec.lua` |
| C12 | `/get-progress` failure skips the entry, never blind-pushes | `spec/journal_spec.lua` |
| D1 | Chapter/series/server/all deletion clears pages, `.part` and index entries | `spec/store_spec.lua`, `spec/cache_api_spec.lua` |
| D4 | Low-space precheck pauses instead of failing; enqueue rejects short batches | `spec/queue_spec.lua` |
| D6 | Delete-read union (journal, server pagesRead, snapshot) | `spec/cacheutil_spec.lua` |
| D9 | Clearing cache keeps the journal and pending sync works afterwards | `spec/journal_spec.lua` |
| D12 | Usage = pages + cover + `.part`, matches real disk sizes | `spec/store_spec.lua` |
| E2 | Online reading never writes page files (no write path exists outside the queue) | structural: only `kamarecachequeue` writes cache files |
| E4 | 2 s progress debounce unchanged | viewer code path unchanged; no spec can load the viewer headlessly |
| F3 | `API_VERSION` is a single integer; callers gate on major version | `spec/cache_api_spec.lua` |
| F5 | One queue: duplicate chapter enqueue is rejected | `spec/queue_spec.lua` |
| G2 | HTML/non-zip archive → no meta, falls back or fails | `spec/archive_spec.lua`, `spec/queue_spec.lua` |
| G4 | Queue persisted; `.part` resumes; extraction restarts from a clean page dir | `spec/queue_spec.lua`, `spec/archive_spec.lua` |

## Manual / device-only checks remaining

These need a real Kavita `0.9.1.4` server and/or real e-ink hardware, and were not run here
because no credentials are configured on this machine:

- A3 (630 MB chapter reset + retry), A6 measured RSS on device, A12 real 403 key.
- B1 (offline entry never opens the Wi-Fi dialog), B2/B3/B4 (shelf contents, greyed rows,
  zero-request open), B7 (dual page / crop offline), B8/B9 (offline next chapter), B10 empty
  state, B12 row text on device.
- C1/C5/C7/C11 (real reconnect activity, 1-page session residue, kill -9 window, trigger points).
- D2/D3 (row disabled while open; the white-page counter-example), D5 (full-series prompt),
  D7 (orphan group after deleting a server), D8 (warning text), D10/D11 (real fingerprint
  change and replacement peak disk).
- E1/E3 (packet-level zero image requests), E5/E6 (yield while a page request is in flight),
  E7 (traffic accounting).
- F1/F2/F4/F6 (official Kamare / old fork / interface self-check / Moon-side coexistence).
- G1/G3/G5 (real network drop, disk full, server version change).

## Known deviations accepted by the design

1. Reconnecting always creates one normal 1-page Kavita activity; offline page counts stay
   low. The shelf says “not counted by Kavita”.
2. Offline reading time is never pushed; only local sessions record it.
3. Partially downloaded archives are unreadable; progress is shown in MB.
4. Offline staleness cannot be detected; stale marks only appear while online.
5. The chapter currently open in the viewer cannot be deleted (its failed pages are terminal).
6. Reading a cached chapter while online fetches no images but still posts progress, by design.
