{.experimental: "codeReordering".}

import termios
import strformat
import streams
import strscans
import strutils
import sequtils
import posix
import system
import os
import times
import algorithm

import console
import common
import syntax
import rowops

const
  NEDVERSION = "0.0.1"

var
  E: NedConfig

proc isCntrl(c: cint): cint {.header: "ctype.h", importc: "iscntrl".}

proc ctrlKey(c: char): char =
  var cc = c.int
  cc = cc and 0x1f
  result = cc.char

proc nedReadKey(): int =
  var c = '\0'

  try:
    stdin.newFileStream.read(c)
  except IOError:
    discard

  if c != ESC:
    return c.int

  var c1, c2, c3: char
  if stdin.newFileStream.readData(c1.addr, 1) != 1:
    return ESC.int
  if stdin.newFileStream.readData(c2.addr, 1) != 1:
    return ESC.int

  if c1 == 'O':
    case c2:
      of 'H': return nkHomeKey.int
      of 'F': return nkEndKey.int
      else: discard
  elif c1 == '[':
    if c2.isDigit:
      if stdin.newFileStream.readData(c3.addr, 1) != 1:
        return ESC.int

      if c3 == '~':
        case c2:
          of '1': return nkHomeKey.int
          of '3': return nkDelKey.int
          of '4': return nkEndKey.int
          of '5': return nkPageUp.int
          of '6': return nkPageDown.int
          of '7': return nkHomeKey.int
          of '8': return nkEndKey.int
          else: discard
    else:
      case c2:
        of 'A': return nkArrowUp.int
        of 'B': return nkArrowDown.int
        of 'C': return nkArrowRight.int
        of 'D': return nkArrowLeft.int
        of 'H': return nkHomeKey.int
        of 'F': return nkEndKey.int
        else: discard
  else:
    return ESC.int

proc nedPrompt(prompt: string, callback: proc(x: string, y: int) = nil): string =
  while true:
    # Show prompt
    nedSetStatusMessage(prompt & result)
    nedRefreshScreen()

    # Read key
    let c = nedReadKey()

    if c == nkDelKey.int or c == nkBackSpace.int:
      if result.len > 0:
        result.delete(result.len - 1, result.len - 1)
    elif c == ESC.int:
      nedSetStatusMessage("")
      if callback != nil: callback(result, c)
      result = ""
      return
    elif c == '\r'.int:
      nedSetStatusMessage("")
      if callback != nil: callback(result, c)
      return
    elif c == '\0'.int:
      # No input. Just ignore it
      continue
    elif isCntrl(c.cint) == 0 and c < 128:
      result.add(c.char)

    if callback != nil: callback(result, c)

proc nedMoveCursor(key: int) =
  case key:
    of nkArrowLeft.int:
      if E.cx != 0:
        E.cx.dec
    of nkArrowRight.int:
      if E.cy < E.rows.len and E.cx < E.rows[E.cy].raw.len:
        E.cx.inc
    of nkArrowUp.int:
      if E.cy != 0:
        E.cy.dec
    of nkArrowDown.int:
      if E.cy + 1 < E.rows.len:
        E.cy.inc
    else:
      discard

  var rowlen = 0
  if E.cy < E.rows.len:
    rowlen = E.rows[E.cy].raw.len

  if E.cx > rowlen:
    E.cx = rowlen

