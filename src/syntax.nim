import strutils
import sequtils
import algorithm

import common
import console

const
  HL_NUMBERS* = (1 shl 0)
  HL_STRINGS* = (1 shl 1)

let
  HLDB* = @[
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
    NedSyntax(filetype: "python",
              filematch: @[".py"],
              keywords: @["and", "as", "assert", "break", "class", "continue", "def", "del",
                          "from", "for", "finally", "False", "escept", "else", "elif",
                          "global", "if", "import", "in", "is", "lambda", "None",
                          "nonlocal", "not", "or", "pass", "raise", "return", "True",
                          "try", "while", "with", "yield", "async",
                          "int|", "long|", "float|", "complex|", "list|", "tuple|", "bytes|",
                          "bytearray|", "set|", "dict|"],
              flags: HL_NUMBERS or HL_STRINGS,
              sline_comment_prefix: "#"),
  ]

proc is_separator(c: char): bool =
  result = c.isSpaceAscii()
  result = result or (c == '\0')
  result = result or (c in ",.()+-/*=~%<>[];")

proc nedUpdateSyntax*(row: var NedRow, syntax: var NedSyntax) =
  if row.hled:
    return

  row.hl = newSeqWith(row.render.len, nhNormal.uint8)
  row.hled = true

  if syntax == nil:
    return

  let scs = syntax.sline_comment_prefix

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

    if (syntax.flags and HL_STRINGS) != 0:
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


    if (syntax.flags and HL_NUMBERS) != 0:
      if (c.isDigit() and (prev_is_sep or prev_hl == nhNumber.uint8)) or
         (c == '.' and prev_hl == nhNumber.uint8):
        row.hl[i] = nhNumber.uint8
        i.inc
        prev_is_sep = false
        continue

    if prev_is_sep:
      var kwfound = false
      for keyword in syntax.keywords:
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

proc nedSyntaxToColor*(hl: uint8): int =
  case hl:
    of nhComment.uint8: return ccFgCyan.int
    of nhKeyword1.uint8: return ccFgYellow.int
    of nhKeyword2.uint8: return ccFgGreen.int
    of nhString.uint8: return ccFgMagenta.int
    of nhNumber.uint8: return ccFgRed.int
    of nhMatch.uint8: return ccFgBlue.int
    else: return 37

proc nedSelectSyntax*(filename: string): NedSyntax =
  result = nil
  if filename == "":
    return

  for j in 0..<HLDB.len:
    for i in 0..<HLDB[j].filematch.len:
      if not filename.endsWith(HLDB[j].filematch[i]):
        continue
      result = HLDB[j]
      return
