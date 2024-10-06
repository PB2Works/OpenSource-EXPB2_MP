import std/tables

proc colorMessage(text: string, color: string): string =
    result = "<font color[eq]\"" & color & "\">" & text & "</font>"

# Specified prefix for Developers and Admins
const DEVELOPER_PREFIX* = colorMessage("[Developer]"  , "#16a7c4")
const ADMIN_PREFIX*     = colorMessage("[Admin]"      , "#ff0000")
const DESIGNER_PREFIX*  = colorMessage("[Designer]"   , "#ffcdf0")
const TESTER_PREFIX*    = colorMessage("[Beta Tester]", "#328da8")

# List of skins guests can use.
const USABLE_GUEST_SKINS* = @[1,2,3,4,6,7,8,9,11,12,13,14,15,16,17,18,19,21,22,23,24,25,26,
                            27,28,29,31,32,33,34,35,36,37,40,41,42,43,44,45,46,47,48,49,61,
                            69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,
                            90,130,131,132,133,134,135,136,137,138,139,140,141,142,143,144,
                            145,146,147,148,149,150]

# Timings (ms)
const TCP_RECEIVE_TIMEOUT* =  60000 
const MATCH_DELETE_AFTER*  = 300000
const RNG_VALID_FOR*       =   4000
const ROUND_START_DELAY*   =   1000
const ROUND_SWITCH_DELAY*  =   3500

# Colors for general things.
const JOIN_LEAVE_COLOR* = "#FF00FF"
const SERVER_YELLOW*    = "#FFF998"
const SERVER_GREEN*     = "#267230"
const SERVER_RED*       = "#ff0000"

# Team id to name and color map.
const VALID_TEAMS* = {
    0 : (name: "Alpha"              , color: "#b0ff7b"),
    1 : (name: "Beta"               , color: "#7eb0fa"),
    2 : (name: "Gamma"              , color: "#dbbb28"),
    3 : (name: "Delta"              , color: "#7a7a7a"),
    4 : (name: "Zeta"               , color: "#3fa042"),
    5 : (name: "Lambda"             , color: "#bc5d00"),
    6 : (name: "Sigma"              , color: "#8d95ff"),
    7 : (name: "Omega"              , color: "#e1ddba"),
    8 : (name: "Counter-Terrorists" , color: "#b2d6ea"),
    9 : (name: "Terrorists"         , color: "#5d160b"),
    10: (name: "Usurpation Forces"  , color: "#efe66c"),
    11: (name: "Civil Security"     , color: "#eacf98"),
    12: (name: "Red Team"           , color: "#fe0000"),
    13: (name: "Blue Team"          , color: "#5dc6fd"),
    14: (name: "Green Team"         , color: "#80fc9a"),
    15: (name: "White Team"         , color: "#ededed"),
    16: (name: "Black Team"         , color: "#3d3d3d")
}.toTable

# Just convenient constants to use instead of number directly.
const GAMEMODE_DM*   = 1
const GAMEMODE_COOP* = 2
const GAMEMODE_TDM*  = 3