proc nedProcessKeypress() =
  var c = nedReadKey()
  case c:
    of '\r'.int:
      nedInsertNewline()

    of ctrlKey('q').int:
      if not E.dirty:
        quit()
      else:
        while true:
          let res = nedPrompt("Content is modified. Do you really want to quit? [y/n]: ").strip()
          if res == "y":
            quit()
          elif res == "n":
            break

    of ctrlKey('w').int:
      nedSave()

    of ctrlKey('s').int:
      nedFind()

    of ctrlKey('h').int:
      nkArrowLeft.int.nedMoveCursor

    of ctrlKey('j').int:
      nkArrowDown.int.nedMoveCursor

    of ctrlKey('k').int:
      nkArrowUp.int.nedMoveCursor

    of ctrlKey('l').int:
      nkArrowRight.int.nedMoveCursor

    of nkPageUp.int, nkPageDown.int, ctrlKey('f').int, ctrlKey('b').int:
      if c == nkPageUp.int or c == ctrlKey('b').int:
        E.cy = E.rowoff
      elif c == nkPageDown.int or c == ctrlKey('f').int:
        E.cy = min(E.rowoff + E.screenrows - 1, max(E.rows.len - 1, 0))

      for i in 0..<E.screenrows:
        if c == nkPageUp.int or c == ctrlKey('b').int:
          nkArrowUp.int.nedMoveCursor
        else:
          nkArrowDown.int.nedMoveCursor

    of nkHomeKey.int:
      E.cx = 0

    of nkEndKey.int:
      if E.cy < E.rows.len:
        E.cx = E.rows[E.cy].raw.len

    of nkBackSpace.int, nkDelKey.int:
      if c == nkDelKey.int: nkArrowRight.int.nedMoveCursor()
      nedDelChar()

    of nkArrowUp.int, nkArrowDown.int, nkArrowLeft.int, nkArrowRight.int:
      c.nedMoveCursor()

    of 0, ESC.int:
      discard

    else:
      c.char.nedInsertChar()

proc nedDrawWelcome(ab: Stream) =
  let welcome = fmt"Ned editor -- version {NEDVERSION}"

  var
    welcomelen = min(welcome.len, E.screencols)
    padding = (E.screencols - welcomelen) div 2 - 5

  if padding != 0:
    ab.write("~")

  while padding != 0:
    ab.write(" ")
    padding.dec

  ab.write(welcome[0..<welcomelen])

proc nedScroll() =
  E.rx = 0
  if E.cy < E.rows.len:
    E.rx = E.rows[E.cy].nedRowCxToRx(E.cx)

  if E.cy < E.rowoff:
    E.rowoff = E.cy
  if E.cy >= E.rowoff + E.screenrows:
    E.rowoff = E.cy - E.screenrows + 1
  if E.rx < E.coloff:
    E.coloff = E.rx
  if E.rx >= E.coloff + E.screencols:
    E.coloff = E.rx - E.screencols + 1

  E.rows.nedUpdateSyntax(E.syntax, E.rowoff, min(E.rowoff + E.screenrows, E.rows.len - 1))

proc nedBuildLineno(lineno: int): string =
  let lineno_len = max(3, (&"{E.rowoff + E.screenrows}").len)
  result = &"{lineno}"
  result = " ".repeat(max(0, lineno_len - result.len)) & result & "| "

proc nedDrawRows(ab: Stream) =
  for y in 0..<E.screenrows:
    let filerow = y + E.rowoff

    ab.setColor(ccFgCyan.int)
    ab.write(nedBuildLineno(filerow + 1))
    ab.setForegroundDefaultColor()

    if filerow >= E.rows.len:
      if E.rows.len == 0 and y == E.screenrows div 3:
        ab.nedDrawWelcome()
      else:
        ab.write("~")
    else:
      let l = min(E.screencols, max(E.rows[filerow].render.len - E.coloff, 0))
      var current_color = -1

      for j in E.coloff..<(E.coloff + l):
        if E.rows[filerow].hl[j] == nhNormal.uint8:
          if current_color != -1:
            ab.setForegroundDefaultColor()
            current_color = -1
          ab.write($E.rows[filerow].render[j])
        else:
          let color = E.rows[filerow].hl[j].nedSyntaxToColor()
          if color != current_color:
            current_color = color
            ab.setColor(color)
          ab.write($E.rows[filerow].render[j])
      ab.setForegroundDefaultColor()

    ab.clearLine()
    ab.write("\r\n")

