# ui.nim — immediate-mode drawing + layout for the rememe-duo client.
#
# No retained widgets: every frame we compute the layout (rects) for the current
# view/state, then draw and (in main.nim) hit-test against the SAME rects.
# Screens mirror rememe-duo/index.php: name -> lobby -> game.

import std/math
import std/strutils

import gfx
import api

type
  Rect* = object
    x*, y*, w*, h*: float

  Focus* = enum
    focusName, focusJoin, focusChat

  OpenGameBtn* = object
    id*, p1*: string
    r*: Rect

# --- constants ---------------------------------------------------------------

const
  LOGICAL_W* = 480.0
  LOGICAL_H* = 800.0
  MARGIN = 16.0
  GAP = 10.0

# --- theme (mirrors rememe-duo/style.css) ------------------------------------

let
  cBg          = rgb(0xEE, 0xF0, 0xF4)
  cPanel       = rgb(0xFF, 0xFF, 0xFF)
  cText        = rgb(0x33, 0x38, 0x3F)
  cTitle       = rgb(0x2B, 0x30, 0x37)
  cMuted       = rgb(0x78, 0x80, 0x8C)
  cAccent      = rgb(0x4A, 0x7F, 0xD6)
  cAccentDark  = rgb(0x3D, 0x6F, 0xC2)
  cChip        = rgb(0xE9, 0xED, 0xF3)
  cChipText    = rgb(0x3A, 0x41, 0x4A)
  cFieldBg     = rgb(0xFF, 0xFF, 0xFF)
  cFieldBorder = rgb(0xD3, 0xD9, 0xE2)
  cTextDark    = rgb(0x2F, 0x34, 0x3B)
  cCardBack    = rgb(0xE6, 0xEA, 0xF1)
  cCardBorder  = rgb(0xD3, 0xD9, 0xE3)
  cCardBackMk  = rgb(0xAA, 0xB3, 0xC2)
  cCardUp      = rgb(0xD5, 0xE4, 0xFB)
  cCardUpBd    = rgb(0xBC, 0xD2, 0xF2)
  cCardMatch   = rgb(0xCF, 0xE9, 0xDB)
  cCardMatchBd = rgb(0xB4, 0xD9, 0xC3)
  cWin         = rgb(0x2F, 0x9E, 0x6E)
  cCode        = rgb(0x2F, 0x6B, 0xD0)
  cMsgBg       = rgb(0xEE, 0xF1, 0xF6)
  cMsgText     = rgb(0x3A, 0x41, 0x4A)
  cName        = rgb(0x2F, 0x6B, 0xD0)
  cError       = rgb(0xC0, 0x30, 0x30)

let symColors = [
  rgb(0xE0, 0x3A, 0x3A), # 0
  rgb(0xE0, 0x2A, 0x6A), # 1
  rgb(0xF0, 0xC0, 0x20), # 2
  rgb(0x3A, 0xC0, 0x50), # 3
  rgb(0x20, 0xA0, 0xD0), # 4
  rgb(0x3A, 0x6A, 0xE0), # 5
  rgb(0x7A, 0x3A, 0xE0), # 6
  rgb(0xE0, 0x7A, 0x2A), # 7
  rgb(0x20, 0xB0, 0xA0), # 8
  rgb(0xC0, 0x60, 0x20), # 9
  rgb(0xE0, 0xD0, 0x30), # 10
  rgb(0x90, 0x90, 0xE0), # 11
]

# --- shared layout state (computed each frame by relayout) -------------------

var
  focus* = focusName
  chatScroll* = 0.0

  btnEnter*, btnNewGame*, btnJoin*, btnBack*, btnSend*: Rect
  fieldName*, fieldJoin*, fieldChat*: Rect
  chatViewport*: Rect
  cardRects*: seq[Rect]
  openGameBtns*: seq[OpenGameBtn]

# --- drawing helpers ---

proc fillBordered(ren: Renderer; r: Rect; bc, fill: Color; t: float = 2.0) =
  fillRect(ren, r.x, r.y, r.w, r.h, bc)
  fillRect(ren, r.x + t, r.y + t, r.w - 2.0 * t, r.h - 2.0 * t, fill)

proc textW(ren: Renderer; text: string; px: float): float =
  float(textSize(ren, text, px)[0])

