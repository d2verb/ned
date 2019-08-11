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

const NEDVERSION = "0.0.1"

type
  NedError = object of Exception

  NedConfig = object
    orig_termios: Termios
    cx: int
    cy: int
    screenrows: int
    screencols: int
    rows: seq[string]
    rowoff: int
    coloff: int
    filename: string
    statusmsg: string
    statusmsg_time: int64
    dirty: int

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

var E: NedConfig

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

proc nedMoveCursor(key: int) =
  case key:
    of nkArrowLeft.int:
      if E.cx != 0:
        E.cx.dec
    of nkArrowRight.int:
      if E.cy < E.rows.len and E.cx < E.rows[E.cy].len:
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
    rowlen = E.rows[E.cy].len

  if E.cx > rowlen:
    E.cx = rowlen

proc nedInsertChar(c: int) =
  if E.cy == E.rows.len:
    E.rows.add("")

  E.rows[E.cy].insert($c.char, E.cx)
  E.cx.inc

proc nedInsertNewLine() =
  if E.rows.len == 0:
    E.rows.add("")

  let
    rowlen = E.rows[E.cy].len
    newLineContent = E.rows[E.cy][E.cx..<rowlen]

  if rowlen - 1 >= E.cx:
    E.rows[E.cy].delete(E.cx, rowlen - 1)
  E.rows.insert(@[newLineContent], E.cy + 1)

  E.cy.inc
  E.cx = 0

proc nedDelRow(at: int) =
  if at < 0 or at >= E.rows.len:
    return

  E.rows.delete(at, at)
  E.dirty.inc

proc nedDelChar() =
  if E.cy == E.rows.len: return
  if E.cx == 0 and E.cy == 0: return

  if E.cx > 0:
    E.rows[E.cy].delete(E.cx - 1, E.cx - 1)
    E.cx.dec
  else:
    E.cx = E.rows[E.cy - 1].len
    E.rows[E.cy - 1].add(E.rows[E.cy])
    nedDelRow(E.cy)
    E.cy.dec

proc nedProcessKeypress() =
  var c = nedReadKey()
  case c:
    of '\r'.int:
      nedInsertNewLine()

    of ctrlKey('q').int:
      quit()

    of nkPageUp.int, nkPageDown.int:
      if c == nkPageUp.int:
        E.cy = E.rowoff
      elif c == nkPageDown.int:
        E.cy = min(E.rowoff + E.screenrows - 1, max(E.rows.len - 1, 0))

      for i in 0..<E.screenrows:
        if c == nkPageUp.int:
          nkArrowUp.int.nedMoveCursor
        else:
          nkArrowDown.int.nedMoveCursor

    of nkHomeKey.int:
      E.cx = 0
    of nkEndKey.int:
      if E.cy < E.rows.len:
        E.cx = E.rows[E.cy].len

    of nkBackSpace.int, ctrlKey('h').int, nkDelKey.int:
      if c == nkDelKey.int: nkArrowRight.int.nedMoveCursor()
      nedDelChar()

    of ctrlKey('l').int, ESC.int:
      discard

    of nkArrowUp.int, nkArrowDown.int, nkArrowLeft.int, nkArrowRight.int:
      c.nedMoveCursor()

    of 0:
      discard

    else:
      c.nedInsertChar()

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
  if E.cy < E.rowoff:
    E.rowoff = E.cy
  if E.cy >= E.rowoff + E.screenrows:
    E.rowoff = E.cy - E.screenrows + 1
  if E.cx < E.coloff:
    E.coloff = E.cx
  if E.cx >= E.coloff + E.screencols:
    E.coloff = E.cx - E.screencols + 1

proc nedDrawRows(ab: Stream) =
  for y in 0..<E.screenrows:
    let filerow = y + E.rowoff
    if filerow >= E.rows.len:
      if E.rows.len == 0 and y == E.screenrows div 3:
        ab.nedDrawWelcome()
      else:
        ab.write("~")
    else:
      var l = min(E.screencols, max(E.rows[filerow].len - E.coloff, 0))
      ab.write(E.rows[filerow][E.coloff..<(E.coloff + l)])

    ab.clearLine()
    ab.write("\r\n")

proc nedDrawStatusBar(ab: Stream) =
  ab.enableSGRReverseVideo()

  let
    status = &"{E.filename} - {E.rows.len} lines"
    rstatus = &"{E.cy + 1}/{E.rows.len}"
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

  ab.setCursorPos(E.cx - E.coloff + 1, E.cy - E.rowoff + 1)
  ab.showCursor()

  ab.setPosition(0)
  stdout.write(ab.readAll())

proc nedSetStatusMessage(msg: string) =
  E.statusmsg = msg
  E.statusmsg_time = getTime().toUnix()

proc nedOpen(filename: string) =
  var f: File = open(filename, FileMode.fmRead)
  defer:
    f.close()

  E.filename = filename

  while f.endOfFile == false:
    E.rows.add(f.readLine())

proc nedInit() =
  E.cx = 0
  E.cy = 0
  E.rowoff = 0
  E.coloff = 0
  E.statusmsg_time = 0
  E.filename = "[NO NAME]"

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

  nedSetStatusMessage("HELP: Ctrl-Q = quit")

  while true:
    nedRefreshScreen()
    nedProcessKeypress()

when isMainModule:
  main()
