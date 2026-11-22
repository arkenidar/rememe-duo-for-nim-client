# rememe_duo_client.nim — entry point: window, input, polling, main loop.
#
# A native Nim client (nim-gfx: SDL2 + Cairo + Pango) for the rememe-duo PHP
# server. It replaces the browser frontend: std/httpclient does the fetching,
# and immediate-mode UI replaces Alpine.js.
#
# Build & run from the project root:
#   nim c -r src/rememe_duo_client.nim
# Options:
#   --server=http://host:8000/   API base URL (default http://127.0.0.1:8000/)
#   --smoke                      render one frame, then exit

import std/os
import std/options
import std/strutils

import gfx
import ui/events
import api
import ui

proc popLastRune(s: var string) =
  if s.len == 0: return
  var start = s.len - 1
  while start > 0 and (uint8(s[start]) and 0xC0'u8) == 0x80'u8:
    dec start
  s.setLen(start)

proc handleText(t: string) =
  case focus
  of focusName:
    if name.len < 20: name.add(t)
  of focusJoin:
    if joinCode.len < 8: joinCode.add(t.toUpperAscii())
  of focusChat:
    if draft.len < 200: draft.add(t)

proc handleKey(k: Key) =
  case k
  of keyBackspace:
    case focus
    of focusName: popLastRune(name)
    of focusJoin: popLastRune(joinCode)
    of focusChat: popLastRune(draft)
  of keyEnter:
    case focus
    of focusName: enterName()
    of focusJoin: joinGame(joinCode)
    of focusChat: sendChat()
  of keyEscape:
    if view == viewGame: backToLobby()
  else:
    discard

proc handleTap(x, y: float) =
  case view
  of viewName:
    if hitRect(x, y, fieldName.x, fieldName.y, fieldName.w, fieldName.h):
      focus = focusName
    elif hitRect(x, y, btnEnter.x, btnEnter.y, btnEnter.w, btnEnter.h):
      enterName()
  of viewLobby:
    if hitRect(x, y, fieldJoin.x, fieldJoin.y, fieldJoin.w, fieldJoin.h):
      focus = focusJoin
    elif hitRect(x, y, fieldChat.x, fieldChat.y, fieldChat.w, fieldChat.h):
      focus = focusChat
    elif hitRect(x, y, btnNewGame.x, btnNewGame.y, btnNewGame.w, btnNewGame.h):
      createGame()
    elif hitRect(x, y, btnJoin.x, btnJoin.y, btnJoin.w, btnJoin.h):
      joinGame(joinCode)
    elif hitRect(x, y, btnSend.x, btnSend.y, btnSend.w, btnSend.h):
      sendChat()
    else:
      for b in openGameBtns:
        if hitRect(x, y, b.r.x, b.r.y, b.r.w, b.r.h):
          joinGame(b.id)
          break
  of viewGame:
    if hitRect(x, y, btnBack.x, btnBack.y, btnBack.w, btnBack.h):
      backToLobby()
    elif hitRect(x, y, fieldChat.x, fieldChat.y, fieldChat.w, fieldChat.h):
      focus = focusChat
    elif hitRect(x, y, btnSend.x, btnSend.y, btnSend.w, btnSend.h):
      sendChat()
    else:
      for i in 0 ..< cardRects.len:
        let r = cardRects[i]
        if hitRect(x, y, r.x, r.y, r.w, r.h) and not isDisabled(i):
          flip(i)
          break

proc main() =
  parseArgs()
  let (win, ren) = openWindow("Rememe Duo", 420, 700)
  let smoke = paramCount() >= 1 and paramStr(1) == "--smoke"
  setLogicalSize(ren, LOGICAL_W, LOGICAL_H)

  var running = true
  var lastPoll = 0

  while running:
    while true:
      let maybe = pollEvent()
      if maybe.isNone: break
      let e = maybe.get
      case e.kind
      of evQuit:
        running = false
      of evKeyDown:
        handleKey(e.key)
      of evTextInput:
        handleText(e.text)
      of evMouseDown:
        if e.button == btnLeft:
          handleTap(float(e.mouseX), float(e.mouseY))
      of evMouseWheel:
        chatScroll += float(e.wheelY) * 40.0
      else:
        discard

    let now = ticks()
    if token.len > 0 and roomId.len > 0 and now - lastPoll >= pollMs:
      lastPoll = now
      refresh()

    relayout()
    frame(ren)
    present(ren)
    if smoke:
      running = false

  close(win, ren)
  shutdown()

main()