proc textH(ren: Renderer; text: string; px: float): float =
  float(textSize(ren, text, px)[1])

proc drawTextCentered(ren: Renderer; text: string; y, px: float; c: Color) =
  let w = textW(ren, text, px)
  drawText(ren, (LOGICAL_W - w) / 2.0, y, text, c, px)

proc drawTextIn(ren: Renderer; text: string; r: Rect; px: float; c: Color;
                centered = true) =
  if centered:
    let w = textW(ren, text, px)
    let h = textH(ren, text, px)
    drawText(ren, r.x + (r.w - w) / 2.0, r.y + (r.h - h) / 2.0, text, c, px)
  else:
    drawText(ren, r.x + 10.0, r.y + (r.h - px) / 2.0, text, c, px)

proc drawButton(ren: Renderer; r: Rect; label: string; px: float;
                enabled = true) =
  let bc = if enabled: cAccentDark else: cMuted
  let fill = if enabled: cAccent else: cMuted
  fillBordered(ren, r, bc, fill, 2.0)
  drawTextIn(ren, label, r, px, cPanel, centered = true)

proc drawField(ren: Renderer; r: Rect; text, placeholder: string; px: float;
               focused: bool) =
  fillBordered(ren, r, (if focused: cAccent else: cFieldBorder), cFieldBg, 2.0)
  setClipRect(ren, r.x + 6.0, r.y, r.w - 12.0, r.h)
  if text.len > 0:
    drawText(ren, r.x + 10.0, r.y + (r.h - px) / 2.0, text, cTextDark, px)
    if focused and (ticks() div 400) mod 2 == 0:
      let tw = textW(ren, text, px)
      drawText(ren, r.x + 10.0 + tw + 1.0, r.y + (r.h - px) / 2.0, "|", cTextDark, px)
  else:
    drawText(ren, r.x + 10.0, r.y + (r.h - px) / 2.0, placeholder, cMuted, px)
  resetClip(ren)

# --- card symbols ---

proc drawStar(ren: Renderer; cx, cy, s: float; c: Color) =
  let outer = s * 0.46
  let inner = s * 0.20
  var pts: array[10, (float, float)]
  for i in 0 ..< 10:
    let r = if i mod 2 == 0: outer else: inner
    let a = -PI / 2.0 + float(i) * PI / 5.0
    pts[i] = (cx + r * cos(a), cy + r * sin(a))
  polygon(ren, pts, c)

proc drawHeart(ren: Renderer; cx, cy, s: float; c: Color) =
  let w = s * 0.25
  let lobeY = cy - s * 0.10
  let tipY = cy + s * 0.42
  moveTo(ren, cx, tipY)
  lineTo(ren, cx - 2.0 * w, lobeY)
  arcTo(ren, cx - w, lobeY, w, PI, 2.0 * PI)
  arcTo(ren, cx + w, lobeY, w, PI, 2.0 * PI)
  lineTo(ren, cx, tipY)
  closePath(ren)
  fillPath(ren, c)

proc drawDiamond(ren: Renderer; cx, cy, s: float; c: Color) =
  let d = s * 0.44
  polygon(ren, [(cx, cy - d), (cx + d, cy), (cx, cy + d), (cx - d, cy)], c)

proc drawTriangle(ren: Renderer; cx, cy, s: float; c: Color) =
  let d = s * 0.44
  polygon(ren, [(cx, cy - d), (cx + d, cy + d * 0.9), (cx - d, cy + d * 0.9)], c)

proc drawSquare(ren: Renderer; cx, cy, s: float; c: Color) =
  let d = s * 0.38
  fillRect(ren, cx - d, cy - d, 2.0 * d, 2.0 * d, c)

proc drawX(ren: Renderer; cx, cy, s: float; c: Color) =
  let d = s * 0.38
  let w = s * 0.13
  polyline(ren, [(cx - d, cy - d), (cx + d, cy + d)], c, w)
  polyline(ren, [(cx - d, cy + d), (cx + d, cy - d)], c, w)

proc drawPlus(ren: Renderer; cx, cy, s: float; c: Color) =
  let t = s * 0.13
  let d = s * 0.40
  fillRect(ren, cx - d, cy - t, 2.0 * d, 2.0 * t, c)
  fillRect(ren, cx - t, cy - d, 2.0 * t, 2.0 * d, c)