proc nedDrawStatusBar(ab: Stream) =
  ab.enableSGRReverseVideo()

  var filename = E.filename
  if filename == "":
    filename = "[NO NAME]"

  var modified = ""
  if E.dirty:
    modified = "(modified)"

  var filetype = "no ft"
  if E.syntax != nil:
    filetype = E.syntax.filetype

  let
    status = &"{filename} - {E.rows.len} lines {modified}"
    rstatus = &"{filetype} | {E.cy + 1}:{E.rx + 1}"
    ln = min(E.screencols, status.len)

  ab.write(status[0..<ln])

  for i in ln..<E.screencols:
    if E.screencols - i == rstatus.len:
      ab.write(rstatus)
      break
    else:
      ab.write(" ")

  ab.resetSGR()
  ab.write("\r\n")

proc nedDrawMessageBar(ab: Stream) =
  ab.clearLine()
  let msglen = min(E.screencols, E.statusmsg.len)
  if msglen > 0 and (getTime().toUnix() - E.statusmsg_time < 5):
    ab.write(E.statusmsg[0..<msglen])

proc nedRefreshScreen() =
  nedScroll()

  var ab = newStringStream("")

  ab.hideCursor()
  ab.resetCursorPos()

  ab.nedDrawRows()
  ab.nedDrawStatusBar()
  ab.nedDrawMessageBar()

  ab.setCursorPos(E.rx - E.coloff + 1 + nedBuildLineno(0).len, E.cy - E.rowoff + 1)
  ab.showCursor()

  ab.setPosition(0)
  stdout.write(ab.readAll())

proc nedSetStatusMessage(msg: string) =
  E.statusmsg = msg
  E.statusmsg_time = getTime().toUnix()

proc nedUpdateSyntax(rows: var seq[NedRow], syntax: var NedSyntax, start: int = 0, last: int = -1) =
  var actual_last = if last == -1: E.rows.len - 1 else: last

  for i in start..actual_last:
    rows[i].nedUpdateSyntax(syntax)

# *** editor operations ***
proc nedInsertRow(s: string, at: int, update_syntax: bool = true, update_dirty = true) =
  if at < 0 or at > E.rows.len:
    return

  E.rows.insert(@[NedRow(raw: s, render: "", hled: false)], at)
  E.rows[at].nedRowUpdate()

  if update_syntax:
    E.rows[at].nedUpdateSyntax(E.syntax)

  if update_dirty:
    E.dirty = true

proc nedDelRow(at: int) =
  if at < 0 or at >= E.rows.len:
    return
  E.rows.delete(at, at)
  E.dirty = true

proc nedInsertChar(c: char) =
  if E.cy == E.rows.len:
    nedInsertRow("", E.rows.len)
  E.rows[E.cy].nedRowInsertChar(E.cx, c)
  E.rows[E.cy].nedUpdateSyntax(E.syntax)
  E.dirty = true
  E.cx.inc

proc nedInsertNewline() =
  if E.cx == 0:
    nedInsertRow("", E.cy)
  else:
    let rowlen = E.rows[E.cy].raw.len
    nedInsertRow(E.rows[E.cy].raw[E.cx..<rowlen], E.cy + 1)
    E.rows[E.cy].nedRowDelChars(E.cx, rowlen - 1)
    E.rows[E.cy].nedRowUpdate()
    E.rows[E.cy].nedUpdateSyntax(E.syntax)
  E.cy.inc
  E.cx = 0

proc nedDelChar() =
  if E.cy == E.rows.len:
    return
  if E.cx == 0 and E.cy == 0:
    return

  if E.cx > 0:
    E.rows[E.cy].nedRowDelChar(E.cx - 1)
    E.rows[E.cy].nedUpdateSyntax(E.syntax)
    E.dirty = true
    E.cx.dec
  else:
    E.cx = E.rows[E.cy - 1].raw.len
    E.rows[E.cy - 1].nedRowAppendString(E.rows[E.cy].raw)
    E.rows[E.cy - 1].nedUpdateSyntax(E.syntax)
    E.dirty = true
    nedDelRow(E.cy)
    E.cy.dec

