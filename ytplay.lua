-- YouTube player for CC:Tweaked
-- Hardware: 4x2 advanced monitor (top), speaker (left), advanced computer.
-- Paste a YouTube URL. Audio plays on the speaker; title + video/cover draw
-- on the 4x2 monitor. Conversion is done by YouCube (DFPWM + 32vid).

local SERVER = "wss://youcube.onrender.com"
local CONNECT_TIMEOUT = 25

local YT_FILES = {
    ["youcube.lua"] = "https://raw.githubusercontent.com/CC-YouCube/client/main/src/youcube.lua",
    ["lib/youcubeapi.lua"] = "https://raw.githubusercontent.com/CC-YouCube/client/main/src/lib/youcubeapi.lua",
    ["lib/numberformatter.lua"] = "https://raw.githubusercontent.com/CC-YouCube/client/main/src/lib/numberformatter.lua",
    ["lib/semver.lua"] = "https://raw.githubusercontent.com/CC-YouCube/client/main/src/lib/semver.lua",
    ["lib/argparse.lua"] = "https://raw.githubusercontent.com/CC-YouCube/client/main/src/lib/argparse.lua",
    ["lib/string_pack.lua"] = "https://raw.githubusercontent.com/CC-YouCube/client/main/src/lib/string_pack.lua",
}

if not http then
    printError("Enable http in the ComputerCraft config.")
    return
end

if not http.websocket then
    printError("Enable websockets in the ComputerCraft config.")
    return
end

local function download(path, url, force)
    if fs.exists(path) and not force then return true end
    print("Downloading " .. path .. " ...")
    local dir = path:match("(.+)/")
    if dir and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local h, err = http.get({ url = url, binary = true })
    if not h then
        printError("Failed " .. path .. ": " .. tostring(err))
        return false
    end
    local f = fs.open(path, "wb")
    f.write(h.readAll())
    f.close()
    h.close()
    return true
end

-- Public knijn hosts are dead / TLS-broken. Stock YouCube also tries
-- ws://127.0.0.1:5000 then times out in 5s. Force the live Render server
-- and a longer handshake timeout.
local function patchYouCubeApi()
    local path = "lib/youcubeapi.lua"
    local h = fs.open(path, "r")
    if not h then return false end
    local src = h.readAll()
    h.close()
    src = src:gsub("local servers = %b{}", 'local servers = { "' .. SERVER .. '" }', 1)
    src = src:gsub("websocket_with_timeout%(server, nil, %d+%)", "websocket_with_timeout(server, nil, " .. CONNECT_TIMEOUT .. ")")
    local f = fs.open(path, "w")
    f.write(src)
    f.close()
    return true
end

local function ensureYouCube()
    for path, url in pairs(YT_FILES) do
        if not download(path, url, false) then return false end
    end
    return patchYouCubeApi()
end

local function monWrite(monitor, y, text, color)
    monitor.setCursorPos(1, y)
    monitor.clearLine()
    if color then monitor.setTextColor(color) end
    monitor.write(tostring(text):sub(1, select(1, monitor.getSize())))
end

local monitor = peripheral.find("monitor")
if not monitor then
    printError("No monitor found. Attach a 4x2 advanced monitor on top.")
    return
end

monitor.setTextScale(0.5)
monitor.setBackgroundColor(colors.black)
monitor.setTextColor(colors.white)
monitor.clear()

local speaker = peripheral.find("speaker")
if not speaker then
    printError("No speaker found. Put a speaker on the left of the computer.")
    return
end

print("ATM10 YouTube player")
print("Monitor: 4x2  Speaker: " .. peripheral.getName(speaker))
print("")

if not ensureYouCube() then
    printError("Could not install the YouTube converter client.")
    return
end

if settings then
    settings.set("youcube.server", SERVER)
    pcall(settings.save)
end

local url = ...
if not url or url == "" then
    print("Paste a YouTube link, then Enter:")
    term.setTextColor(colors.yellow)
    url = read()
    term.setTextColor(colors.white)
end

url = url and url:gsub("^%s+", ""):gsub("%s+$", "") or ""
if url == "" then
    print("No URL given.")
    return
end

monWrite(monitor, 1, "Connecting to converter...", colors.cyan)
monWrite(monitor, 2, url, colors.lightGray)
monWrite(monitor, 4, "This can take up to " .. CONNECT_TIMEOUT .. "s", colors.gray)

print("")
print("Connecting to " .. SERVER)
print("(first start after idle can be slow)")
print("Hold Ctrl+T to stop.")

-- Keep errors on the computer. Redirect only while YouCube is running.
local old = term.redirect(monitor)
local ok, err = pcall(function()
    shell.run("youcube.lua", "--server", SERVER, url)
end)
term.redirect(old)

if not ok or (err and tostring(err):lower():find("timeout")) then
    local msg = tostring(err or "unknown error")
    printError("Playback failed: " .. msg)
    print("The converter at youcube.onrender.com may be waking up.")
    print("Run ytplay again in 20 seconds.")
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    monWrite(monitor, 1, "Converter timed out", colors.red)
    monWrite(monitor, 3, "Run ytplay again", colors.white)
    monWrite(monitor, 4, "Render servers sleep when idle", colors.lightGray)
end