proc drawArrowUp(ren: Renderer; cx, cy, s: float; c: Color) =
  let head = s * 0.42
  let halfW = s * 0.28
  polygon(ren, [(cx, cy - head), (cx + halfW, cy), (cx - halfW, cy)], c)
  fillRect(ren, cx - s * 0.10, cy, s * 0.20, s * 0.40, c)

proc drawArrowDown(ren: Renderer; cx, cy, s: float; c: Color) =
  let head = s * 0.42
  let halfW = s * 0.28
  polygon(ren, [(cx, cy + head), (cx + halfW, cy), (cx - halfW, cy)], c)
  fillRect(ren, cx - s * 0.10, cy - s * 0.40, s * 0.20, s * 0.40, c)

proc drawBolt(ren: Renderer; cx, cy, s: float; c: Color) =
  polygon(ren, [
    (cx + s * 0.08, cy - s * 0.45),
    (cx - s * 0.28, cy + s * 0.05),
    (cx - s * 0.02, cy + s * 0.05),
    (cx - s * 0.08, cy + s * 0.45),
    (cx + s * 0.28, cy - s * 0.05),
    (cx + s * 0.02, cy - s * 0.05),
  ], c)

proc drawSmiley(ren: Renderer; cx, cy, s: float; c: Color) =
  let r = s * 0.42
  let w = max(1.0, r * 0.12)
  arc(ren, cx, cy, r, 0.0, 2.0 * PI, c, filled = false, width = w)
  let eye = max(1.0, r * 0.09)
  drawCircle(ren, cx - r * 0.35, cy - r * 0.30, eye, c)
  drawCircle(ren, cx + r * 0.35, cy - r * 0.30, eye, c)
  arc(ren, cx, cy + r * 0.15, r * 0.55, PI * 0.15, PI * 0.85, c,
      filled = false, width = w)

proc drawSymbol(ren: Renderer; id: int; area: Rect; tint: Color) =
  let s = min(area.w, area.h)
  let cx = area.x + area.w / 2.0
  let cy = area.y + area.h / 2.0
  case id mod 12
  of 0: drawStar(ren, cx, cy, s, tint)
  of 1: drawHeart(ren, cx, cy, s, tint)
  of 2: drawDiamond(ren, cx, cy, s, tint)
  of 3: drawCircle(ren, cx, cy, s * 0.44, tint)
  of 4: drawTriangle(ren, cx, cy, s, tint)
  of 5: drawSquare(ren, cx, cy, s, tint)
  of 6: drawX(ren, cx, cy, s, tint)
  of 7: drawPlus(ren, cx, cy, s, tint)
  of 8: drawArrowUp(ren, cx, cy, s, tint)
  of 9: drawArrowDown(ren, cx, cy, s, tint)
  of 10: drawBolt(ren, cx, cy, s, tint)
  of 11: drawSmiley(ren, cx, cy, s, tint)
  else: discard

proc emojiSymbol(emoji: string): int =
  case emoji
  of "🐶": 0
  of "🐱": 1
  of "🦊": 2
  of "🐸": 3
  of "🐙": 4
  of "🦋": 5
  of "🍎": 6
  of "🍕": 7
  of "⭐": 8
  of "🌈": 9
  of "🎲": 10
  of "🚀": 11
  else: -1

proc drawCardFace(ren: Renderer; emoji: string; area: Rect) =
  let sym = emojiSymbol(emoji)
  if sym >= 0:
    drawSymbol(ren, sym, area, symColors[sym mod 12])
  else:
    drawTextIn(ren, emoji, area, 26.0, cText, centered = true)

proc drawCard(ren: Renderer; i: int; r: Rect) =
  let flipped = cardFlipped(i)
  let matched = cardMatched(i)
  var border = cCardBorder
  var fill = cCardBack
  if flipped or matched:
    if matched:
      border = cCardMatchBd; fill = cCardMatch
    else:
      border = cCardUpBd; fill = cCardUp
  fillBordered(ren, r, border, fill, 2.0)
  if flipped or matched:
    drawCardFace(ren, cardEmoji(i), r)
  else:
    drawSymbol(ren, 2, r, cCardBackMk)

# --- screens & frame ---

