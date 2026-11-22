# api.nim — HTTP client + state mirror for the rememe-duo PHP server.
#
# Mirrors rememe-duo's script.js: we fetch the server, keep a local mirror of
# the room, and the UI redraws from it every frame ("data in, view out").
#
# The room JSON is kept as a JsonNode with tiny accessor helpers, rather than
# mapped to a typed object, because the server emits many nullable fields
# (p2:null, turn:null, ...) and two room shapes (lobby vs game).

import std/json
import std/httpclient
import std/uri
import std/strutils
import std/os

type
  View* = enum
    viewName, viewLobby, viewGame

# --- server selection --------------------------------------------------------

type
  ServerPreset* = object
    label*: string
    url*: string          # server root, always ends with "/"

var serverPresets* = [
  ServerPreset(label: "local",  url: "http://127.0.0.1:8000/"),
  ServerPreset(label: "remote", url: "https://github.arkenidar.com/rememe-duo/"),
]
var serverIndex* = 0
var serverRoot* = serverPresets[0].url

proc apiEndpoint*(): string =
  ## The full ".../api.php" URL the client talks to.
  serverRoot & "api.php"

proc serverLabel*(): string =
  if serverIndex >= 0 and serverIndex < serverPresets.len:
    serverPresets[serverIndex].label
  else:
    "custom"

proc setServer*(url: string) =
  ## Normalize a server address into a root (trailing "/"), accepting both a
  ## root ".../rememe-duo/" and a full ".../rememe-duo/api.php" URL.
  var u = url.strip()
  if u.len == 0: return
  while u.endsWith("/"): u.setLen(u.len - 1)
  if u.endsWith("/api.php"): u = u[0 ..< u.len - "/api.php".len]
  if u.len == 0: return
  serverRoot = u & "/"
  serverIndex = -1
  for i, p in serverPresets:
    if p.url == serverRoot:
      serverIndex = i
      break

proc cycleServer*(dir: int) =
  ## Step to the previous/next preset (wraps around). Leaving a custom URL,
  ## "<" goes to the last preset and ">" to the first.
  let n = serverPresets.len
  if n == 0: return
  if serverIndex < 0:
    serverIndex = if dir < 0: n - 1 else: 0
  else:
    serverIndex = ((serverIndex + dir) mod n + n) mod n
  serverRoot = serverPresets[serverIndex].url

# --- the state mirror (script.js's `state` + local UI fields) ----------------

var
  view* = viewName
  name* = ""
  joinCode* = ""
  draft* = ""
  token* = ""
  roomId* = ""
  you* = ""              # 'p1' | 'p2' | '' (your seat in a game, '' in the lobby)
  room*: JsonNode = nil
  openGames*: seq[JsonNode] = @[]
  errorMsg* = ""
  pollMs* = 600

# --- tiny JsonNode helpers ---------------------------------------------------

proc jget(n: JsonNode; key: string): JsonNode =
  if n != nil and n.kind == JObject and n.hasKey(key): n[key] else: nil

proc jstr(n: JsonNode; key: string): string =
  let v = jget(n, key)
  if v != nil and v.kind == JString: v.getStr() else: ""

proc jint(n: JsonNode; key: string): int =
  let v = jget(n, key)
  if v != nil: v.getInt() else: 0

proc isNull(n: JsonNode): bool =
  n == nil or n.kind == JNull

proc jarr(n: JsonNode; key: string): seq[JsonNode] =
  let v = jget(n, key)
  if v != nil and v.kind == JArray: v.getElems() else: @[]

# --- accessors over the room mirror ------------------------------------------

proc status*(): string = jstr(room, "status")
proc turn*(): string = jstr(room, "turn")
proc winner*(): string = jstr(room, "winner")

proc playerName*(slot: string): string =
  let players = jget(room, "players")
  let p = jget(players, slot)
  if p != nil: return jstr(p, "name")
  if slot == "p1": "Player 1" else: "Player 2"

proc p1Name*(): string = playerName("p1")
proc p2Name*(): string = playerName("p2")

proc score*(slot: string): int =
  jint(jget(room, "scores"), slot)

proc isActive*(slot: string): bool = status() == "playing" and turn() == slot
proc isWinner*(slot: string): bool = status() == "finished" and winner() == slot

proc statusText*(): string =
  case status()
  of "waiting": "waiting for opponent..."
  of "finished":
    if winner() == "tie": "it's a tie!"
    else: (if winner() == "p1": p1Name() else: p2Name()) & " wins!"
  else:
    "it's " & (if turn() == "p1": p1Name() else: p2Name()) & "'s turn"

proc people*(): seq[JsonNode] = jarr(room, "people")
proc messages*(): seq[JsonNode] = jarr(room, "messages")
proc cardList*(): seq[JsonNode] = jarr(room, "cards")
proc cardCount*(): int = cardList().len

