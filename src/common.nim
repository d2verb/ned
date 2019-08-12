const
  NEDTABSTOP* = 4

# All ned types
type
  NedError* = object of Exception

  # for syntax.nim  
  NedSyntax* = ref object
    filetype*: string
    filematch*: seq[string]
    keywords*: seq[string]
    flags*: int
    sline_comment_prefix*: string

  NedHighlight* = enum
    nhNormal = 0
    nhComment
    nhKeyword1
    nhKeyword2
    nhString
    nhNumber
    nhMatch
    
  # for rowops.nim
  NedRow* = ref object
    raw*: string
    render*: string
    hl*: seq[uint8]
    hled*: bool # Is this row highlighted?
    
  # for ned.nim
  NedConfig* = object
    rx*: int
    cx*: int
    cy*: int
    screenrows*: int
    screencols*: int
    rows*: seq[NedRow]
    rowoff*: int
    coloff*: int
    filename*: string
    statusmsg*: string
    statusmsg_time*: int64
    dirty*: bool
    saved_hl_line*: int
    saved_hl*: seq[uint8]
    syntax*: NedSyntax

  NedKey* = enum
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