proc drawChat(ren: Renderer; viewport: Rect; placeholder: string) =
  fillRect(ren, viewport.x, viewport.y, viewport.w, viewport.h, cMsgBg)
  setClipRect(ren, viewport.x, viewport.y, viewport.w, viewport.h)
  let msgs = messages()
  let msgH = 24.0
  let gap = 4.0
  let total = float(msgs.len) * msgH + float(max(msgs.len - 1, 0)) * gap
  let maxScroll = max(0.0, total - viewport.h)
  if chatScroll > maxScroll: chatScroll = maxScroll
  if chatScroll < 0.0: chatScroll = 0.0
  let topY = viewport.y + viewport.h - total + chatScroll
  var y = topY
  for m in msgs:
    let who = msgName(m) & ": "
    let ww = textW(ren, who, 14.0)
    drawText(ren, viewport.x + 8.0, y + 4.0, who, cName, 14.0)
    drawText(ren, viewport.x + 8.0 + ww, y + 4.0, msgText(m), cMsgText, 14.0)
    y += msgH + gap
  resetClip(ren)
  drawField(ren, fieldChat, draft, placeholder, 16.0, focus == focusChat)
  drawButton(ren, btnSend, "send", 16.0)

proc drawScoreboard(ren: Renderer) =
  let y = 68.0
  let h = 44.0
  let p1on = isWinner("p1") or isActive("p1")
  let p2on = isWinner("p2") or isActive("p2")
  let p1bg = if isWinner("p1"): cWin elif isActive("p1"): cAccent else: cChip
  let p2bg = if isWinner("p2"): cWin elif isActive("p2"): cAccent else: cChip
  let p1fg = if p1on: cPanel else: cChipText
  let p2fg = if p2on: cPanel else: cChipText
  let ty = y + (h - 16.0) / 2.0
  roundedRect(ren, 40.0, y, 170.0, h, 8.0, p1bg)
  drawText(ren, 52.0, ty, p1Name(), p1fg, 16.0)
  let s1w = textW(ren, $score("p1"), 16.0)
  drawText(ren, 40.0 + 170.0 - 12.0 - s1w, ty, $score("p1"), p1fg, 16.0)
  drawTextCentered(ren, "vs", ty, 16.0, cMuted)
  roundedRect(ren, 270.0, y, 170.0, h, 8.0, p2bg)
  drawText(ren, 282.0, ty, $score("p2"), p2fg, 16.0)
  let n2w = textW(ren, p2Name(), 16.0)
  drawText(ren, 270.0 + 170.0 - 12.0 - n2w, ty, p2Name(), p2fg, 16.0)

proc renderName(ren: Renderer) =
  drawTextCentered(ren, "Rememe Duo", 120.0, 36.0, cTitle)
  drawTextWrapped(ren, 60.0, 190.0, LOGICAL_W - 120.0,
    "Two screens, one memory duel. Pick a name to enter the lobby.", cMuted, 16.0)
  drawField(ren, fieldName, name, "your name", 18.0, focus == focusName)
  drawButton(ren, btnEnter, "enter lobby", 18.0)

proc renderLobby(ren: Renderer) =
  drawText(ren, MARGIN, 24.0, "Lobby", cTitle, 20.0)

  drawText(ren, MARGIN, 70.0, "who's here", cMuted, 12.0)
  var names: seq[string] = @[]
  for p in people(): names.add(personName(p))
  if names.len == 0:
    drawText(ren, MARGIN, 94.0, "nobody yet", cMuted, 14.0)
  else:
    drawTextWrapped(ren, MARGIN, 94.0, LOGICAL_W - 2.0 * MARGIN,
                    names.join(", "), cText, 14.0)

  drawText(ren, MARGIN, 168.0, "open games (click to join)", cMuted, 12.0)
  if openGameBtns.len == 0:
    drawText(ren, MARGIN, 192.0, "none yet - create one below", cMuted, 14.0)
  else:
    for b in openGameBtns:
      fillBordered(ren, b.r, cAccent, cPanel, 2.0)
      let codeArea = Rect(x: b.r.x + 8.0, y: b.r.y, w: 96.0, h: b.r.h)
      drawTextIn(ren, b.id, codeArea, 16.0, cAccent, centered = true)
      drawText(ren, b.r.x + 112.0, b.r.y + (b.r.h - 16.0) / 2.0, b.p1, cText, 16.0)

  drawButton(ren, btnNewGame, "new game", 16.0)
  drawField(ren, fieldJoin, joinCode, "game code", 16.0, focus == focusJoin)
  drawButton(ren, btnJoin, "join", 16.0)

  drawChat(ren, chatViewport, "chat with everyone...")

