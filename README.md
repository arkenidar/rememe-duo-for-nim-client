# rememe-duo-for-nim-client

A native **Nim** client for the [rememe-duo](../rememe-duo) PHP server, built on
**[nim-gfx](../nim-gfx)** (SDL2 + Cairo + Pango).

It replaces the browser frontend (HTML/CSS/JS/Alpine/fetch) with a desktop
window:

| Browser frontend         | Nim client                              |
|--------------------------|-----------------------------------------|
| `fetch()`                | `std/httpclient` GET calls              |
| Alpine.js reactive view  | immediate-mode UI (draw + hit-test each frame) |
| `index.php` templates    | `src/ui.nim` screens (name → lobby → game) |
| `script.js` state logic  | `src/api.nim` state mirror + actions    |

The client keeps a local mirror of the room file and redraws every frame,
polling `api.php?action=state` every `poll_ms` (600 ms) — the same heartbeat as
the web client. Card faces are drawn as tinted vector symbols (a deterministic
function of the server's emoji), so no emoji font is required and both players
see the same board.

## Run it

```sh
# 1. start the server (in rememe-duo/)
cd ../rememe-duo
php -S 0.0.0.0:8000

# 2. start the client (in rememe-duo-for-nim-client/)
nim c -d:ssl -r src/rememe_duo_client.nim
```

`-d:ssl` links OpenSSL so the remote `https://` preset works (local `http://`
works either way).

## Choosing the server

On the **name screen**, use the `<` / `>` buttons (or the **Left/Right** arrow
keys) to cycle between presets, shown as `[label] URL`:

| Preset | Endpoint |
|---|---|
| `local`  | `http://127.0.0.1:8000/api.php` |
| `remote` | `https://github.arkenidar.com/rememe-duo/api.php` |

You can also pass any URL on the command line — a root or a full `api.php` URL
both work, and `--server=local` / `--server=remote` select a preset by name:

```sh
nim c -d:ssl -r src/rememe_duo_client.nim -- --server=remote
nim c -d:ssl -r src/rememe_duo_client.nim -- --server=http://192.168.1.20:8000/
nim c -d:ssl -r src/rememe_duo_client.nim -- --server=https://github.arkenidar.com/rememe-duo/api.php
```

(`--` passes the flag through to the built program.)

## Controls

| Action | Input |
|---|---|
| Type into a field | click/tap it, then type |
| Backspace / submit | `Backspace` / `Enter` (in the focused field) |
| Click/tap a card | mouse left click or touch |
| Back to lobby (in game) | `Esc` or the `lobby` button |
| Scroll chat | mouse wheel |
| Cycle server (name screen) | `<` / `>` buttons or `Left` / `Right` arrows |
| Quit | close the window (✕) |

## Project layout

```
src/
  rememe_duo_client.nim  # entry: window, input, polling, main loop
  api.nim                # HTTP + JSON + the room "mirror" (mirrors script.js)
  ui.nim                 # immediate-mode widgets + screens + card symbols
config.nims              # --path to ../nim-gfx/src
rememe-duo-for-nim-client.nimble
```

The only code dependency is the sibling [nim-gfx](../nim-gfx) — clone it next to
this repo. `config.nims` points at `../nim-gfx/src`, so `import gfx` resolves
without installing anything.

## Honest simplifications

- HTTP calls are **synchronous** in the main loop (like the web client's
  polling); a localhost request is fast, but the window briefly blocks during
  one. A background-thread / `asyncdispatch` variant is future work.
- Chat messages render as a single line each (clipped, not wrapped).
- No clipboard paste yet (on nim-gfx's roadmap).
