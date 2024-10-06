import std/json
import std/random
import std/tables
import std/asyncdispatch
import std/httpclient
import std/strutils
import std/xmltree
import std/xmlparser
import std/strtabs
import std/times
import std/logging
import std/re

import objects
import qpack
import constants
import triggers
import ../sconfig

randomize()

type Handler* = object
    handler*: proc(ctx: Context): Future[string] {.async.}
    args*: seq[string]

var rqHandlers* = initTable[string, Handler]()

proc registerHandler(name: string, args: seq[string], hand: proc(
        ctx: Context): Future[string] {.async.}) =
    rqHandlers[name] = Handler(
        handler: hand,
        args: args
    )

proc notGameContext*(server: Server, player: Player) =
    if player.room == -1:
        return
    var room = server.rooms[player.room]
    room.playerLeave(player)
    room.clients.del player.slot
    room.lastLeave = now()
    if player.token in server.tokenToClient:
        server.tokenToClient.del player.token
    player.kills = 0
    player.deaths = 0
    player.slot = -1
    player.room = -1


registerHandler("login", @["tok", "v", "h"], proc(ctx: Context): Future[
        string] {.async.} =
    var token = ctx.data["tok"]

    var login, display, skins = ""
    var flags = 0

    if token == "0":
        if config.guestsEnabled:
            login = ".guest"
            display = "Guest-" & $rand(0..99999)
            skins = $sample(USABLE_GUEST_SKINS)
            skins.add("|" & skins)
        else:
            return "[SERVER] This server has guests disabled."
    else:
        if ctx.server.authoritativeServer.host == "":
            return "[SERVER] Webhost is invalid."
        try:
            var response = ""
            var prot = "http://"
            if ctx.server.authoritativeServer.secure:
                prot = "https://"
            var url = prot & ctx.server.authoritativeServer.host & "/token.php"
            try:
                response = await ctx.server.httpClient.postContent(url,
                        body = "rq=extract&tok=" & token)
            except: # We try again
                response = await ctx.server.httpClient.postContent(url,
                        body = "rq=extract&tok=" & token)

            if (response.len > "error|".len) and (response[0..<(
                    "error|".len)] == "error|"):
                return response["error".len ..< response.len]
            if (response.len > "ok|".len) and (response[0..<("ok|".len)] != "ok|"):
                return "Unexpected response."
            var node = parseJson(response["ok|".len .. ^1])
            login = node[0].getStr()
            display = node[1].getStr()
            skins = node[2].getStr()
            flags = node[3].getInt()
            if not ctx.server.findClientByLogin(login).isNil:
                return "One-Account-Multiple-Session is not allowed."
        except Exception as Er:
            ctx.server.logger.log(lvlError, Er.getStackTrace())
            ctx.server.logger.log(lvlError, Er.msg)
            return "Something went wrong when extracting token."

    var player = Player(
        login: login,
        display: display,
        skins: skins,
        flags: flags.toPlayerFlags
    )
    if Developer in player.flags:
        player.chatPrefix = DEVELOPER_PREFIX
    elif Administrator in player.flags:
        player.chatPrefix = ADMIN_PREFIX
    elif Designer in player.flags:
        player.chatPrefix = DESIGNER_PREFIX
    elif Tester in player.flags:
        player.chatPrefix = TESTER_PREFIX

    ctx.client.player = player
    return "ok|" & player.display.replace("|", "[^I]") & "|" & player.skins & "||"
)

