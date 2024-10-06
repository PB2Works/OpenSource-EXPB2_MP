import std/httpclient
import std/tables
import std/asyncnet
import std/logging
import std/xmltree
import std/xmlparser
import std/times
import std/strutils
import std/random
import std/asyncdispatch
import std/strtabs
import std/strformat

import ws

import constants
import qpack
import ../sconfig

type
    Client* = ref object
        socket*: AsyncSocket
        index*: int
        pckID* = 0
        lastReceive*: DateTime
        ping* = 0
        player*: Player

    PlayerFlagsEnum* = enum
        Developer
        Administrator
        Designer
        Tester
    PlayerFlags* = set[PlayerFlagsEnum]

    Player* = ref object
        login*, display*: string
        skins*: string
        flags*: PlayerFlags
        slot* = -1
        room* = -1
        token* = ""
        events* = ""
        extra* = ""  # Other data to be appended on the next request
        matchData* = newTable[string, string]()
        chatPrefix* = ""

        kills* = 0
        deaths* = 0

    Server* = ref object
        logger* = newConsoleLogger(fmtStr = "[$datetime $appname] [$levelname]: ")
        socket*: AsyncSocket
        udpSocket*: AsyncSocket
        httpClient*: AsyncHttpClient

        authoritativeServer* = (host: "", secure: false)
        clients* = initTable[int, Client]()
        tokenToClient* = initTable[string, Client]()
        closing* = false
        clientID* = 0
        websocket*: WebSocket = nil

        rooms*: TableRef[int, Room]

    Context* = ref object
        server*: Server
        client*: Client
        data*: TableRef[string, string]

    Room* = ref object
        id*: int
        lastLeave*: DateTime
        server*: Server
        clients* = initTable[int, Client]()
        title*, password*, mapID*: string
        modifications* = ""
        maxPing*, netcode*, gamemode*, maxPlayers*: int
        approved*, ranked*: bool
        spPoints* = 0
        mapdata* = ""
        fetched* = false
        fetching* = false
        refreshing* = false
        testID*: string
        masters*: seq[string] = @[]
        rngVars*: Table[string, tuple[generated: DateTime, value: string]]
        lastSpecial* = 0
        grenTick* = 0
        excluded*: seq[string] = @[]
        kickVotes* = initTable[string, seq[string]]()
        entityMaster* = -1
        rngValidFor* = RNG_VALID_FOR

        teamScores* = initTable[int, int]()
        teamWins* = initTable[int, int]()
        round* = 0

        restarting*: bool = false
        lastRoundEnd*: DateTime

        serverSidedTimers*: Table[int, SSTimer]
        serverSidedTriggers*: Table[int, SSTrigger]
        uidtoidmap* = initTable[string, int]()
        
        variables*: Table[string, string]

        chatReceiver*: SSTrigger
        talkerSlot*: int
        talkerMessage*: string
        messageIsTeam*: bool


    SSTAction* = ref object
        opcode*: int
        args*: seq[string]

    SSTrigger* = ref object
        id*: int
        uid*: string
        enabled*: bool
        maxCalls*: int
        actions*: seq[SSTAction] = @[]
    
    SSTimer* = ref object
        #id*: int
        enabled*: bool
        maxCalls*: int
        delay*: int
        callback*: SSTrigger
        tick* = 0
    
    TriggerContext* = ref object
        trigger*: SSTrigger
        room*: Room
        server*: Server
        actionID* = 0


proc colorMessage*(text: string, color: string): string {.inline.} =
    result = "<font color[eq]\"" & color & "\">" & text & "</font>"

proc toNum*(f: PlayerFlags): int {.inline.} = cast[int](f)
proc toPlayerFlags*(v: int): PlayerFlags {.inline.} = cast[PlayerFlags](v)

proc isMaster*(room: Room, player: Player): bool =
    if player.login in room.masters:
        return true
    else:
        return false

proc isAdmin*(player: Player): bool {.inline.} =
    return Administrator in player.flags

proc privelegeLevel*(room: Room, player: Player): int {.inline.} =
    if player.isAdmin:
        return 2
    elif room.isMaster(player):
        return 1
    else:
        return 0

proc isSpectator*(player: Player): bool {.inline.} =
    return player.slot < 0 # Will work as expected as long as context is in-game.


#######################################################################################################

