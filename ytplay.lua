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

local function httpGet(url, timeout)
    local opts = { url = url, timeout = timeout or 10, binary = false }
    local h, err = http.get(opts)
    if not h then return nil, err end
    local body = h.readAll()
    h.close()
    return body
end

local function httpGetBin(url)
    local h, err = http.get({ url = url, binary = true, timeout = 60 })
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

local base = settings.get(SETTINGS_KEY)
local arg1 = ...
local function explainHttpError(err)
    err = tostring(err or "")
    printError("Cannot reach converter: " .. err)
    if err:lower():find("domain not permitted", 1, true) then
        print("CC blocked that host. Do not use 10.x, 192.168.x, 127.x,")
        print("or Tailscale 100.x unless you allow it in")
        print("serverconfig/computercraft-server.toml (above $private):")
        print('  [[http.rules]]')
        print('  host = "127.0.0.0/8"')
        print('  action = "allow"')
        print("Or use the Minecraft server's public IP/hostname.")
    else
        print("Run ytcc/start.sh on the Minecraft Ubuntu host, then:")
        print("  ytplay setup")
    end
end

if arg1 == "setup" or not base or base == "" then
    print("Paste the converter URL (Minecraft server, not Tailscale):")
    print("  http://PUBLIC.IP:8765")
    print("  or http://127.0.0.1:8765 if you allowed loopback")
    base = prompt("> ")
    base = base:gsub("/+$", "")
    settings.set(SETTINGS_KEY, base)
    pcall(settings.save)
    print("Saved " .. base)
    if arg1 == "setup" then return end
end

print("Checking converter " .. base)
local health, herr = httpGet(base .. "/health", 5)
if not health then
    explainHttpError(herr)
    return
end

local yt = arg1
if not yt or yt == "" or yt == "setup" then
    print("Paste a YouTube URL:")
    yt = prompt("> ")
end
yt = yt:gsub("^%s+", ""):gsub("%s+$", "")
if yt == "" then
    print("No URL.")
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

print("Downloading cover + audio...")
monLine(1, "Downloading...", colors.cyan)

if info.cover then
    local nfp = httpGet(base .. info.cover, 20)
    if nfp then
        local f = fs.open("yt-cover.nfp", "w")
        f.write(nfp)
        f.close()
        monitor.setBackgroundColor(colors.black)
        monitor.clear()
        paintutils.drawImage(paintutils.loadImage("yt-cover.nfp"), 1, 1)
    end
end

local title = info.title or "YouTube"
for i = 0, titleH - 1 do
    monLine(coverH + 1 + i, "", colors.white)
end
monLine(coverH + 1, title, colors.yellow)
monLine(coverH + 2, "Playing  Ctrl+T to stop", colors.lightGray)

local audio = httpGetBin(base .. info.audio)
if not audio then
    printError("Audio download failed")
    return
end
local af = fs.open("yt-audio.dfpwm", "wb")
af.write(audio)
af.close()

print("Playing: " .. title)
local dfpwm = require("cc.audio.dfpwm")
local decoder = dfpwm.make_decoder()
local fh = fs.open("yt-audio.dfpwm", "rb")
while true do
    local chunk = fh.read(16 * 1024)
    if not chunk then break end
    local buf = decoder(chunk)
    while not speaker.playAudio(buf) do
        os.pullEvent("speaker_audio_empty")
    end
end
fh.close()
monLine(coverH + 2, "Done", colors.lime)
print("Done.")
