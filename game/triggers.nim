import std/asyncdispatch
import std/logging
import std/tables
import std/strutils

import objects

proc executeTimer*(server: Server, room: Room, timer: SSTimer)

proc handleTimers*(server: Server) {.async.} =
    server.logger.log(lvlInfo, "Server Sided Timers will be ran.")
    var msPerTick = 1000 / 30
    var rooms = server.rooms

    while not server.closing:
        await sleepAsync(msPerTick)
        if rooms.len == 0:
            continue # nothing to do here.
        for room in rooms.values:
            if room.serverSidedTimers.len == 0:
                continue # nothing to do here.
            for timer in room.serverSidedTimers.values:
                if not timer.enabled:
                    continue
                if timer.maxCalls == 0:
                    continue
                timer.tick += 1
                if timer.tick >= timer.delay:
                    timer.tick = 0
                    if timer.maxCalls > 0:
                        timer.maxCalls -= 1
                    server.executeTimer(room, timer)

#########################################################

proc executeAction*(ctx: TriggerContext, action: SSTAction) =
    var args = action.args
    var room = ctx.room
    var opcode = action.opcode

    case opcode:
    # Basic actions
    of 42: # Send text 'A' in chat with color 'B'
        var message = colorMessage(args[0], args[1])
        for key, value in ctx.room.variables.pairs:
            if key in message:
                message = message.replace(key, value)
        room.sendGlobalChat(message)

    # Player actions
    of 184, 187, 185, 188: # Get login, displayed name, 187 and 188 are variable version.
    # Not fully tested, I am too lazy, I just want to get things done
        var saveTo = args[0]
        var value = args[1]

        try:
            var valueInt = value.parseInt
            # Normal slot version.
            if valueInt notin room.clients:
                room.variables[saveTo] = "!UNDEFINED!"
            else:
                var saveValue = room.clients[valueInt].player.display
                if opcode == 184:
                    saveValue = room.clients[valueInt].player.login
                room.variables[saveTo] = saveValue
        except ValueError:
            # Variable version.
            if value notin room.variables:
                room.variables[saveTo] = "Do action properly."
            try:
                var valueInt = room.variables[value].parseInt
                if valueInt notin room.clients:
                    room.variables[saveTo] = "!UNDEFINED!"
                else:
                    var saveValue = room.clients[valueInt].player.display
                    if opcode == 187:
                        saveValue = room.clients[valueInt].player.login
                    room.variables[saveTo] = saveValue
        
            except ValueError:
                room.variables[saveTo] = "Do action properly."


    # Chat actions
    of 156: # Register trigger 'A' as chat receiver:
        var trigger = args[0]
        if trigger notin room.uidtoidmap:
            return
        var triggerID = room.uidtoidmap[trigger]
        if triggerID notin room.serverSidedTriggers:
            return
        room.chatReceiver = room.serverSidedTriggers[triggerID]
    of 159: # Get slot of talker
        room.variables[args[0]] = $(room.talkerSlot)
    of 160: # Get text being said
        room.variables[args[0]] = room.talkerMessage

    of 2500: # Set variable 'A' to 1 if recently sent message is team, set to 0 in else case
        # I decided to start actions with 2500
        room.variables[args[0]] = if room.messageIsTeam: "1" else: "0"

    else:
        discard


#########################################################

proc executeTrigger*(server: Server, room: Room, trigger: SSTrigger) =
    if not trigger.enabled:
        return
    if trigger.maxCalls == 0:
        return
    if trigger.maxCalls > 0:
        trigger.maxCalls -= 1
    
    if trigger.actions.len < 1:
        trigger.enabled = false
        return

    var ctx = TriggerContext(
        trigger: trigger,
        room: room,
        server: server
    )
    
    while ctx.actionID < ctx.trigger.actions.len:
        ctx.executeAction(ctx.trigger.actions[ctx.actionID])
        ctx.actionID += 1

proc executeTimer*(server: Server, room: Room, timer: SSTimer) =
    var trigger = timer.callback
    if trigger.actions.len < 1:
        trigger.enabled = false
        timer.enabled = false
    server.executeTrigger(room, trigger)