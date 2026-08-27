-- YouTube player for CC:Tweaked
-- Hardware: 4x2 advanced monitor (top), speaker (left), advanced computer.
-- Paste a YouTube URL. Audio plays on the speaker; title + video/cover draw
-- on the 4x2 monitor. Conversion (yt-dlp -> DFPWM + 32vid) is done by YouCube.

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

local function download(path, url)
    if fs.exists(path) then return true end
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

local function ensureYouCube()
    for path, url in pairs(YT_FILES) do
        if not download(path, url) then return false end
    end
    return true
end

local monitor = peripheral.find("monitor")
if not monitor then
    printError("No monitor found. Attach a 4x2 advanced monitor on top.")
    return
end

-- 4x2 at 0.5 scale gives enough pixels for the cover / video + title.
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

monitor.setCursorPos(1, 1)
monitor.setTextColor(colors.cyan)
monitor.write("Loading YouTube...")
monitor.setCursorPos(1, 2)
monitor.setTextColor(colors.lightGray)
monitor.write(url:sub(1, select(1, monitor.getSize())))

print("")
print("Playing on the 4x2 monitor.")
print("Hold Ctrl+T to stop.")

-- YouCube draws title + video on `term` and sizes the stream from term.getSize().
-- Redirect so that is the 4x2 monitor, not the computer screen.
local old = term.redirect(monitor)
local ok, err = pcall(function()
    shell.run("youcube.lua", url)
end)
term.redirect(old)

if not ok then
    printError("Playback failed: " .. tostring(err))
    print("The YouCube servers convert the video to DFPWM.")
    print("If this keeps failing, the public servers may be down.")
end
