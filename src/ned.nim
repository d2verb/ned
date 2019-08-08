import termios
import strformat
import streams
import posix

const TIOCGWINSZ = 0x5413

proc isCntrl(c: cint): cint {.header: "ctype.h", importc: "iscntrl".}
proc ioctl[T](fd: cint, request: culong, argp: var T): cint {.importc, header: "<sys/ioctl.h>".}

type
  NedError = object of Exception
  NedConfig = object
    orig_termios: Termios
    screenrows: int
    screencols: int

  WinSize = object
    row: cushort
    col: cushort
    xpixel: cushort
    ypixel: cushort

var E: NedConfig

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

proc nedReadKey(): char =
  var c = '\0'
  try:
    stdin.newFileStream.read(c)
  except IOError:
    discard
  result = c

proc getWindowSize(): tuple[width: int, height: int] =
  var ws: WinSize
  if stdout.getFileHandle.ioctl(TIOCGWINSZ, ws.addr) == -1 or ws.col == 0:
    raise newException(NedError, "getWindowSize() failed")
  else:
    result = (ws.col.int, ws.row.int)

proc nedProcessKeypress() =
  var c = nedReadKey()
  case c:
    of ctrlKey('q'):
      quit()
    else:
      discard

proc nedClearScreen() {.noconv.} =
  # Clear screen
  stdout.write("\x1b[2J")
  # Reposition the cursor
  stdout.write("\x1b[H")

proc nedDrawRows() =
  for y in 0..<E.screenrows:
    stdout.write(&"~\r\n")

proc nedRefreshScreen() =
  nedClearScreen()
  nedDrawRows()
  stdout.write("\x1b[H")

proc nedInit() =
  (E.screenrows, E.screencols) = getWindowSize()

proc main() =
  enableRawMode()
  addQuitProc(nedClearScreen)
  nedInit()

  while true:
    nedRefreshScreen()
    nedProcessKeypress()

when isMainModule:
  main()
