import std/tables
import std/logging
import std/asyncnet
import std/strutils
import std/asyncdispatch
import std/json
import std/times

import ws

import objects
import handlers
import triggers

proc parseKVString*(data: string): TableRef[string, string] =
    result = newTable[string, string]()
    for pair in data.split('&'):
        if not ('=' in pair):
            continue
        var splt = pair.split('=')
        if splt.len != 2:
            continue
        result[splt[0]] = splt[1]

proc handleRequest(server: Server, client: Client, data: string): Future[
        string] {.async.} =
    var tab = data.parseKVString()
    if not ("rq" in tab):
        return ""
    var rq = tab["rq"]
    if not (rq in rqHandlers):
        return ""

    var handler = rqHandlers[rq]
    for arg in handler.args:
        if not (arg in tab):
            return ""

    var ctx = Context(
        server: server,
        client: client,
        data: tab
    )
    return await handler.handler(ctx)

proc handleClient*(server: Server, client: Client) {.async.} =
    try:
        var greet = await client.receive()
        if greet != "Glad to meet you! :D":
            return

        while not server.closing:
            var data = await client.receive()
            client.ping = (now() - client.lastReceive).inMilliseconds
            client.lastReceive = now()
            
            if data.len == 0:
                break
            var resp = await server.handleRequest(client, data)
            await client.send(resp)

    except Exception as error:
        server.logger.log(lvlError, error.getStackTrace())
        server.logger.log(lvlError, error.msg)

    finally:
        if not client.player.isNil:
            server.notGameContext(client.player)
        client.socket.close()
        server.clients.del client.index


proc handleUDP*(server: Server) {.async.} =
    while not server.closing:
        var datagram = await server.udpSocket.recvFrom(1)
        var tab = datagram.data.parseKVString()
        if not ("tok" in tab):
            continue
        
        var token = tab["tok"]
        # We will assume that if token doesn't exist, it means it got removed by votekick
        if not (token in server.tokenToClient):
            await server.udpSocket.sendto(datagram.address, datagram.port, "&dropped=1")
            continue
        
        var client = server.tokenToClient[token]
        var context = Context(
            server: server, 
            client: client,
            data: tab
        )

        var resp = await RQHandleGame(context)
        if resp.len > 0:
            await server.udpSocket.sendTo(datagram.address, datagram.port, resp)


proc listen*(server: Server, host: string, port: int, handleTimers: bool) =
    server.socket.setSockOpt(OptReuseAddr, true)
    server.socket.bindAddr(Port(port), host)
    server.socket.listen()
    server.logger.log(lvlInfo, "TCP server listening at " & host & ":" & $port)

    if not server.udpSocket.isNil:
        server.udpSocket.setSockOpt(OptReuseAddr, true)
        server.udpSocket.bindAddr(Port(port), host)
        asyncCheck(server.handleUDP)
        server.logger.log(lvlInfo, "UDP server listening at " & host & ":" & $port)
    else:
        server.logger.log(lvlInfo, "UDP is disabled.")
    
    if handleTimers:
        asyncCheck handleTimers(server)
    else:
        server.logger.log(lvlWarn, "Server-Sided Triggers are disabled.")

proc accept*(server: Server) {.async.} =
    var socket = await server.socket.accept()

    var client = Client(
        socket: socket, 
        index: server.clientID, 
        player: nil,
        lastReceive: now()
    )
    server.clients[server.clientID] = client
    inc server.clientID
    if server.clientID == int.high:
        server.clientID = 0

    asyncCheck server.handleClient(client)

proc connectToAuthority*(server: Server, name, key: string): Future[
        bool] {.async.} =
    server.logger.log(lvlDebug, "Trying to connect to Authoritative Webserver.")
    if server.authoritativeServer.host == "":
        server.logger.log(lvlError, "Host is empty.")
        return false
    var prot = "ws://"
    if server.authoritativeServer.secure:
        prot = "wss://"

    var ws: WebSocket = nil
    try:
        ws = await newWebSocket(prot & server.authoritativeServer.host & "/server")
    except OSError:
        server.logger.log(lvlError, "Unable to connect to Authoritative Webserver, skipping.")
        server.authoritativeServer.host = ""
        return false

    var saddr = server.socket.getLocalAddr()
    await ws.send($( %* {
        "key": key,
        "name": name,
        "port": saddr[1].int
    }))

    var resp = parseJson(await ws.receiveStrPacket())
    if resp{"error"}.isNil:
        server.logger.log(lvlInfo, "Connected to Authoritative Webserver.")
        server.websocket = ws
        return true
    else:
        server.logger.log(lvlError, resp["error"].getStr())
        ws.close()
        return false

proc postStats*(server: Server) {.async.} =
    if server.websocket.isNil:
        raise IOError.newException("Websocket is not available.")
    
    await server.websocket.send($( %* {
        "rq": "updateStat",
        "tc": $server.clients.len
    }))
    var data = ""
    for i in 0..<6:
        data = await server.websocket.receiveStrPacket()
        if data.len != 0:
            break
    if data.len == 0:
        server.logger.log(lvlError, "Expected proper reply to `server.postStats`, got empty.")
        return
    var resp = parseJson(data)
    if resp{"approved"}.isNil:
        server.logger.log(lvlError, resp["error"].getStr())

proc runForever*(server: Server) {.async.} =
    server.logger.log(lvlInfo, "Accepting connections now.")
    try:
        while not server.closing:
            await server.accept()
    finally:
        server.socket.close()
        if not server.udpSocket.isNil:
            server.udpSocket.close()
        if not server.websocket.isNil:
            server.websocket.close()
        server.logger.log(lvlInfo, "Server has been closed.")
