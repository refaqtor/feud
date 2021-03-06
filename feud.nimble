# Package

version     = "0.1.0"
author      = "genotrance"
description = "Fed Ep with UDitors"
license     = "MIT"

# Dependencies

requires "nim >= 0.19.0", "c2nim >= 0.9.14", "nimterop#v020"
requires "cligen >= 0.9.17", "winim >= 2.5.2", "xml >= 0.1.2"

import strutils

var
  dll = ".dll"
  exe = ".exe"
  flags = "--opt:speed"

when defined(Linux):
  dll = ".so"
  exe = ""
elif defined(OSX):
  dll = ".dylib"
  exe = ""

task cleandll, "Clean DLLs":
  for dir in @["plugins", "plugins/client", "plugins/server"]:
    for file in dir.listFiles():
      if dll in file:
        rmFile file

task clean, "Clean all":
  var
    exe =
      when defined(Windows):
        ".exe"
      else:
        ""

  rmFile "feud" & exe
  rmFile "feudc" & exe
  cleandllTask()

proc echoExec(cmd: string) =
  echo cmd
  exec cmd

proc stripDlls(path: string) =
  for file in listFiles(path):
    if dll in file:
      exec "strip -s " & file

proc buildDlls(path: string) =
  for file in listFiles(path):
    if file[^4 .. ^1] == ".nim":
      echo "Building " & file
      echoExec "nim c --app:lib " & flags & " " & file

proc execDlls(task: proc(path: string)) =
  for dir in ["plugins", "plugins/server", "plugins/client"]:
    task(dir)

task dll, "Build dlls":
  execDlls(buildDlls)
  if "debug" notin flags:
    execDlls(stripDlls)

task bin, "Build binaries":
  echoExec "nim c " & flags & " feudc"
  echoExec "nim c " & flags & " feud"
  if "debug" notin flags:
    echoExec "strip -s feudc" & exe
    echoExec "strip -s feud" & exe

task release, "Release build":
  dllTask()
  binTask()

task binary, "Release binary":
  flags = "-d:binary " & flags
  releaseTask()

task debug, "Debug build":
  flags = "--debugger:native --debuginfo -d:useGcAssert -d:useSysAssert --lineTrace:on"
  releaseTask()

task dbin, "Debug binaries":
  flags = "--debugger:native --debuginfo -d:useGcAssert -d:useSysAssert --lineTrace:on"
  binTask()

task test, "Tester":
  echoExec "nim tests/test.nims"