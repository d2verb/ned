import strformat
import streams
import strutils
import strscans
import posix

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
