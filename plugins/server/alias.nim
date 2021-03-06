import sets, strformat, strutils, tables

import "../../src"/pluginapi

type
  Aliases = ref object
    atable: Table[string, string]

proc getAliases(plg: Plugin): Aliases =
  return getCtxData[Aliases](plg)

proc setupAlias(plg: Plugin, alias: string) =
  var
    aliases = plg.getAliases()

  if not plg.callbacks.hasKey(alias):
    plg.cindex.incl alias
    plg.callbacks[alias] = proc(plg: Plugin, cmd: CmdData) =
      var
        command = aliases.atable[alias]

      if cmd.params.len != 0:
        command &= " " & cmd.params.join(" ")

      var
        ccmd = newCmdData(command)
      plg.ctx.handleCommand(plg.ctx, ccmd)

proc alias(plg: Plugin, cmd: CmdData) {.feudCallback.} =
  var
    aliases = plg.getAliases()

  if cmd.params.len == 0:
    var aout = ""

    for alias in aliases.atable.keys():
      aout &= &"{alias} = {aliases.atable[alias]}\n"

    if aout.len != 0:
      plg.ctx.notify(plg.ctx, aout[0 .. ^2])
  else:
    if cmd.params.len == 1 and cmd.params[0].len != 0:
      let
        alias = cmd.params[0]
      aliases.atable.del(alias)
      plg.cindex.excl alias
      plg.callbacks.del(alias)
    elif cmd.params.len == 2 and
      cmd.params[0].len != 0 and cmd.params[1].len != 0:
      let
        alias = cmd.params[0]
        val = cmd.params[1]
      aliases.atable[alias] = val
      plg.setupAlias(alias)
    else:
      plg.ctx.notify(plg.ctx, "Invalid syntax for alias")
      cmd.failed = true

feudPluginLoad:
  var
    aliases = plg.getAliases()

  if aliases.atable.len != 0:
    for alias in aliases.atable.keys():
      plg.setupAlias(alias)