registerHandler("game_make", @["maxplayers", "mmap", "ttype", "gn", "netcode",
        "fpss", "mods", "ranked", "att", "test"], proc(ctx: Context): Future[
        string] {.async.} =
    if ctx.client.player.isNil:
        return
    ctx.server.notGameContext(ctx.client.player)

    var title = ctx.data["gn"]
    var password = ctx.data["att"]
    var mapID = ctx.data["mmap"]
    var modifications = ctx.data["mods"]
    var testID = ctx.data["test"]
    #var ranked = ctx.data["ranked"] == "true"

    var maxping = 1000
    var dnetcode = 0
    var dMaxPlayers = 8
    var dgamemode = 1
    try:
        maxping = ctx.data["fpss"].parseInt
        dnetcode = ctx.data["netcode"].parseInt
        dmaxPlayers = ctx.data["maxplayers"].parseInt
        dgamemode = ctx.data["ttype"].parseInt
    except ValueError:
        return ""

    var rooms = ctx.server.rooms
    var roomID = 0
    while roomID in rooms:
        roomID += 1
    var room = Room(
        id: roomID,
        server: ctx.server,
        lastLeave: now(),
        title: title,
        password: password,
        mapID: mapID,
        maxPing: maxping,
        netcode: dnetcode,
        gamemode: dgamemode,
        maxPlayers: dmaxPlayers,
        approved: false,
        ranked: false,
        lastRoundEnd: now(),
        testID: testID,
        serverSidedTriggers: initTable[int, SSTrigger](),
        serverSidedTimers: initTable[int, SSTimer]()
    )
    rooms[roomID] = room

    for match in findAll(modifications, re"-(\w*?):(\w*?)\."):
        modifications = modifications.replace(match, "")
        var pair = match[1 ..< ^1].split(":")
        var key = pair[0].strip(chars = {' '})
        var value = pair[1].strip(chars = {' '})
        case key
            of "owners":
                var masters = value.split(",")
                for master in masters:
                    room.masters.add(master.strip(chars = {' '}))
            else:
                ctx.client.player.events.add(
                        ";chat2|Server: Invalid modification key '" & key & "'")

    room.modifications = modifications
    if ctx.client.player.login != ".guest":
        room.masters.add(ctx.client.player.login)
    return "$<jrm to=\"" & $roomID & "\" />"
)

registerHandler("game_list", @["gl_gamename", "gl_mapid", "gl_mode",
        "gl_public", "gl_approved", "gl_ranked", "gl_hf"], proc(
        ctx: Context): Future[string] {.async.} =
    if ctx.client.player.isNil:
        return
    ctx.server.notGameContext(ctx.client.player)

    var rooms = ctx.server.rooms

    var deleting: seq[int]
    for (id, room) in rooms.pairs:
        if room.clients.len != 0:
            continue
        if (now() - room.lastLeave).inMilliseconds >= MATCH_DELETE_AFTER:
            deleting.add(id)

    for id in deleting:
        rooms.del id

    result = "$<st />"
    for room in rooms.values:
        if ctx.client.player.login in room.excluded:
            continue
        elif (ctx.data["gl_gamename"] != "any") and (room.title != ctx.data[
                "gl_gamename"]):
            continue
        elif (ctx.data["gl_mapid"] != "any") and (room.mapID != ctx.data["gl_mapid"]):
            continue
        elif (ctx.data["gl_mode"] != "6") and ($room.gamemode != ctx.data["gl_mode"]):
            continue
        elif (ctx.data["gl_public"] == "1") and (room.password != ""):
            continue
        elif (ctx.data["gl_approved"] == "1") and (not room.approved):
            continue
        elif (ctx.data["gl_approved"] == "2") and (room.approved):
            continue
        elif (ctx.data["gl_ranked"] == "1") and (not room.ranked):
            continue
        elif (ctx.data["gl_ranked"] == "3") and (room.ranked):
            continue
        elif (ctx.data["gl_hf"] == "1") and (room.clients.len == room.maxPlayers):
            continue
        result.add($room)
)

proc JGEMessage(text: string): string =
    return "&myid=-1&msg=" & text

proc upgradeXml*(mapdata: string): string =
    var tree = ("<r>" & mapdata & "</r>").parseXml
    for element in tree:
        if element.tag != "trigger":
            result.add($element)
            continue
        var attrs = element.attrs
        for i in 1..10:
            var typ = attrs.getOrDefault("actions_" & $i & "_type", "-1")
            var argA = attrs.getOrDefault("actions_" & $i & "_targetA", "")
            var argB = attrs.getOrDefault("actions_" & $i & "_targetB", "")
            attrs.del "actions_" & $i & "_type"
            attrs.del "actions_" & $i & "_targetA"
            attrs.del "actions_" & $i & "_targetB"
            attrs["a" & $i] = typ & "|" & argA & "|" & argB
        result.add($element)

