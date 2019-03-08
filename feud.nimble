# Package

version     = "0.1.0"
author      = "genotrance"
description = "Fed Ep with UDitors"
license     = "MIT"

bin = @["feud", "feudc"]

# Dependencies

requires "nim >= 0.19.0", "nimterop >= 0.1.0", "winim >= 2.5.2", "cligen >= 0.9.17", "nimdeps >= 0.1.0"

import strutils

task cleandll, "Clean DLLs":
  var
    dll = ".dll"

  when defined(Linux):
    dll = ".so"
  elif defined(OSX):
    dll = ".dylib"

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

task release, "Release build":
  exec "nim c -d:release feudc"
  exec "nim c -d:release feud"

task binary, "Release binary":
  exec "nim c -d:binary -d:release feud"

task debug, "Debug build":
  exec "nim c --debugger:native feud"