proc cardAt*(i: int): JsonNode =
  let cs = cardList()
  if i >= 0 and i < cs.len: cs[i] else: nil

proc cardFlipped*(i: int): bool =
  let c = cardAt(i)
  if c != nil: c["flipped"].getBool() else: false

proc cardMatched*(i: int): bool =
  let c = cardAt(i)
  if c != nil: c["matched"].getBool() else: false

proc cardEmoji*(i: int): string =
  let c = cardAt(i)
  if c != nil: jstr(c, "emoji") else: ""

proc personName*(p: JsonNode): string = jstr(p, "name")
proc msgName*(m: JsonNode): string = jstr(m, "name")
proc msgText*(m: JsonNode): string = jstr(m, "text")
proc ogId*(g: JsonNode): string = jstr(g, "id")
proc ogP1*(g: JsonNode): string = jstr(g, "p1")

proc isDisabled*(i: int): bool =
  let c = cardAt(i)
  if c == nil: return true
  if status() != "playing": return true
  if turn() != you: return true
  if c["flipped"].getBool() or c["matched"].getBool(): return true
  if not isNull(jget(room, "mismatch")): return true
  false

# --- the HTTP call -----------------------------------------------------------

proc apiCall*(action: string; params: seq[(string, string)] = @[]): JsonNode =
  ## GET api.php?action=...&... and return the parsed JSON envelope.
  var url = apiEndpoint() & "?action=" & encodeUrl(action)
  for (k, v) in params:
    url.add("&" & encodeUrl(k) & "=" & encodeUrl(v))
  let client = newHttpClient(timeout = 5000)
  try:
    let body = client.getContent(url)
    let data = parseJson(body)
    if not data["ok"].getBool():
      let err = jget(data, "error")
      errorMsg = if err != nil: err.getStr() else: "something went wrong"
      raise newException(IOError, errorMsg)
    return data
  finally:
    client.close()

proc apply*(data: JsonNode) =
  ## Write an API envelope back into the local mirror.
  let r = jget(data, "room")
  if r != nil and r.kind == JObject:
    room = r
    roomId = jstr(r, "id")
  you = jstr(data, "you")
  let og = jget(data, "openGames")
  if og != nil and og.kind == JArray:
    openGames = og.getElems()
  errorMsg = ""

# --- actions (mirror script.js) ---------------------------------------------

proc enterLobby*() =
  try:
    let r = apiCall("lobby", @[("token", token), ("name", name.strip())])
    apply(r)
    view = viewLobby
  except CatchableError:
    errorMsg = getCurrentExceptionMsg()

proc enterName*() =
  if name.strip().len == 0: return
  try:
    let r = apiCall("hello")
    token = r["token"].getStr()
    enterLobby()
  except CatchableError:
    errorMsg = getCurrentExceptionMsg()

proc createGame*() =
  try:
    let r = apiCall("create", @[("token", token), ("name", name.strip())])
    apply(r)
    view = viewGame
  except CatchableError:
    errorMsg = getCurrentExceptionMsg()

proc joinGame*(code: string) =
  let c = code.strip().toUpperAscii()
  if c.len == 0: return
  try:
    let r = apiCall("join", @[("token", token), ("name", name.strip()), ("room", c)])
    apply(r)
    view = viewGame
  except CatchableError:
    errorMsg = getCurrentExceptionMsg()

proc backToLobby*() =
  enterLobby()

proc refresh*()
  # Forward declaration: `flip` / `sendChat` resync on error; the body is below.

proc flip*(i: int) =
  if isDisabled(i): return
  try:
    let r = apiCall("flip", @[("token", token), ("room", roomId), ("card", $i)])
    apply(r)
  except CatchableError:
    errorMsg = getCurrentExceptionMsg()
    refresh()   # someone else moved — resync

proc sendChat*() =
  let text = draft.strip()
  if text.len == 0: return
  draft = ""
  try:
    let r = apiCall("chat", @[("token", token), ("room", roomId), ("text", text)])
    apply(r)
  except CatchableError:
    errorMsg = getCurrentExceptionMsg()
    refresh()

proc refresh*() =
  if token.len == 0 or roomId.len == 0: return
  try:
    let r = apiCall("state", @[("token", token), ("room", roomId)])
    apply(r)
  except CatchableError:
    discard

# --- command-line args -------------------------------------------------------

proc parseArgs*() =
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a.startsWith("--server="):
      let v = a[9 .. ^1]
      var matched = false
      for idx, p in serverPresets:
        if v == p.label:
          serverIndex = idx
          serverRoot = p.url
          matched = true
          break
      if not matched:
        setServer(v)
