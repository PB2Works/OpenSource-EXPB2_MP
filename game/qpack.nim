import std/strutils

const LOADSCRIPT = """qpack_rule_2param("^","[^]");qpack_rule("\" /><player x=\"");qpack_rule("\" /><enemy x=\"");qpack_rule("\" /><door x=\"");qpack_rule("\" /><box x=\"");qpack_rule("\" /><gun x=\"");qpack_rule("\" /><pushf x=\"");qpack_rule("\" /><decor x=\"");qpack_rule("\" /><trigger enabled=\"true");qpack_rule("\" /><trigger enabled=\"false");qpack_rule("\" /><timer enabled=\"true");qpack_rule("\" /><timer enabled=\"false");qpack_rule("\" /><inf mark=\"");qpack_rule(" /><bg x=\"");qpack_rule(" /><lamp x=\"");qpack_rule(" /><region x=\"");qpack_rule("<player x=\"");qpack_rule("\" damage=\"");qpack_rule("\" maxspeed=\"");qpack_rule("\" model=\"gun_");qpack_rule("\" model=\"");qpack_rule("\" botaction=\"");qpack_rule("\" ondeath=\"");qpack_rule("\" actions_");qpack_rule("_targetB=\"");qpack_rule("_type=\"");qpack_rule("_targetA=\"");qpack_rule("\" team=\"");qpack_rule("\" side=\"");qpack_rule("\" command=\"");qpack_rule("\" flare=\"");qpack_rule("\" power=\"");qpack_rule("\" moving=\"true");qpack_rule("\" moving=\"false");qpack_rule("\" tarx=\"");qpack_rule("\" tary=\"");qpack_rule("\" tox=\"");qpack_rule("\" toy=\"");qpack_rule("\" hea=\"");qpack_rule("\" hmax=\"");qpack_rule("\" incar=\"");qpack_rule("\" char=\"");qpack_rule("\" maxcalls=\"");qpack_rule("\" vis=\"false");qpack_rule("\" vis=\"true");qpack_rule("\" use_on=\"");qpack_rule("\" use_target=\"");qpack_rule("\" upg=\"0^");qpack_rule("\" upg=\"");qpack_rule("^fgun_");qpack_rule("\" addx=\"");qpack_rule("\" addy=\"");qpack_rule("\" y=\"");qpack_rule("\" w=\"");qpack_rule("\" h=\"");qpack_rule("\" m=\"");qpack_rule("\" at=\"");qpack_rule("\" delay=\"");qpack_rule("\" target=\"");qpack_rule("\" stab=\"");qpack_rule("\" mark=\"");qpack_rule("0^T0^3");qpack_rule("0^x^y0^z0^h1^");qpack_rule("^m3^o-1^m3^p0^m3^n0^m4^o-1^m4^p0^m4^n0^m5^o-1^m5^p0^m5^n0^m6^o-1^m6^p0^m6^n0^m7^o-1^m7^p0^m7^n0^m8^o-1^m8^p0^m8^n0^m9^o-1^m9^p0^m9^n0^m10^o-1^m10^p0^m10^n0");qpack_rule("^m5^o-1^m5^p0^m5^n0^m6^o-1^m6^p0^m6^n0^m7^o-1^m7^p0^m7^n0^m8^o-1^m8^p0^m8^n0^m9^o-1^m9^p0^m9^n0^m10^o-1^m10^p0^m10^n0");qpack_rule("^A0^B0^C130^D130^q");qpack_rule("0^u0.4^t1\"^");qpack_rule("0^Q1");qpack_rule("0^R");qpack_rule("0^S");qpack_rule("0^Q-");qpack_rule("0^Q");qpack_rule("\" /><water x=\"");qpack_rule("\" forteam=\"");qpack_rule("^Ttrue");qpack_rule("true");qpack_rule("false");qpack_rule("^m2^o-1^m2^p0^m2^n0^)");qpack_rule("pistol");qpack_rule("rifle");qpack_rule("shotgun");qpack_rule("real_");"""
const CHARS = "0123456789abcdefghijklmnopqrstuwxyzABCDEFGHIJKLMNOPQRSTUWXYZ_()$@~!.,*-+;:?<>/#%&"

proc newRuleSeq(): seq[array[2, string]] =
    var cursor = 0
    for iline in LOADSCRIPT.split(';'):
        if iline.len == 0:
            continue
        var line = iline
        var real, fake = ""
        line.removePrefix(' ')
        line.removeSuffix(' ')
        if line.len > 17 and line[0..<17] == "qpack_rule_2param":
            var splt = line[19..^3].split("\",\"", 1)
            real = splt[0]
            fake = splt[1]
        else:
            real = line[12..^3].replace("\\\"", "\"")
            fake = "^" & CHARS[cursor]
            cursor += 1
        result.add( [real, fake])

const rules = newRuleSeq()

proc unqpack*(data: string): string =
    result = data
    result = result.replace("[i]", "&").replace("[eq]", "=").replace("<q.", "")
    for index in countdown(rules.len-1, 0):
        result = result.replace(rules[index][1], rules[index][0])

proc qpack*(data: string): string =
    result = data
    for arr in rules:
        result = result.replace(arr[0], arr[1])
    result = "<q." & result.replace("&", "[i]").replace("=", "[eq]")