# *** file i/o ***
proc nedRowsToString(): string =
  result = ""
  for i in 0..<E.rows.len:
    if i != 0:
      result = result & "\n"
    result = result & E.rows[i].raw

proc nedOpen(filename: string) =
  E.filename = filename
  E.syntax = filename.nedSelectSyntax()

  try:
    var f = open(filename, fmRead)
    defer:
      f.close()

    while f.endOfFile == false:
      nedInsertRow(f.readLine(), E.rows.len, update_syntax=false, update_dirty=false)
  except IOError:
    # Do nothing if we failed to open file
    discard
    
  E.rows.nedUpdateSyntax(E.syntax, 0, min(E.screenrows, E.rows.len - 1))

proc nedSave() =
  if E.filename == "":
    E.filename = nedPrompt("Save as (ESC to cancel): ")
    if E.filename == "":
      nedSetStatusMessage("Save aborted")
      return
    E.syntax = E.filename.nedSelectSyntax()
    
    # New syntax is loaded. We must re-highlight whole the content
    for i in 0..<E.rows.len:
      E.rows[i].hled = false

    E.rows.nedUpdateSyntax(E.syntax, E.rowoff, min(E.rowoff + E.screenrows, E.rows.len - 1))
  else:
    while true:
      let res = nedPrompt("Do you really want to save it? [y/n]: ").strip()
      if res == "y":
        break
      elif res == "n":
        return

  try:
    var f = open(E.filename, fmReadWrite)
    defer:
      f.close()

    let output = nedRowsToString()
    f.write(output)
    E.dirty = false
    nedSetStatusMessage(&"{output.len} bytes written to disk")
  except:
    let
      e = getCurrentException()
      msg = getCurrentExceptionMsg()
    nedSetStatusMessage(&"Can't save! " & e.repr & ": " & msg)

proc nedFindCallback(query: string, key: int) =
  if E.saved_hl.len != 0:
    for i in 0..<E.saved_hl.len:
      E.rows[E.saved_hl_line].hl[i] = E.saved_hl[i]
    E.saved_hl = @[]

  if key == '\r'.int or key == ESC.int:
    return

  for i in 0..<E.rows.len:
    let match = E.rows[i].render.find(query)
    if match != -1:
      E.cy = i
      E.cx = E.rows[i].nedRowRxToCx(match)
      E.rowoff = E.rows.len

      E.saved_hl_line = i
      for j in 0..<E.rows[i].hl.len:
        E.saved_hl.add(E.rows[i].hl[j])

      for j in match..<(match + query.len):
        E.rows[i].hl[j] = nhMatch.uint8

      break

proc nedFind() =
  let
    saved_cx = E.cx
    saved_cy = E.cy
    saved_coloff = E.coloff
    saved_rowoff = E.rowoff
    query = nedPrompt("Search (ESC to cancel): ", nedFindCallback)

  if query == "":
    E.cx = saved_cx
    E.cy = saved_cy
    E.coloff = saved_coloff
    E.rowoff = saved_rowoff

proc nedInit() =
  E.rx = 0
  E.cx = 0
  E.cy = 0
  E.rowoff = 0
  E.coloff = 0
  E.statusmsg_time = 0
  E.dirty = false
  E.syntax = nil

  let (rows, cols) = getWindowSize()
  E.screenrows = rows
  E.screencols = cols

  E.screenrows -= 2

proc main() =
  enableRawMode()
  switchToAlternateScreen()
  nedInit()

  if paramCount() >= 1:
    nedOpen(os.commandLineParams()[0])

  nedSetStatusMessage("HELP: Ctrl-W = save | Ctrl-Q = quit | Ctrl-S = search")

  while true:
    nedRefreshScreen()
    nedProcessKeypress()

when isMainModule:
  main()
