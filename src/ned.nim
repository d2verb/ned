{.experimental: "codeReordering".}

import termios
import strformat
import streams
import strscans
import strutils
import sequtils
import posix
import console
import system
import os
import times
import algorithm

const
  NEDVERSION = "0.0.1"
  NEDTABSTOP = 4

  HL_NUMBERS = (1 shl 0)
  HL_STRINGS = (1 shl 1)

type
  NedError = object of Exception

  NedSyntax = ref object
    filetype: string
    filematch: seq[string]
    keywords: seq[string]
    flags: int
    sline_comment_prefix: string

  NedRow = ref object
    raw: string
    render: string
    hl: seq[uint8]

  NedConfig = object
    orig_termios: Termios
    rx: int
    cx: int
    cy: int
    screenrows: int
    screencols: int
    rows: seq[NedRow]
    rowoff: int
    coloff: int
    filename: string
    statusmsg: string
    statusmsg_time: int64
    dirty: bool
    saved_hl_line: int
    saved_hl: seq[uint8]
    syntax: NedSyntax

  NedKey = enum
    nkBackSpace = 127
    nkArrowLeft = 1000
    nkArrowRight
    nkArrowUp
    nkArrowDown
    nkDelKey
    nkHomeKey
    nkEndKey
    nkPageUp
    nkPageDown

  NedHighlight = enum
    nhNormal = 0
    nhComment
    nhKeyword1
    nhKeyword2
    nhString
    nhNumber
    nhMatch

var
  E: NedConfig
  HLDB = @[
    NedSyntax(filetype: "c",
              filematch: @[".c", ".h", ".cpp"],
              keywords: @["switch", "if", "while", "for", "break", "continue", "return", "else",
                          "struct", "union", "typedef", "static", "enum", "class", "case",
                          "int|", "long|", "double|", "float|", "char|", "unsigned|", "signed|",
                          "void|"],
              flags: HL_NUMBERS or HL_STRINGS,
              sline_comment_prefix: "//"),
    NedSyntax(filetype: "nim",
              filematch: @[".nim"],
              keywords: @["addr", "and", "asm", "bind", "block", "break", "case", "cast",
                          "concept", "const", "continue", "converter", "defer", "discard", "distinct",
                          "div", "do", "elif", "else", "end", "enum", "except", "export",
                          "finally", "for", "from", "func", "if", "import", "in", "include", "interface", "is",
                          "isnot", "iterator", "let", "macro", "method", "mixin", "mod", "nil", "not", "notin",
                          "object", "of", "or", "out", "proc", "ptr", "raise", "ref", "return", "shl", "shr", "static",
                          "template", "try", "tuple", "type", "using", "var", "when", "while", "xor", "yield",
                          "int8|", "int16|", "int32|", "int64|", "uint8|", "uint|16", "uint32|", "uint64|", "int|", "uint|",
                          "float32|", "float64|", "float|", "bool|", "char|", "string|", "cstring|"],
              flags: HL_NUMBERS or HL_STRINGS,
              sline_comment_prefix: "#"),
  ]

proc isCntrl(c: cint): cint {.header: "ctype.h", importc: "iscntrl".}

proc ctrlKey(c: char): char =
  var cc = c.int
  cc = cc and 0x1f
  result = cc.char

proc disableRawMode() {.noconv.} =
  if stdin.getFileHandle.tcSetAttr(TCSAFLUSH, E.orig_termios.addr) == -1:
    raise newException(NedError, "tcsetattr() failed")

proc enableRawMode() =
  if stdin.getFileHandle.tcGetAttr(E.orig_termios.addr) == -1:
    raise newException(NedError, "tcgetattr() failed")

  addQuitProc(disableRawMode)

  var raw = E.orig_termios

  # Note: BRKINT, INPCK, ISTRIP, CS8 are set for a traditional reason

  # Disable:
  #   Ctrl-S
  #   Ctrl-Q
  # Fix:
  #   let Ctrl-M to produce (13, '\r') not (10, '\n')
  raw.c_iflag = raw.c_iflag and (not (BRKINT or ICRNL or INPCK or ISTRIP or IXON))

  # Disable:
  #   "\n" to "\r\n" translation
  raw.c_oflag = raw.c_oflag and (not (OPOST))

  # Set: char size to 8 bits per byte
  raw.c_cflag = raw.c_cflag or CS8

  # Disable:
  #   echo
  #   canonical mode
  #   Ctrl-C
  #   Ctrl-Z
  #   Ctrl-V
  raw.c_lflag = raw.c_lflag and (not (ECHO or ICANON or IEXTEN or ISIG))

  # Set time out for preventing read() from blocking
  raw.c_cc[VMIN] = 0.cuchar
  raw.c_cc[VTIME] = 1.cuchar

  if stdin.getFileHandle.tcSetAttr(TCSAFLUSH, raw.addr) == -1:
    raise newException(NedError, "tcsetattr() failed")

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
      quit()

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

