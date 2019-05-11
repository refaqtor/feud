import deques, os, sequtils, sets, strformat, strutils, tables, times

import "../.."/src/pluginapi
import "../.."/wrappers/fuzzy

const MAX_BUFFER = 8192

type
  Doc = ref object
    path: string
    docptr: pointer
    cursor: int
    syncTime: Time
    windows: HashSet[int]

  Docs = ref object
    doclist: seq[Doc]
    dirHistory: Deque[string]
    currDir: int

proc getDocs(plg: var Plugin): Docs =
  return getCtxData[Docs](plg)

proc getDocId(plg: var Plugin, winid = -1): int =
  var
    cmd = "getDocId"
  if winid != -1:
    cmd &= &" {winid}"
  result = plg.getCbIntResult(cmd, -1)

proc setDocId(plg: var Plugin, docid: int) =
  discard plg.ctx.handleCommand(plg.ctx, &"setDocId {docid}")

proc getDocPath(plg: var Plugin) {.feudCallback.} =
  var
    docs = plg.getDocs()
    docid = plg.getDocId()

  if docid != -1:
    plg.ctx.cmdParam = @[docs.doclist[docid].path]
  else:
    plg.ctx.cmdParam = @[""]

proc setCurrentDir(plg: var Plugin, dir: string) =
  var
    docs = plg.getDocs()

  let
    pdir = getCurrentDir()
  dir.setCurrentDir()
  let
    ndir = getCurrentDir()

  if pdir != ndir:
    if docs.currDir < docs.dirHistory.len-1:
      docs.dirHistory.shrink(fromLast = docs.dirHistory.len - docs.currDir - 1)

    docs.dirHistory.addLast(ndir)
    docs.currDir = docs.dirHistory.len - 1

proc findDocFromString(plg: var Plugin, srch: string): int =
  result = -1
  var
    docs = plg.getDocs()
    scores: seq[int]
    score: cint = 0

  # Exact match
  for i in 0 .. docs.doclist.len-1:
    let
      str = docs.doclist[i].path
    if srch == str:
      result = i
      break
    else:
      scores.add 0

  # File name.ext match
  if result == -1:
    for i in 0 .. docs.doclist.len-1:
      let
        str = docs.doclist[i].path.extractFilename()
      if srch == str:
        result = i
        break
      elif fuzzy_match(srch, str, score) and score > scores[i]:
          scores[i] = score

  # File name match
  if result == -1:
    for i in 0 .. docs.doclist.len-1:
      let
        str = docs.doclist[i].path.splitFile().name
      if srch == str:
        result = i
        break
      elif fuzzy_match(srch, str, score) and score > scores[i]:
          scores[i] = score

  # Fuzzy
  if result == -1:
    let
      maxf = max(scores)
    if maxf > 100:
      result = scores.find(maxf)

proc findDocFromParam(plg: var Plugin, param: string): int =
  var
    docs = plg.getDocs()

  result =
    if param.len == 0:
      plg.getDocId()
    else:
      plg.findDocFromString(param)

  if result < 0:
    try:
      result = parseInt(param)
    except ValueError:
      discard

  if result > docs.doclist.len-1:
    result = -1

proc switchDoc(plg: var Plugin, docid: int) =
  var
    docs = plg.getDocs()
    currDoc = plg.getDocId()
    currWindow = plg.getCbIntResult("getCurrentWindow", -1)

  if docid < 0 or docid > docs.doclist.len-1 or currWindow < 0 or currDoc < 0 or (docid == currDoc and docid != 0):
    return

  docs.doclist[currDoc].cursor = plg.ctx.msg(plg.ctx, SCI_GETCURRENTPOS)
  discard plg.ctx.msg(plg.ctx, SCI_ADDREFDOCUMENT, 0, docs.doclist[currDoc].docptr)
  docs.doclist[currDoc].windows.excl currWindow

  docs.doclist[docid].windows.incl currWindow
  discard plg.ctx.msg(plg.ctx, SCI_SETDOCPOINTER, 0, docs.doclist[docid].docptr)
  discard plg.ctx.msg(plg.ctx, SCI_RELEASEDOCUMENT, 0, docs.doclist[docid].docptr)
  discard plg.ctx.msg(plg.ctx, SCI_GOTOPOS, docs.doclist[docid].cursor)

  plg.setDocId(docid)

  discard plg.ctx.handleCommand(plg.ctx, &"setTitle {docs.doclist[docid].path}")

  let
    lexer = plg.getCbResult(&"setLexer {docs.doclist[docid].path}")
  if lexer.len != 0:
    discard plg.ctx.handleCommand(plg.ctx, &"setTheme {lexer}")

  if plg.getCbResult("get file:fileChdir") == "true":
    if docs.doclist[docid].path notin ["Notifications", "New document"]:
      docs.doclist[docid].path.parentDir().setCurrentDir()
    else:
      docs.dirHistory.peekFirst().setCurrentDir()

  if docid == 0:
    let
      length = plg.ctx.msg(plg.ctx, SCI_GETLENGTH)
    discard plg.ctx.msg(plg.ctx, SCI_GOTOPOS, length)

  discard plg.ctx.handleCommand(plg.ctx, "runHook postFileSwitch")