proc `$`*(room: Room): string =
    return $(<>o(
        n = room.title,
        f = $room.id,
        t = $room.clients.len & " / " & $room.maxPlayers,
        p = if room.password != "": "yes" else: "no",
        m = room.mapID,
        a = if room.approved: "1" else: "0",
        g = $room.gamemode,
        s = if room.spPoints == 0: "-" else: $room.spPoints,
        q = "Description",
        nt = $room.netcode,
        ts = room.testID
    ))

proc sendGlobalChat*(room: Room, text: string) =
    for client in room.clients.values:
        client.player.events.add(";chat2|" & text)

proc playerJoin*(room: Room, player: Player) =
    for client in room.clients.values:
        client.player.events.add(";user_connect|" & $player.slot)
    room.sendGlobalChat(colorMessage(player.display, JOIN_LEAVE_COLOR) & " has connected.")

proc playerLeave*(room: Room, player: Player) =
    for client in room.clients.values:
        client.player.events.add(";user_disconnect|" & $player.slot)
    room.sendGlobalChat(colorMessage(player.display, JOIN_LEAVE_COLOR) & " has left the game.")

proc getSRNGValue*(room: Room, name, value: string): string =
    var deleting: seq[string]
    for (name, tup) in room.rngVars.pairs:
        if (now() - tup.generated).inMilliseconds > room.rngValidFor:
            deleting.add(name)

    for i in deleting:
        room.rngVars.del name

    if name in room.rngVars:
        return room.rngVars[name].value

    if "-" in value:
        var splt = value.split("-")
        if splt.len != 2:
            return "There must be 1 -"
        room.rngVars[name] = (
            generated: now(),
            value: $rand(splt[0].parseInt .. splt[1].parseInt)
        )
    elif "." in value:
        var splt = value.split(".")
        if splt.len != 2:
            return "There must be 1 ."
        var a = splt[0].parseFloat
        var b = splt[1].parseFloat
        room.rngVars[name] = (
            generated: now(),
            value: $(a + (b - a) * rand(1.0))
        )
    else:
        return "Unknown format."
    return room.rngVars[name].value

#######################################################################################################

proc findClientByLogin*(server: Server, login: string): Client =
    for client in server.clients.values:
        if not client.player.isNil:
            if client.player.login == login:
                return client
    return nil

###########################################################################################################

proc internalReceive(client: Client): Future[string] {.async.} =
    var bytes: seq[byte]
    while bytes.len < 4:
        var part = await client.socket.recv(4 - bytes.len)
        if part.len == 0:
            return ""
        for chara in part:
            bytes.add(chara.byte)
    var size = (bytes[2].int shl 8) or bytes[3].int
    var data = ""
    while data.len < size:
        var part = await client.socket.recv(size - data.len)
        if part.len == 0:
            return ""
        data.add(part)
    return data

proc receive*(client: Client): Future[string] {.async.} =
    var fut = client.internalReceive()

    var received = await fut.withTimeout(TCP_RECEIVE_TIMEOUT)
    if received:
        return fut.read
    else:
        return ""

proc send*(client: Client, data: string) {.async.} =
    var sending = ""

    var data = data
    data = data.replace("@", "[^at]")
    data = data.replace("~", "[^sw]")
    data = data.replace("`", "[^']")

    data = data & "/" & $client.pckID & "@"
    sending.add(((data.len and 0xFF000000) shr 24).chr)
    sending.add(((data.len and 0x00FF0000) shr 16).chr)
    sending.add(((data.len and 0x0000FF00) shr 8).chr)
    sending.add((data.len and 0x000000FF).chr)
    sending.add(data)
    await client.socket.send(sending)

    inc client.pckID
    if client.pckID == int.high:
        client.pckID = 0

##################################################################