proc nedClearScreen() {.noconv.} =
  clearScreen()
  resetCursorPos()

proc nedDrawWelcome(ab: Stream) =
  let welcome = fmt"Ned editor -- version {NEDVERSION}"

  var
    welcomelen = min(welcome.len, E.screencols)
    padding = (E.screencols - welcomelen) div 2

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

proc nedDrawRows(ab: Stream) =
  for y in 0..<E.screenrows:
    let filerow = y + E.rowoff
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

  ab.setCursorPos(E.rx - E.coloff + 1, E.cy - E.rowoff + 1)
  ab.showCursor()

  ab.setPosition(0)
  stdout.write(ab.readAll())

proc nedSetStatusMessage(msg: string) =
  E.statusmsg = msg
  E.statusmsg_time = getTime().toUnix()

# *** syntax highlighting ***
proc is_separator(c: char): bool =
  result = c.isSpaceAscii()
  result = result or (c == '\0')
  result = result or (c in ",.()+-/*=~%<>[];")

proc nedUpdateSyntax(row: var NedRow) =
  row.hl = newSeqWith(row.render.len, nhNormal.uint8)

  if E.syntax == nil:
    return

  let
    scs = E.syntax.sline_comment_prefix
    keywords = E.syntax.keywords

  var
    i = 0
    prev_is_sep = true
    in_string = '\0' # `\0` or `"` or `'`

  while i < row.render.len:
    let c = row.render[i]
    var prev_hl = nhNormal.uint8
    if i > 0:
      prev_hl = row.hl[i - 1]

    if scs.len > 0 and in_string == '\0':
      if i + scs.len <= row.render.len and row.render[i..<(i+scs.len)] == scs:
        row.hl.fill(i, row.hl.len - 1, nhComment.uint8)
        break

    if (E.syntax.flags and HL_STRINGS) != 0:
      if in_string != '\0':
        row.hl[i] = nhString.uint8
        if c == '\\' and i + 1 < row.render.len:
          row.hl[i+1] = nhString.uint8
          i += 2
          continue

        if c == in_string:
          in_string = '\0'

        i.inc
        prev_is_sep = true
        continue
      elif c == '"' or c == '\'':
        in_string = c
        row.hl[i] = nhString.uint8
        i.inc
        continue


    if (E.syntax.flags and HL_NUMBERS) != 0:
      if (c.isDigit() and (prev_is_sep or prev_hl == nhNumber.uint8)) or
         (c == '.' and prev_hl == nhNumber.uint8):
        row.hl[i] = nhNumber.uint8
        i.inc
        prev_is_sep = false
        continue

    if prev_is_sep:
      var kwfound = false
      for keyword in keywords:
        var
          kwlen = keyword.len
          kwcolor = nhKeyword1

        if keyword[kwlen-1] == '|':
          kwlen.dec
          kwcolor = nhKeyword2

        if i + kwlen <= row.render.len and row.render[i..<(i + kwlen)] == keyword[0..<kwlen]:
          var is_sep = false
          if i + kwlen < row.render.len and is_separator(row.render[i + kwlen]):
            is_sep = true
          elif i + kwlen >= row.render.len:
            is_sep = true

          if is_sep:
            kwfound = true
            row.hl.fill(i, i + kwlen - 1, kwcolor.uint8)
            i = i + kwlen
            break

      if kwfound:
        prev_is_sep = false
        continue


    prev_is_sep = c.is_separator()
    i.inc

proc nedSyntaxToColor(hl: uint8): int =
  case hl:
    of nhComment.uint8: return 36
    of nhKeyword1.uint8: return 33
    of nhKeyword2.uint8: return 32
    of nhString.uint8: return 35
    of nhNumber.uint8: return 31
    of nhMatch.uint8: return 34
    else: return 37

