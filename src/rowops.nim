import strutils
import common

proc nedRowCxToRx*(row: var NedRow, cx: int): int =
  result = 0
  for j in 0..<cx:
    if row.raw[j] == '\t':
      result += (NEDTABSTOP - 1) - (result mod NEDTABSTOP)
    result.inc

proc nedRowRxToCx*(row: var NedRow, rx: int): int =
  result = 0
  for cx in 0..<row.raw.len:
    if row.raw[cx] == '\t':
      result += (NEDTABSTOP - 1) - (result mod NEDTABSTOP)
    result.inc
    if result > rx:
      return cx

proc nedRowUpdate*(row: var NedRow) =
  row.render = ""
  for j in 0..<row.raw.len:
    let c = row.raw[j]
    if c == '\t':
      row.render.add(' ')
      while row.render.len mod NEDTABSTOP != 0:
        row.render.add(' ')
    else:
      row.render.add(row.raw[j])
  # Row is changed. We must re-highlight it.
  row.hled = false

proc nedRowInsertChar*(row: var NedRow, at: int, c: char) =
  var nat = at
  if at < 0 or at > row.raw.len:
    nat = row.raw.len
  row.raw.insert($c, nat)
  row.nedRowUpdate()

proc nedRowAppendString*(row: var NedRow, s: string) =
  row.raw.add(s)
  row.nedRowUpdate()

proc nedRowDelChar*(row: var NedRow, at: int) =
  if at < 0 or at >= row.raw.len:
    return
  row.raw.delete(at, at)
  row.nedRowUpdate()

proc nedRowDelChars*(row: var NedRow, start: int, last: int) =
  if start < 0 or start >= row.raw.len:
    return
  if last < 0 or last >= row.raw.len:
    return
  if start > last:
    return
  row.raw.delete(start, last)
  row.nedRowUpdate()