proc getMapdata*(server: Server, map_id: string): Future[string] {.async.} =
    var mapFile = "./maps/" & map_id & ".xml"
    
    try:
        result = mapFile.readFile

        if "actions_1_type" in result:
            result = upgradeXml(result)
            mapFile.writeFile result
    
        result = result.qpack
    except IOError:
        result = "<not_published />"
    
    if result == "<not_published />" and server.authoritativeServer.host != "":
        var prot = "http://"
        if server.authoritativeServer.secure:
            prot = "https://"
        var url = prot & server.authoritativeServer.host & "/mapdata"
        try:
            result = await server.httpClient.postContent(url, body = "mapID=" & map_id)
        except: # we try again
            result = await server.httpClient.postContent(url, body = "mapID=" & map_id)

registerHandler("jg", @["room", "pass", "rdy"], proc(ctx: Context): Future[
        string] {.async.} =
    if ctx.client.player.isNil:
        return
    var rooms = ctx.server.rooms
    if ctx.client.player.room in rooms:
        var room = rooms[ctx.client.player.room]
        return (
            "&events=&lastid=0&started=true" &
            "&netcode=" & $room.netcode &
            "&token=" & $ctx.client.player.token
        )
    var room: Room
    var isSpectating: bool
    try:
        room = rooms[ctx.data["room"].parseInt]
    except KeyError:
        return JGEMessage("Match doesn't exist.")
    except ValueError:
        return JGEMessage("Unable to parse parameter.")
    try:
        isSpectating = ctx.data["myid"] == "-2"
    except ValueError:
        return # no.

    if ctx.client.player.login in room.excluded:
        return # ABSOLUTELY NOT.

    #echo "isSpectating: ", isSpectating
    if room.password != ctx.data["pass"]:
        return JGEMessage("Password is incorrect.")
    elif (not isSpectating) and (room.clients.len == room.maxPlayers):
        return JGEMessage("Match is full.")
    var haveFetched = false
    if not room.fetched:
        if room.fetching:
            return JGEMEssage("Map is being fetched, please come back later.")
        room.fetching = true
        try:
            room.mapdata = await ctx.server.getMapdata(room.mapID)
        except Exception as Er:
            ctx.server.logger.log(lvlError, Er.getStackTrace())
            ctx.server.logger.log(lvlError, Er.msg)
            rooms.del room.id
            return JGEMessage("Something went wrong while fetching mapdata.")
        if "<not_published />" in room.mapdata:
            rooms.del room.id
            return JGEMessage("Map isn't published.")
        room.fetched = true
        room.fetching = false
        haveFetched = true

    var slot: int
    if not isSpectating: # Normal slots, starting from 0
        slot = 0
        while slot in room.clients:
            slot += 1
    else: # We give spectators slots, like normal players, but just negative starting from -1. (Still debating whether there are benefits to giving diff slots to diff spectators)
        slot = -1
        while slot in room.clients:
            slot -= 1

    room.clients[slot] = ctx.client
    ctx.client.player.room = room.id
    ctx.client.player.slot = slot

    if haveFetched:
        doThingsWithMapdata(ctx, room)

    var token = ""
    while true:
        token = ""
        for i in 0..<20:
            token.add(sample("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        if not (token in ctx.server.tokenToClient):
            break

    ctx.client.player.token = token
    ctx.server.tokenToClient[token] = ctx.client

    room.playerJoin(ctx.client.player)

    return (
        "&myid=" & $(if ctx.client.player.isSpectator: -2 else: slot) &
        "&events=&lastid=0&maxplayers=" & $room.maxplayers &
        "&mptype=" & $room.gamemode & "&fpss=" & $room.maxPing &
        "&mods=" & room.modifications &
        "&mapid=" & room.mapID &
        "&mapdata=" & room.mapdata &
        "&ranked=" & (if room.ranked: "1" else: "0") &
        "&approved=" & (if room.approved: "1" else: "0") &
        "&started=true"
    )
)

proc handleVoteKick*(server: Server, room: Room, kicker: Player, victim: Player) =
    var kickerPrivelege = room.privelegeLevel(kicker)
    var victimPrivelege = room.privelegeLevel(victim)

    if kicker.isSpectator or victim.isSpectator:
        return # No.

    if (
        (kickerPrivelege < victimPrivelege) or
        (kickerPrivelege == victimPrivelege and kickerPrivelege != 0)
    ):
        if not (victim.login in room.kickVotes):
            room.kickVotes[victim.login] = @[]
        var kickers = room.kickVotes[victim.login]
        if kicker.login in kickers:
            return
        kickers.add(kicker.login)
        room.kickVotes[victim.login] = kickers # Setting key to copy...
        room.sendGlobalChat(
            color_message(kicker.display, SERVER_YELLOW) & " voted to exclude" &
            " Match Owner " & color_message(victim.display, SERVER_YELLOW) &
            ". Impossible to exclude Match Owner from their own match. " &
            "( " & $kickers.len & " )"
        )

    elif kickerPrivelege > 0: # is either master, or admin
        room.kickVotes.del victim.login
        room.excluded.add(victim.login)
        room.sendGlobalChat(
            "Match owner " & color_message(kicker.display, SERVER_YELLOW) &
            " excluded player " & color_message(victim.display, SERVER_YELLOW)
        )
        server.notGameContext(victim)

    else:
        if not (victim.login in room.kickVotes):
            room.kickVotes[victim.login] = @[]
        var kickers = room.kickVotes[victim.login]
        if (kicker.login in kickers) or (kicker.login == ".guest"):
            return
        kickers.add(kicker.login)
        room.kickVotes[victim.login] = kickers # Setting key to copy...
        var requiredKickes = room.clients.len div 2 + 1
        room.sendGlobalChat(
            color_message(kicker.display, SERVER_YELLOW) &
            " voted to exclude " & color_message(victim.display,
                    SERVER_YELLOW) &
            " from this match." &
            " ( " & $kickers.len & " / " & $requiredKickes & " )"
        )
        if kickers.len >= requiredKickes:
            room.sendGlobalChat(
                color_message(victim.display, SERVER_YELLOW) &
                " is now excluded from this match." &
                " ( " & $kickers.len & " / " & $requiredKickes & " )"
            )
            room.kickVotes.del victim.login
            room.excluded.add(victim.login)
            server.notGameContext(victim)


proc handleCevent(server: Server, room: Room, client: Client,
        cevent: string): string =
    var player = client.player

    var events: seq[string] = @[]
    for eventWithArgs in cevent.split(";"):
        if eventWithArgs.len == 0:
            continue
        var parts = eventWithArgs.split("|")
        if parts.len < 2:
            continue
        var event = parts[0]
        var args = parts[1]

        if event in ["chat", "tchat"]:
            events.add([event, $client.player.slot, args,
                    client.player.chatPrefix].join("|"))
            if room.chatReceiver.isNil: continue
            room.talkerSlot = client.player.slot
            room.talkerMessage = args
            room.messageIsTeam = event == "tchat"
            server.executeTrigger(room, room.chatReceiver)
            
        elif event == "frag":
            var arguments = args.split("#")
            if arguments.len != 5:
                continue
            player.deaths += 1
            try:
                var killer = arguments[1].parseInt
                if killer in room.clients:
                    var killerP = room.clients[killer].player
                    killerP.kills += 1

                    var team = killerP.match_data["t"].parseInt
                    if not (team in room.teamScores):
                        room.teamScores[team] = 0
                    room.teamScores[team] += 1
            except ValueError:
                discard
            events.add(["frag", args].join("|"))

        elif event in ["user_disconnect", "gs", "gok"]:
            continue # ABSOLUTELY NOT.

        elif event == "refresh":
            server.logger.log(lvlInfo, "Player \"" & client.player.display & "\" requests refresh")
            room.refreshing = room.testID != "_" and room.isMaster(client.player)


        elif event == "m_ow":
            events.add([
                event,
                args & "#" & "/" & room.masters.join("/") & "/"
            ].join("|"))

        elif event == "change_pw":
            var newPw = args
            if room.isMaster(player):
                room.password = newPw
                events.add([event, newPw].join("|"))
            else:
                continue

        elif event == "srand":
            var splt = args.split("#")
            if splt.len != 2:
                continue
            var varName = splt[0]
            var varRange = splt[1]
            events.add([
                event,
                varName & "#" & room.getSRNGValue(varName, varRange)
            ].join("|"))

        elif event == "gren":
            # Request to spawn grenade.
            var splt = args.split("#")
            if splt.len < 2:
                continue
            var specialType = splt[0]
            var clientSpecialID = splt[1]
            var startX = -1
            var startY = -1
            try:
                startX = player.matchData["x"].parseInt
                startY = player.matchData["y"].parseInt - 40
            except ValueError:
                continue
            events.add([
                "gok",
                [$player.slot, clientSpecialID, $room.lastSpecial].join("#")
            ].join("|")) # Assign grenade with server ID ID, matching client grenade ID
            events.add([
                "gs",
                [$room.lastSpecial, $startX, $startY, "0", "0", specialType,
                        $player.slot].join("#")
            ].join("|")) # Spawn  grenade.
            inc room.lastSpecial
            if room.lastSpecial == int.high:
                room.lastSpecial = 0

        elif event == "gm":
            # Move grenade.
            var splt = args.split("#")
            if splt.len != 7:
                continue
            var
                id = splt[0]
                x = splt[1]
                y = splt[2]
                vx = splt[3]
                vy = splt[4]
                #primed = splt[5]
                #visible = splt[6]
            # TODO: Check if gm sender is grenade owner themselves
            events.add([
                "gm",
                [id, x, y, vx, vy, "0", "0", $room.grenTick].join("#")
            ].join("|"))
            inc room.grenTick
            if room.grenTick == int.high:
                room.grenTick = 0

        elif event == "voteping":
            var newMaxPing = 0
            try:
                newMaxPing = args.parseInt
            except ValueError:
                continue
            if room.isMaster(player) or player.isAdmin:
                room.maxPing = newMaxPing
                room.sendGlobalChat(
                    "Ping limit set to " & color_message($newMaxPing,
                            SERVER_YELLOW) &
                    " by Match Owner " & color_message(player.display, SERVER_YELLOW)
                )

        elif event == "votekick":
            var splt = args.split("#")
            if splt.len != 2:
                continue
            var kickingClient: Client
            try:
                kickingClient = room.clients[splt[0].parseInt]
            except ValueError:
                continue
            var kicking = kickingClient.player
            if kicking.login in room.excluded:
                continue
            server.handleVoteKick(room, player, kicking)

        elif event == "sync":
            events.add(["sync", $player.slot & "#" & args].join("|"))

        else:
            events.add([event, args].join("|"))

    for event in events:
        result.add(";" & event)

proc handleCoop*(server: Server, client: Client, room: Room) =
    var aliveTeams: seq[int]
    var allTeams: seq[int]
    var alivePlayers: int = 0
    var timeDifference = (now() - room.lastRoundEnd).inMilliseconds

    if not room.restarting and (timeDifference < ROUND_SWITCH_DELAY +
            ROUND_START_DELAY):
        return

    for oclient in room.clients.values:
        var player = oclient.player
        if player.isSpectator:
            continue
        try:
            var team = player.matchData["t"].parseInt
            var health = player.matchData["he"].parseInt
            if health > 0:
                alivePlayers += 1

            if team in VALID_TEAMS:
                if not (team in allTeams):
                    allTeams.add(team)
                if health > 0:
                    if not (team in aliveTeams):
                        aliveTeams.add(team)
        except ValueError:
            continue

    if room.restarting:
        if timeDifference >= ROUND_SWITCH_DELAY:
            room.round.inc
            for oclient in room.clients.values:
                var player = oclient.player
                player.events.add(";chat2|" & color_message("Round: " &
                        $room.round, SERVER_YELLOW))
            room.restarting = false
        return

    if alivePlayers == 0 or ((aliveTeams.len == 1) and (allTeams.len > 1)):
        var message = "Round Draw"
        if aliveTeams.len == 1:
            var teamID = aliveTeams[0]
            var team = ValidTeams[teamID]
            message = color_message(team.name, team.color) & " Victory."
            if not (teamID in room.teamWins):
                room.teamWins[teamID] = 0
            room.teamWins[teamID] += 1

        var teamsMessage = ""
        for teamID in allTeams:
            var team = ValidTeams[teamID]
            if not (teamID in room.teamWins):
                continue
            teamsMessage.add(color_message(team.name & ": ", team.color) &
                    $room.teamWins[teamID] & " ")

        for oclient in room.clients.values:
            var player = oclient.player
            player.events.add(";chat2|" & message)
            player.events.add(";chat2|" & teamsMessage)

        room.lastRoundEnd = now()
        room.restarting = true

proc performRefresh*(ctx: Context, room: Room) {.async.} =
    var server = ctx.server

    if room.refreshing:
        room.fetched = false
        room.fetching = true
        
        var mapdata = await server.getMapdata(room.mapID)
        var extra = ""

        if mapdata != "<not_published />":
            room.mapdata = mapdata
            extra.add("&refresh=1")
            extra.add("&mapdata=" & room.mapdata)
            doThingsWithMapdata(ctx, room)
            room.sendGlobalChat("Server: Refreshed.")
        else:
            room.sendGlobalChat("Server: Map is not published.")

        for client in room.clients.values:
            client.player.extra.add(extra)

        room.fetched = true
        room.fetching = false
        room.refreshing = false

proc RQHandleGame*(ctx: Context): Future[string] {.async.} =
    var client = ctx.client
    var server = ctx.server
    var data = ctx.data
    
    if client.player.isNil:
        return ""
    if client.player.room == -1:
        return "&dropped=1"

    var ce = ""
    try:
        ce = data["ce"]
    except KeyError:
        return ""
    data.del "tok"
    data.del "ce"
    data.del "rq"

    var rooms = ctx.server.rooms
    var room = rooms[client.player.room]
    client.player.matchData = data
    if not client.player.isSpectator:
        ce = handleCevent(server, room, client, ce)
    else:
        ce = "" # Flat out ignore spectators, for now.
    if client.player.login in room.excluded:
        #server.notGameContext(client.player) # Already done in handleVoteKick.
        return "&dropped=1"
    for oclient in room.clients.values:
        oclient.player.events.add(ce)

    var currentPlayer = client.player

    if room.refreshing:
        await ctx.performRefresh(room)
    else:    
        if room.gamemode == GAMEMODE_COOP:
            handleCoop(server, client, room)
    result.add("&evs=" & currentPlayer.events)
    currentPlayer.events = ""

    for (slot, oclient) in room.clients.pairs:
        if (slot == client.player.slot) or oclient.player.isSpectator:
            continue
        for (key, value) in oclient.player.matchData.pairs:
            result.add("&p" & $slot & key & "=" & value)
        result.add("&p" & $slot & "lo=" & oclient.player.login)
        result.add("&p" & $slot & "k=" & $oclient.player.kills)
        result.add("&p" & $slot & "dd=" & $oclient.player.deaths)
        result.add("&p" & $slot & "p=" & $oclient.ping)
        result.add("&p" & $slot & "_=" & $(oclient.pckID mod 100))

    if not client.player.isSpectator:
        result.add("&k=" & $currentPlayer.kills)
        result.add("&dd=" & $currentPlayer.deaths)

    if room.gamemode == GAMEMODE_TDM:
        result.add("&r=" & $room.teamScores.getOrDefault(12, 0))
        result.add("&b=" & $room.teamScores.getOrDefault(13, 0))
    elif room.gamemode == GAMEMODE_COOP:
        result.add("&rnd=" & $room.round)
    
    result.add(client.player.extra)
    client.player.extra = ""

    var lowestPing = int.high
    for (slot, mclient) in room.clients.pairs:
        if mclient.player.isSpectator:
            continue
        if mclient.ping < lowestPing:
            lowestPing = mclient.ping
            room.entityMaster = slot
    
    result.add("&em=" & $room.entityMaster)

registerHandler("g", @["ce"], proc(ctx: Context): Future[
string] {.async.} =
    return await RQHandleGame(ctx)
)