proc nedSelectSyntax() =
  E.syntax = nil
  if E.filename == "":
    return

  for j in 0..<HLDB.len:
    for i in 0..<HLDB[j].filematch.len:
      if not E.filename.endsWith(HLDB[j].filematch[i]):
        continue

      for k in 0..<E.rows.len:
        E.rows[k].nedUpdateSyntax()

      E.syntax = HLDB[j]
      return

# *** row operations ***
proc nedRowCxToRx(row: var NedRow, cx: int): int =
  result = 0
  for j in 0..<cx:
    if row.raw[j] == '\t':
      result += (NEDTABSTOP - 1) - (result mod NEDTABSTOP)
    result.inc

proc nedRowRxToCx(row: var NedRow, rx: int): int =
  result = 0
  for cx in 0..<row.raw.len:
    if row.raw[cx] == '\t':
      result += (NEDTABSTOP - 1) - (result mod NEDTABSTOP)
    result.inc
    if result > rx:
      return cx

proc nedUpdateRow(row: var NedRow) =
  row.render = ""
  for j in 0..<row.raw.len:
    let c = row.raw[j]
    if c == '\t':
      row.render.add(' ')
      while row.render.len mod NEDTABSTOP != 0:
        row.render.add(' ')
    else:
      row.render.add(row.raw[j])
  row.nedUpdateSyntax()

proc nedInsertRow(s: string, at: int) =
  if at < 0 or at > E.rows.len:
    return

  E.rows.insert(@[NedRow(raw: s, render: "")], at)
  E.rows[at].nedUpdateRow()

  E.dirty = true

proc nedDelRow(at: int) =
  if at < 0 or at >= E.rows.len:
    return
  E.rows.delete(at, at)
  E.dirty = true

proc nedRowInsertChar(row: var NedRow, at: int, c: char) =
  var nat = at
  if at < 0 or at > row.raw.len:
    nat = row.raw.len
  row.raw.insert($c, nat)
  row.nedUpdateRow()
  E.dirty = true

proc nedRowAppendString(row: var NedRow, s: string) =
  row.raw.add(s)
  row.nedUpdateRow()
  E.dirty = true

proc nedRowDelChar(row: var NedRow, at: int) =
  if at < 0 or at >= row.raw.len:
    return
  row.raw.delete(at, at)
  row.nedUpdateRow()
  E.dirty = true

# *** editor operations ***
proc nedInsertChar(c: char) =
  if E.cy == E.rows.len:
    nedInsertRow("", E.rows.len)
  E.rows[E.cy].nedRowInsertChar(E.cx, c)
  E.cx.inc

proc nedInsertNewline() =
  if E.cx == 0:
    nedInsertRow("", E.cy)
  else:
    let rowlen = E.rows[E.cy].raw.len
    nedInsertRow(E.rows[E.cy].raw[E.cx..<rowlen], E.cy + 1)
    E.rows[E.cy].raw.delete(E.cx, rowlen - 1)
    E.rows[E.cy].nedUpdateRow()
  E.cy.inc
  E.cx = 0

proc nedDelChar() =
  if E.cy == E.rows.len:
    return
  if E.cx == 0 and E.cy == 0:
    return

  if E.cx > 0:
    E.rows[E.cy].nedRowDelChar(E.cx - 1)
    E.cx.dec
  else:
    E.cx = E.rows[E.cy - 1].raw.len
    E.rows[E.cy - 1].nedRowAppendString(E.rows[E.cy].raw)
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

  nedSelectSyntax()

  try:
    var f = open(filename, fmRead)
    defer:
      f.close()

    while f.endOfFile == false:
      nedInsertRow(f.readLine(), E.rows.len)
  except IOError:
    # Do nothing if we failed to open file
    discard

proc nedSave() =
  if E.filename == "":
    E.filename = nedPrompt("Save as (ESC to cancel): ")
    if E.filename == "":
      nedSetStatusMessage("Save aborted")
      return
    nedSelectSyntax()

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
  addQuitProc(nedClearScreen)
  nedInit()

  if paramCount() >= 1:
    nedOpen(os.commandLineParams()[0])

  nedSetStatusMessage("HELP: Ctrl-W = save | Ctrl-Q = quit | Ctrl-S = search")

  while true:
    nedRefreshScreen()
    nedProcessKeypress()

when isMainModule:
  main()