proc loadFileContents(plg: var Plugin, path: string) =
  if not fileExists(path):
    return

  discard plg.ctx.msg(plg.ctx, SCI_CLEARALL)
  var
    buffer = newString(MAX_BUFFER)
    bytesRead = 0
    f = open(path)

  while true:
    bytesRead = readBuffer(f, addr buffer[0], MAX_BUFFER)
    if bytesRead == MAX_BUFFER:
      discard plg.ctx.msg(plg.ctx, SCI_ADDTEXT, bytesRead, addr buffer[0])
    else:
      if bytesRead != 0:
        buffer.setLen(bytesRead)
        discard plg.ctx.msg(plg.ctx, SCI_ADDTEXT, bytesRead, addr buffer[0])
      break
  f.close()

  discard plg.ctx.msg(plg.ctx, SCI_SETSAVEPOINT)
  discard plg.ctx.handleCommand(plg.ctx, "runHook postFileLoad")

proc newDoc(plg: var Plugin) {.feudCallback.} =
  var
    docs = plg.getDocs()
    doc = new(Doc)

  doc.windows.init()
  doc.path = "New document"
  doc.docptr = plg.ctx.msg(plg.ctx, SCI_CREATEDOCUMENT, 0.toPtr).toPtr

  docs.doclist.add doc

  plg.switchDoc(docs.doclist.len-1)

proc open(plg: var Plugin) {.feudCallback.} =
  proc getDirPat(path: string): tuple[dir, pat: string] =
    if "/" in path or "\\" in path:
      result.dir = path.parentDir()
      result.pat = path.replace(result.dir, "")
      if result.pat[0] in ['\\', '/']:
        result.pat = result.pat[1 .. ^1]
    else:
      result.dir = getCurrentDir()
      result.pat = path

  proc openRec(plg: var Plugin, path: string) =
    var
      (dir, pat) = path.getDirPat()
    plg.ctx.cmdParam = @[]
    for d in dir.walkDirRec(yieldFilter={pcDir}):
      if ".git" notin d:
        if "*" in pat or "?" in pat or fileExists(d/pat):
          plg.ctx.cmdParam.add d/pat
    plg.open()

  proc openFuzzy(plg: var Plugin, path: string) =
    var
      (dir, pat) = path.getDirPat()
      bestscore = 0
      bestmatch = ""
      score: cint = 0
    plg.ctx.cmdParam = @[]
    for f in dir.walkDirRec():
      if ".git" notin f:
        if fuzzy_match(pat, f.extractFilename(), score):
          if score > bestscore:
            bestscore = score
            bestmatch = f
    if bestmatch.len != 0:
      if " " in bestmatch or "\t" in bestmatch:
        bestmatch = '"' & bestmatch & '"'
      discard plg.ctx.handleCommand(plg.ctx, &"togglePopup open {bestmatch}")

  var
    sel = plg.getSelection()
    params = plg.getParam()
    selected = false

  if params.len == 0 and sel.len != 0:
    params.add sel
    selected = true

  if params.len == 0:
    discard plg.ctx.handleCommand(plg.ctx, "togglePopup open")

  for param in params:
    defer:
      selected = false

    var
      paths = param.parseCmdLine()
      recurse = false
      fuzzy = false

    if "-r" in paths:
      recurse = true
      paths.delete(paths.find("-r"))

    if "-f" in paths:
      fuzzy = true
      paths.delete(paths.find("-f"))

    if paths.len == 0 and sel.len != 0:
      paths.add sel
      selected = true

    let
      togOpen = "togglePopup open" & (if recurse: " -r" elif fuzzy: " -f" else: "")
    if paths.len == 0:
      discard plg.ctx.handleCommand(plg.ctx, togOpen)

    for path in paths:
      let
        path = path.strip()

      if "*" in path or "?" in path:
        if not recurse:
          plg.ctx.cmdParam = @[]
          for spath in path.walkPattern():
            plg.ctx.cmdParam.add spath.expandFilename()
          plg.open()
        else:
          plg.openRec(path)
      elif path.len != 0:
        let
          docid = plg.findDocFromParam(path)
        if docid > -1:
          plg.switchDoc(docid)
        elif path.dirExists():
          plg.ctx.cmdParam = @[]
          for kind, file in path.walkDir():
            if kind == pcFile:
              plg.ctx.cmdParam.add file.expandFilename()
          plg.open()
        else:
          if not fileExists(path):
            if recurse:
              plg.openRec(path)
            elif fuzzy:
              plg.openFuzzy(path)
            else:
              if selected:
                discard plg.ctx.handleCommand(plg.ctx, togOpen)
              else:
                plg.ctx.notify(plg.ctx, &"File does not exist: {path}")
          else:
            var
              path = path.expandFilename()
              docs = plg.getDocs()
              info = path.getFileInfo()
              doc = new(Doc)

            doc.windows.init()
            doc.path = path
            doc.docptr = plg.ctx.msg(plg.ctx, SCI_CREATEDOCUMENT, info.size.toPtr).toPtr
            doc.syncTime = path.getLastModificationTime()

            docs.doclist.add doc

            plg.switchDoc(docs.doclist.len-1)

            plg.loadFileContents(path)

            discard plg.ctx.msg(plg.ctx, SCI_GOTOPOS, 0)