proc doThingsWithMapdata*(ctx: Context, room: Room) =
    # top tier procedure name, i agree
    var mapdata = ""
    var uidtoidmap = initTable[string, int]()
    var serverSidedTriggers = initTable[int, SSTrigger]()
    var triggerUIDs: seq[string]

    proc noticeWontDo(text, fault: string) =
        room.sendGlobalChat(&"Server: {text}, Server-Sided objects will not be parsed.")
        room.sendGlobalChat(&"Server: {fault}")

    var processingTimers = initTable[int, XmlNode]()

    var tsc = initTable[string, int]()
    for node in parseXml("<r>" & room.mapdata.unqpack & "</r>"):
        var tag = node.tag
        if not (tag in tsc):
            tsc[tag] = -1
        tsc[tag] += 1
        
        var uid = node.attr("uid")
        var gid = tsc[tag]

        if uid.len == 0:
            mapdata.add($node)
            continue
        elif not uid.startsWith("#"):
            noticeWontDo("One of object UID does not start with #", uid & " " & $gid)
            return
        elif uid in uidtoidmap:
            noticeWontDo("There is DUPLICATE UID", uid)
            return

        uidtoidmap[uid] = gid

        case(node.tag)
        of "inf":
            if node.attr("mark") != "server_srng_validity":
                mapdata.add($node)
                continue
            try:
                var validFor = node.attr("forteam").parseInt
                room.rngValidFor = validFor
            except ValueError:
                continue
        of "trigger":
            triggerUIDs.add(uid)
            if node.attr("onserver") != "true":
                mapdata.add($node)
                continue
            var maxCalls = node.attr("maxcalls")
            var enabled = node.attr("enabled")
            if not (enabled in ["true", "false"]):
                noticeWontDo("Trigger does not have proper `enabled`", uid)
                return
            try:
                discard maxCalls.parseInt
            except ValueError:
                noticeWontDo("Invalid `maxcalls`.", uid)
                return
            
            var trigger = SSTrigger(
                id: gid,
                uid: uid,
                enabled: enabled == "true",
                maxCalls: maxCalls.parseInt
            )
            for i in 1..10:
                var action = node.attr &"a{i}"
                if action.len == 0:
                    noticeWontDo("One of trigger action is empty", uid)
                    return
                var parts = action.split("|")
                if parts.len < 3:
                    noticeWontDo("One of action has less than expected parameters", uid)
                    return
                try:
                    var op = parts[0].parseInt
                    var args = parts[1 .. ^1]
                    if (op == -1):
                        continue
                    trigger.actions.add(SSTAction(opcode: op, args: args))
                except ValueError:
                    noticeWontDo("One of opcode is not number", uid)
                    return
            serverSidedTriggers[gid] = trigger
            mapdata.add("<trigger />") # just balancing out ID's, lol...
        of "timer":
            processingTimers[gid] = node # We gotta do timers later after all triggers are parsed
        else:
            mapdata.add($node)
    var serverSidedTimers = initTable[int, SSTimer]()

    for gid, node in processingTimers.pairs:
        var uid = node.attr("uid")
        var enabled = node.attr("enabled")
        if not (enabled in ["true", "false"]):
            noticeWontDo("Timer does not have proper `enabled`.", uid)
            return
        try:
            var maxCalls = node.attr("maxcalls").parseInt
            var delay = node.attr("delay").parseInt
            var target = node.attr("target")

            if target == "-1":
                mapdata.add($node)
                continue

            if not (target in uidtoidmap):
                mapdata.add($node)
                continue

            if not (target in triggerUIDs):
                mapdata.add($node)
                continue

            var trigger = uidtoidmap[target]
            if not (trigger in serverSidedTriggers):
                mapdata.add($node)
                continue

            var timer = SSTimer(
                enabled: enabled == "true",
                maxCalls: maxCalls,
                delay: delay,
                callback: serverSidedTriggers[trigger]
            )
            serverSidedTimers[gid] = timer
            mapdata.add("""<timer target="-1" enabled="false" />""") # just balancing out ID's
        except ValueError:
            noticeWontDo("Timer does not have proper maxcalls/delay", uid)
            return
    
    room.mapdata = mapdata.qpack
    
    if serverSidedTimers.len == 0 and serverSidedTriggers.len > 0:
        room.sendGlobalChat("Server: There are triggers but NO timers to run them.")
        return
    if serverSidedTimers.len > 0 and serverSidedTriggers.len == 0:
        room.sendGlobalChat("Server: There are timers but NO triggers to execute by them.")
        return

    if serverSidedTimers.len == 0:
        return
    if config.serverTriggerEnabled:
        room.serverSidedTimers = serverSidedTimers
        room.serverSidedTriggers = serverSidedTriggers
        room.uidtoidmap = uidtoidmap
    else:
        room.sendGlobalChat("This map uses Server-Sided Triggers, but Server Hoster chose to have it disabled.")
        room.sendGlobalChat("So those Server-Sided Triggers will NOT be ran.")
    #room.sendGlobalChat("SST's:")
    #room.sendGlobalChat(&"Server Triggers: {serverSidedTriggers.len}")
    #room.sendGlobalChat(&"Server Timers: {serverSidedTimers.len}")