import strformat
import streams
import strutils
import strscans
import posix
import termios

import common

const
  TIOCGWINSZ = 0x5413
  ESC* = '\x1b'

type
  ConsoleError = object of Exception

  WinSize = object
    row: cushort
    col: cushort
    xpixel: cushort
    ypixel: cushort

proc clearScreen*() =
  let output = &"{ESC}[2J"
  if stdout.writeChars(output, 0, output.len) != output.len:
    raise ConsoleError.newException("clearScreen() failed")

proc clearScreen*(s: Stream) =
  let output = &"{ESC}[2J"
  s.write(output)

proc clearLine*(n: int = 0) =
  let output = &"{ESC}[{n}K"
  if stdout.writeChars(output, 0, output.len) != output.len:
    raise ConsoleError.newException("clearLine() failed")

proc clearLine*(s: Stream, n: int = 0) =
  let output = &"{ESC}[{n}K"
  s.write(output)

proc setCursorPos*(x, y: int) =
  let output = &"{ESC}[{y};{x}H"
  if stdout.writeChars(output, 0, output.len) != output.len:
    raise ConsoleError.newException("setCursorPos() failed")

proc setCursorPos*(s:Stream, x, y: int) =
  let output = &"{ESC}[{y};{x}H"
  s.write(output)

proc resetCursorPos*() =
  let output = &"{ESC}[H"
  if stdout.writeChars(output, 0, output.len) != output.len:
    raise ConsoleError.newException("resetCursorPos() failed")

proc resetCursorPos*(s: Stream) =
  let output = &"{ESC}[H"
  s.write(output)

proc queryCursorPosition*() =
  let output = &"{ESC}[6n"
  if stdout.writeChars(output, 0, output.len) != output.len:
    raise ConsoleError.newException("queryCursorPos() failed")

proc queryCursorPosition*(s: Stream) =
  let output = &"{ESC}[6n"
  s.write(output)

proc getCursorPos*(): tuple[rows: int, cols: int] =
  queryCursorPosition()

  const maxBufSize = 32
  var
    i = 0
    buf = ""

  while i < maxBufSize:
    var c: char
    if stdin.newFileStream.readData(c.addr, 1) != 1:
      break
    if c == 'R':
      break
    buf = buf & $c
    i.inc

  if not buf.startsWith(&"{ESC}["):
    raise ConsoleError.newException("getCursorPos() failed: input does not start with '\\x1b['")

  if scanf(buf[2..^1], "$i;$i", result.rows, result.cols):
    raise ConsoleError.newException("getCursorPos() failed: input format shouldb be 'n;n'")

proc showCursor*() =
  let output = &"{ESC}[?25h"
  if stdout.writeChars(output, 0, output.len) != output.len:
    raise ConsoleError.newException("showCursor() failed")

proc showCursor*(s: Stream) =
  let output = &"{ESC}[?25h"
  s.write(output)

proc hideCursor*() =
  let output = &"{ESC}[?25l"
  if stdout.writeChars(output, 0, output.len) != output.len:
    raise ConsoleError.newException("showCursor() failed")

proc hideCursor*(s: Stream) =
  let output = &"{ESC}[?25l"
  s.write(output)

proc getWindowSize*(): tuple[rows: int, cols: int] =
  var ws: WinSize

  if stdout.getFileHandle.ioctl(TIOCGWINSZ, ws.addr) == -1 or ws.col == 0:
    setCursorPos(999, 999)
    result = getCursorPos()
  else:
    result = (ws.row.int, ws.col.int)

proc enableSGRReverseVideo*(s: Stream) =
  let output = &"{ESC}[7m"
  s.write(output)

proc resetSGR*(s: Stream) =
  let output = &"{ESC}[m"
  s.write(output)

proc setColor*(s: Stream, color: int) =
  let output = &"{ESC}[{color}m"
  s.write(output)

proc setForegroundDefaultColor*(s: Stream) =
  s.setColor(39)

var orig_termios: Termios

proc disableRawMode*() {.noconv.} =
  if stdin.getFileHandle.tcSetAttr(TCSAFLUSH, orig_termios.addr) == -1:
    raise newException(NedError, "tcsetattr() failed")

proc enableRawMode*() =
  if stdin.getFileHandle.tcGetAttr(orig_termios.addr) == -1:
    raise newException(NedError, "tcgetattr() failed")

  addQuitProc(disableRawMode)

  var raw = orig_termios

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