proc save(plg: var Plugin) {.feudCallback.} =
  var
    docs = plg.getDocs()
    currDoc = plg.getDocId()

  if docs.doclist.len != 0 and currDoc > 0:
    let
      doc = docs.doclist[currDoc]

    if doc.path == "New document":
      plg.ctx.notify(plg.ctx, &"Save new document using saveAs <fullpath>")
      return

    discard plg.ctx.msg(plg.ctx, SCI_SETREADONLY, 1.toPtr)
    defer:
      discard plg.ctx.msg(plg.ctx, SCI_SETREADONLY, 0.toPtr)

    let
      data = cast[cstring](plg.ctx.msg(plg.ctx, SCI_GETCHARACTERPOINTER))

    try:
      var
        f = open(doc.path, fmWrite)
      f.write(data)
      f.close()
      plg.ctx.notify(plg.ctx, &"Saved {doc.path}")

      doc.syncTime = doc.path.getLastModificationTime()

      discard plg.ctx.msg(plg.ctx, SCI_SETSAVEPOINT)
      discard plg.ctx.handleCommand(plg.ctx, &"setTitle {doc.path}")
    except:
      plg.ctx.notify(plg.ctx, &"Failed to save {doc.path}")

proc saveAs(plg: var Plugin) {.feudCallback.} =
  if plg.ctx.cmdParam.len != 0:
    var
      name = plg.ctx.cmdParam[0].strip()
      docs = plg.getDocs()
      doc = docs.doclist[plg.getDocId()]

    if name.len != 0:
      doc.path = name.expandFilename()

      if plg.getCbResult("get file:fileChdir") == "true":
        doc.path.parentDir().setCurrentDir()

      plg.save()

proc list(plg: var Plugin) {.feudCallback.} =
  var
    lout = ""
    docs = plg.getDocs()

  for i in 0 .. docs.doclist.len-1:
    lout &= &"{i}: {docs.doclist[i].path.extractFilename()}\n"

  plg.ctx.notify(plg.ctx, lout[0..^2])

proc close(plg: var Plugin) {.feudCallback.} =
  var
    docs = plg.getDocs()
    params =
      if plg.ctx.cmdParam.len != 0:
        plg.getParam()
      else:
        @[""]

  for param in params:
    var
      docid = plg.findDocFromParam(param)
      currDoc = plg.getDocId()

    if docid > 0 and currDoc > -1:
      if docid == currDoc:
        if docid == docs.doclist.len-1:
          plg.switchDoc(docid-1)
        else:
          plg.switchDoc(docid+1)

      if docs.doclist[docid].windows.len == 0:
        discard plg.ctx.msg(plg.ctx, SCI_RELEASEDOCUMENT, 0, docs.doclist[docid].docptr)
        docs.doclist.delete(docid)
        currDoc = plg.getDocId()
        if docid < currDoc:
          plg.setDocId(currDoc-1)

proc closeAll(plg: var Plugin) {.feudCallback.} =
  var
    docs = plg.getDocs()

  while docs.doclist.len != 1:
    plg.ctx.cmdParam = @[$(docs.doclist.len-1)]
    plg.close()

