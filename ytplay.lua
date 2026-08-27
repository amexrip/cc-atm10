-- YouTube player for CC:Tweaked (4x2 monitor + speaker).
-- A converter on the Minecraft host turns the link into DFPWM + cover art.
-- First run: ytplay setup
--   public:   http://YOUR.SERVER.IP:8765
--   or local: http://127.0.0.1:8765  (needs a CC http.rules allow for 127.0.0.0/8)

local SETTINGS_KEY = "ytcc.base"

local function jsonDecode(s)
    if textutils.unserialiseJSON then
        return textutils.unserialiseJSON(s)
    end
    return textutils.unserialize(s)
end

local function clampTimeout(t)
    t = tonumber(t) or 10
    if t < 0 then t = 0 end
    if t > 60 then t = 60 end
    return t
end

local function httpGet(url, timeout, binary)
    local opts = { url = url, timeout = clampTimeout(timeout), binary = binary and true or false }
    local h, err = http.get(opts)
    if not h then return nil, err end
    local body = h.readAll()
    h.close()
    return body
end

local function httpPostJson(url, tbl)
    local body = textutils.serialiseJSON(tbl)
    local h, err = http.post(url, body, { ["Content-Type"] = "application/json" })
    if not h then return nil, err end
    local resp = h.readAll()
    h.close()
    return jsonDecode(resp)
end

local function prompt(label)
    term.setTextColor(colors.yellow)
    write(label)
    term.setTextColor(colors.white)
    return read()
end

local function looksLikeConverter(s)
    s = (s or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
    local low = s:lower()
    if s == "" then return false end
    if low == "play" or low == "setup" or low == "ytplay" then return false end
    if low:find("youtube.com", 1, true) or low:find("youtu.be", 1, true) then
        return false
    end
    return low:find("^https?://") ~= nil
end

if not http then
    printError("Enable http in ComputerCraft.")
    return
end

local monitor = peripheral.find("monitor")
if not monitor then
    printError("No monitor. Use a 4x2 advanced monitor on top.")
    return
end
monitor.setTextScale(0.5)
monitor.setBackgroundColor(colors.black)
monitor.setTextColor(colors.white)
monitor.clear()

local speaker = peripheral.find("speaker")
if not speaker then
    printError("No speaker. Put a speaker on the left.")
    return
end

local function monLine(y, text, color)
    monitor.setCursorPos(1, y)
    monitor.clearLine()
    if color then monitor.setTextColor(color) end
    local w = select(1, monitor.getSize())
    monitor.write(tostring(text):sub(1, w))
end

local args = { ... }
local arg1 = args[1]
local base = settings.get(SETTINGS_KEY)

local function explainHttpError(err)
    err = tostring(err or "")
    printError("Cannot reach converter: " .. err)
    if err:lower():find("domain not permitted", 1, true) then
        print("CC blocked that host. With start.sh on the Minecraft")
        print("server, allow loopback ABOVE $private, restart, then")
        print("use http://127.0.0.1:8765")
        print('  [[http.rules]]')
        print('  host = "127.0.0.0/8"')
        print('  action = "allow"')
    else
        print("Is start.sh running on the Minecraft host?")
        print("Then run:  play setup")
        print("and paste: http://127.0.0.1:8765")
    end
end

if arg1 == "setup" or not looksLikeConverter(base) then
    print("NOT the shell. Paste ONLY the converter address.")
    print("Because start.sh is on the Minecraft server, type this:")
    print("  http://127.0.0.1:8765")
    while true do
        base = prompt("Converter URL: ")
        base = (base or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
        if looksLikeConverter(base) then break end
        printError("That is not a converter URL. Example:")
        print("  http://127.0.0.1:8765")
        print("Do not type play. Do not paste a YouTube link here.")
    end
    settings.set(SETTINGS_KEY, base)
    pcall(settings.save)
    print("Saved converter " .. base)
end

print("Checking converter " .. base)
local health, herr = httpGet(base .. "/health", 5)
if not health then
    explainHttpError(herr)
    return
end

local yt
if arg1 and arg1 ~= "setup" then
    yt = table.concat(args, " ")
else
    print("Converter is up. NOW paste the YouTube link.")
    yt = prompt("YouTube URL: ")
end
yt = (yt or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^/+", "")
if yt == "" then
    print("No YouTube URL. Run play again and paste the link.")
    return
end
if not yt:lower():find("^https?://") then
    yt = "https://" .. yt
end
if not yt:lower():find("youtu") then
    printError("That does not look like a YouTube URL.")
    return
end

local mw, mh = monitor.getSize()
local titleH = 3
local coverW, coverH = mw, math.max(8, mh - titleH)

monLine(1, "Converting...", colors.cyan)
monLine(2, yt, colors.lightGray)

print("Starting convert job...")
local job, jerr = httpPostJson(base .. "/job", { url = yt, w = coverW, h = coverH })
if not job or not job.id then
    printError("Job failed: " .. tostring(jerr or (job and job.error)))
    return
end

local info
while true do
    sleep(2)
    local body, err = httpGet(base .. "/job/" .. job.id, 10)
    if not body then
        printError("Status failed: " .. tostring(err))
        return
    end
    info = jsonDecode(body)
    if not info then
        printError("Bad status JSON")
        return
    end
    monLine(1, info.phase or info.status or "...", colors.cyan)
    monLine(2, info.title or "", colors.yellow)
    monLine(3, info.message or "", colors.lightGray)
    print((info.phase or "?") .. " - " .. (info.message or ""))
    if info.status == "ready" then break end
    if info.status == "error" then
        printError(info.error or info.message or "convert error")
        monLine(1, "Convert failed", colors.red)
        monLine(3, info.error or info.message or "", colors.orange)
        return
    end
end

pcall(fs.delete, "yt-audio.dfpwm")
pcall(fs.delete, "yt-cover.nfp")

print("Fetching cover...")
monLine(1, "Cover art...", colors.cyan)

if info.cover then
    local nfp = httpGet(base .. info.cover, 20)
    if nfp then
        monitor.setBackgroundColor(colors.black)
        monitor.clear()
        local y = 1
        for line in (nfp .. "\n"):gmatch("(.-)\n") do
            for x = 1, #line do
                local n = tonumber(line:sub(x, x), 16)
                if n then
                    monitor.setCursorPos(x, y)
                    monitor.setBackgroundColor(2 ^ n)
                    monitor.write(" ")
                end
            end
            y = y + 1
        end
    end
end

local title = info.title or "YouTube"
for i = 0, titleH - 1 do
    monLine(coverH + 1 + i, "", colors.white)
end
monLine(coverH + 1, title, colors.yellow)
monLine(coverH + 2, "Playing  Ctrl+T to stop", colors.lightGray)

print("Loading audio...")
monLine(coverH + 2, "Loading audio...", colors.lightGray)
local audio, aerr = httpGet(base .. info.audio, 60, true)
if not audio or audio == "" then
    printError("Audio download failed: " .. tostring(aerr))
    return
end

print("Playing: " .. title)
monLine(coverH + 2, "Playing  Ctrl+T to stop", colors.lightGray)
local dfpwm = require("cc.audio.dfpwm")
local decoder = dfpwm.make_decoder()
local pos = 1
local n = #audio
while pos <= n do
    local chunk = audio:sub(pos, pos + 16 * 1024 - 1)
    pos = pos + #chunk
    local buf = decoder(chunk)
    while not speaker.playAudio(buf) do
        os.pullEvent("speaker_audio_empty")
    end
end
monLine(coverH + 2, "Done", colors.lime)
print("Done.")
