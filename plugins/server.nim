import locks, os, strformat, strutils, tables

import "../src"/pluginapi

import ".."/wrappers/nng

type
  ServerCtx = ref object
    listen: string
    dial: string
    thread: Thread[tuple[pserver: ptr Server, listen, dial: string]]

  Server = object
    lock: Lock
    run: bool
    recvBuf: seq[string]
    sendBuf: seq[string]

proc getServer(plg: var Plugin): ptr Server =
  return cast[ptr Server](plg.pluginData)

proc monitorServer(tparam: tuple[pserver: ptr Server, listen, dial: string]) {.thread.} =
  var
    socket: nng_socket
    listener: nng_listener
    dialer: nng_dialer
    buf: cstring
    sz: cuint
    ret: cint
    run = true

  ret = nng_bus0_open(addr socket)
  doException  ret == 0, &"Failed to open bus socket: {ret}"

  if tparam.dial.len != 0:
    ret = socket.nng_dial(tparam.dial, addr dialer, 0)
    doException ret == 0, &"Failed to connect to {tparam.dial}: {ret}"
  else:
    ret = socket.nng_listen(tparam.listen, addr listener, 0)
    doException ret == 0, &"Failed to listen on {tparam.listen}: {ret}"

  while run:
    ret = socket.nng_recv(addr buf, addr sz, (NNG_FLAG_NONBLOCK or NNG_FLAG_ALLOC).cint)
    if ret == 0:
      if sz != 0:
        withLock tparam.pserver[].lock:
          tparam.pserver[].recvBuf.add $buf
      buf.nng_free(sz)
    elif ret == NNG_ETIMEDOUT:
      echo "Timed out"

    withLock tparam.pserver[].lock:
      for i in tparam.pserver[].sendBuf:
        ret = socket.nng_send(i.cstring, (i.len+1).cuint, NNG_FLAG_NONBLOCK.cint)
      if tparam.pserver[].sendBuf.len != 0:
        tparam.pserver[].sendBuf = @[]

    sleep(100)

    withLock tparam.pserver[].lock:
      run = tparam.pserver[].run

  if tparam.dial.len != 0:
    discard dialer.nng_dialer_close()
  else:
    discard listener.nng_listener_close()

  discard socket.nng_close()

proc initServer(plg: var Plugin) =
  var
    pserver = newShared[Server]()
    pserverCtx = getCtxData[ServerCtx](plg)

  plg.pluginData = cast[pointer](pserver)

  pserver[].lock.initLock()
  pserver[].run = true

  if pserverCtx[].listen.len == 0:
    if plg.ctx.cmdParam.len == 0:
      pserverCtx[].listen = "ipc:///tmp/feud"
    else:
      pserverCtx[].listen = plg.ctx.cmdParam[0]

  if pserverCtx[].dial.len == 0:
    if plg.ctx.cmdParam.len > 1:
      pserverCtx[].dial = plg.ctx.cmdParam[1]

  createThread(pserverCtx.thread, monitorServer, (pserver, pserverCtx[].listen, pserverCtx[].dial))

proc stopServer(plg: var Plugin) =
  var
    pserver = plg.getServer()
    pserverCtx = getCtxData[ServerCtx](plg)

  withLock pserver[].lock:
    pserver[].run = false

  pserverCtx.thread.joinThread()

  freeShared(pserver)

proc restartServer(plg: var Plugin) {.feudCallback.} =
  plg.stopServer()
  plg.initServer()

proc readServer(plg: var Plugin) =
  var
    pserver = plg.getServer()
    mode = ""

  withLock plg.ctx.pmonitor[].lock:
    mode = plg.ctx.pmonitor[].path

  withLock pserver[].lock:
    for i in pserver[].recvBuf:
      if mode == "server":
        discard plg.ctx.handleCommand(plg.ctx, $i)
      else:
        echo $i

    if pserver[].recvBuf.len != 0:
      pserver[].recvBuf = @[]

proc sendServer(plg: var Plugin) {.feudCallback.} =
  var
    pserver = plg.getServer()

  if plg.ctx.cmdParam.len != 0:
    withLock pserver[].lock:
      pserver[].sendBuf.add plg.ctx.cmdParam[0]

proc notifyClient(plg: var Plugin) =
  var
    pserver = plg.getServer()
    mode = ""

  withLock plg.ctx.pmonitor[].lock:
    mode = plg.ctx.pmonitor[].path

  if plg.ctx.cmdParam.len != 0:
    if mode == "server":
      withLock pserver[].lock:
        pserver[].sendBuf.add plg.ctx.cmdParam[0]

feudPluginLoad:
  plg.initServer()

feudPluginTick:
  plg.readServer()

feudPluginNotify:
  plg.notifyClient()

feudPluginUnload:
  plg.stopServer()