proc unload(plg: var Plugin) {.feudCallback.} =
  var
    docs = plg.getDocs()
    params =
      if plg.ctx.cmdParam.len != 0:
        plg.getParam()
      else:
        @[]

  for param in params:
    var
      winid: int
    try:
      winid = param.parseInt()
    except:
      winid = -1

    if winid != -1:
      let
        docid = plg.getDocId(winid)

      if docid < docs.doclist.len and docid > -1:
        discard plg.ctx.msg(plg.ctx, SCI_ADDREFDOCUMENT, 0, docs.doclist[docid].docptr, windowID=winid)
        docs.doclist[docid].windows.excl winid

        discard plg.ctx.msg(plg.ctx, SCI_SETDOCPOINTER, 0, nil, windowID=winid)

proc next(plg: var Plugin) {.feudCallback.} =
  var
    docs = plg.getDocs()

  if docs.doclist.len != 1:
    var
      docid = plg.getDocId()
    docid += 1
    if docid == docs.doclist.len:
      docid = 0

    plg.switchDoc(docid)

proc prev(plg: var Plugin) {.feudCallback.} =
  var
    docs = plg.getDocs()

  if docs.doclist.len != 1:
    var
      docid = plg.getDocId()
    docid -= 1
    if docid < 0:
      docid = docs.doclist.len-1

    plg.switchDoc(docid)

proc last(plg: var Plugin) {.feudCallback.} =
  var
    docs = plg.getDocs()

  var
    last = plg.getCbIntResult("getLastId", -1)
  if last > docs.doclist.len-1:
    last = 0

  plg.switchDoc(last)

proc reload(plg: var Plugin) {.feudCallback.} =
  var
    docs = plg.getDocs()
    docid = plg.getDocId()
    doc = docs.doclist[docid]

  if docid > 0:
    plg.loadFileContents(doc.path)

    doc.syncTime = doc.path.getLastModificationTime()

    plg.ctx.notify(plg.ctx, &"Reloaded {doc.path}")

proc reloadAll(plg: var Plugin) {.feudCallback.} =
  var
    docs = plg.getDocs()

  plg.reload()
  if docs.doclist.len != 2:
    for i in 0 .. docs.doclist.len-1:
      plg.next()
      plg.reload()

proc reloadIfChanged(plg: var Plugin) {.feudCallback.} =
  var
    docs = plg.getDocs()
    docid = plg.getDocId()
    doc = docs.doclist[docid]

  if doc.path.fileExists() and doc.syncTime < doc.path.getLastModificationTime():
    if plg.ctx.msg(plg.ctx, SCI_GETMODIFY) == 0:
      plg.reload()
    else:
      plg.ctx.notify(plg.ctx, &"File '{doc.path.extractFilename()}' with unsaved modifications changed behind the scenes")

proc cd(plg: var Plugin) {.feudCallback.} =
  var
    docs = plg.getDocs()

  if plg.ctx.cmdParam.len != 0:
    if plg.ctx.cmdParam[0].len != 0:
      let
        path = plg.ctx.cmdParam[0].strip()

      if path.dirExists():
        plg.setCurrentDir(path)
      elif path.fileExists():
        plg.setCurrentDir(path.parentDir())
      elif path == "$":
        var
          docid = plg.getDocId()

        if docid > -1 and docid < docs.doclist.len:
          plg.ctx.cmdParam = @[docs.doclist[docid].path]
          plg.cd()
      elif path == "-":
        if docs.currDir != 0:
          docs.currDir -= 1
          docs.dirHistory[docs.currDir].setCurrentDir()
      elif path == "+":
        if docs.currDir < docs.dirHistory.len-1:
          docs.currDir += 1
          docs.dirHistory[docs.currDir].setCurrentDir()
      else:
        plg.ctx.notify(plg.ctx, "Directory doesn't exist: " & path)
        return

  plg.ctx.notify(plg.ctx, "Current directory: " & getCurrentDir())

feudPluginDepends(["filetype", "theme", "window"])

feudPluginLoad:
  var
    docs = plg.getDocs()

  if docs.doclist.len == 0:
    var
      notif = new(Doc)
    notif.windows.init()
    notif.path = "Notifications"
    notif.docptr = plg.ctx.msg(plg.ctx, SCI_GETDOCPOINTER, windowID=0).toPtr
    notif.windows.incl 0

    docs.doclist.add notif
    plg.setDocId(0)

    docs.dirHistory = initDeque[string]()
    docs.dirHistory.addLast(getCurrentDir())

  discard plg.ctx.handleCommand(plg.ctx, "hook preCloseWindow unload")
  discard plg.ctx.handleCommand(plg.ctx, "hook onWindowActivate reloadIfChanged")
  discard plg.ctx.handleCommand(plg.ctx, "hook postFileSwitch reloadIfChanged")
  discard plg.ctx.handleCommand(plg.ctx, "hook postNewWindow open 0")