proc renderGame(ren: Renderer) =
  drawButton(ren, btnBack, "lobby", 16.0)
  drawTextCentered(ren, statusText(), 30.0, 18.0, cTitle)
  drawScoreboard(ren)
  if status() == "waiting":
    drawTextCentered(ren, "Share this code with your opponent:", 180.0, 16.0, cText)
    drawTextCentered(ren, roomId, 220.0, 34.0, cCode)
    drawTextCentered(ren, "waiting for them to join...", 280.0, 14.0, cMuted)
  else:
    for i in 0 ..< cardRects.len:
      drawCard(ren, i, cardRects[i])
  drawChat(ren, chatViewport, "chat with your rival...")

proc frame*(ren: Renderer) =
  clear(ren, cBg)
  case view
  of viewName: renderName(ren)
  of viewLobby: renderLobby(ren)
  of viewGame: renderGame(ren)
  if errorMsg.len > 0:
    drawText(ren, MARGIN, LOGICAL_H - 30.0, errorMsg, cError, 14.0)

# --- layout ---

proc relayout*() =
  case view
  of viewName:
    fieldName = Rect(x: 40.0, y: 300.0, w: 400.0, h: 48.0)
    btnEnter = Rect(x: 140.0, y: 380.0, w: 200.0, h: 48.0)
  of viewLobby:
    fieldChat = Rect(x: MARGIN, y: 560.0, w: LOGICAL_W - 2.0 * MARGIN - 90.0, h: 44.0)
    btnSend = Rect(x: fieldChat.x + fieldChat.w + 8.0, y: 560.0, w: 82.0, h: 44.0)
    chatViewport = Rect(x: MARGIN, y: 380.0, w: LOGICAL_W - 2.0 * MARGIN, h: 168.0)
    btnNewGame = Rect(x: MARGIN, y: 300.0, w: 150.0, h: 44.0)
    fieldJoin = Rect(x: btnNewGame.x + btnNewGame.w + 8.0, y: 300.0,
                     w: LOGICAL_W - 2.0 * MARGIN - btnNewGame.w - 8.0 - 90.0, h: 44.0)
    btnJoin = Rect(x: fieldJoin.x + fieldJoin.w + 8.0, y: 300.0, w: 82.0, h: 44.0)
    openGameBtns = @[]
    var y = 190.0
    for g in openGames:
      openGameBtns.add(OpenGameBtn(id: ogId(g), p1: ogP1(g),
        r: Rect(x: MARGIN, y: y, w: LOGICAL_W - 2.0 * MARGIN, h: 38.0)))
      y += 46.0
  of viewGame:
    btnBack = Rect(x: MARGIN, y: 16.0, w: 90.0, h: 40.0)
    let n = cardCount()
    cardRects = @[]
    if n > 0:
      let boardX = MARGIN
      let boardY = 124.0
      let boardW = LOGICAL_W - 2.0 * MARGIN
      let boardH = 340.0
      let cols = (if n <= 12: 4 elif n <= 20: 5 else: 6)
      let rows = (n + cols - 1) div cols
      let cw = (boardW - float(cols - 1) * GAP) / float(cols)
      let ch = (boardH - float(rows - 1) * GAP) / float(rows)
      for r in 0 ..< rows:
        for c in 0 ..< cols:
          let idx = r * cols + c
          if idx >= n: break
          cardRects.add(Rect(x: boardX + float(c) * (cw + GAP),
                             y: boardY + float(r) * (ch + GAP),
                             w: cw, h: ch))
    fieldChat = Rect(x: MARGIN, y: 610.0, w: LOGICAL_W - 2.0 * MARGIN - 90.0, h: 44.0)
    btnSend = Rect(x: fieldChat.x + fieldChat.w + 8.0, y: 610.0, w: 82.0, h: 44.0)
    chatViewport = Rect(x: MARGIN, y: 474.0, w: LOGICAL_W - 2.0 * MARGIN, h: 126.0)
