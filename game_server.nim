import std/httpclient
import std/asyncnet
import std/net
import std/asyncdispatch
import std/logging
import std/tables

import ws

import game/objects
import game/server
import sconfig

proc postUpdateInterval(server: Server) {.async.} =
    try:
        while not server.websocket.isNil:
            await sleepAsync(10 * 1000)
            await server.postStats()
    except WebSocketClosedError:
        server.logger.log(lvlError, "WebSocket closed.")
    finally:
        server.websocket.close()
        server.websocket = nil

proc main() {.async.} =
    var udpSocket: AsyncSocket = nil
    if config.udpEnabled:
        udpSocket = newAsyncSocket(
            AF_INET,
            SOCK_DGRAM,
            IPPROTO_UDP
        )
    
    var server = Server(
        socket: newAsyncSocket(),
        udpSocket: udpSocket,
        authoritativeServer: (
            host: config.authorityServer.host, 
            secure: config.authorityServer.secure
        ),
        httpClient: newAsyncHttpClient(),
        rooms: newTable[int, Room]()
    )

    server.listen(config.ip, config.port, config.serverTriggerEnabled)
    if await server.connectToAuthority(config.serverName, config.authorityServer.apiKey):
        await server.postStats()
        asyncCheck postUpdateInterval(server)

    await server.runForever()

waitFor main()