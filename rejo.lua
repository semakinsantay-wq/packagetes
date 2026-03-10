#!/usr/bin/env lua5.3

local os = require("os")
local io = require("io")

-- BERSIHKAN LAYAR SAAT PERTAMA KALI JALAN
os.execute("clear")

-- --- FUNGSI UTILITAS DASAR ---
local function sleep(ms)
    os.execute("sleep " .. tonumber(ms) / 1000)
end

local function exec(cmd)
    local f = io.popen(cmd)
    if not f then return "" end
    local result = f:read("*a")
    f:close()
    return (result:gsub("^%s*(.-)%s*$", "%1")) -- trim whitespace
end

local function split(s, delimiter)
    local result = {}
    for match in (s..delimiter):gmatch("(.-)"..delimiter) do
        table.insert(result, match)
    end
    return result
end

-- URL ENCODER MURNI LUA
local function urlencode(str)
    if str then
        str = string.gsub(str, "\n", "\r\n")
        str = string.gsub(str, "([^%w %-%_%.%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        str = string.gsub(str, " ", "+")
    end
    return str
end

-- --- MANAJEMEN KONFIGURASI (JSON) ---
local config_file = "config.json"
local config = {}

-- Fitur Argumen -reset
if arg then
    for i = 1, #arg do
        if arg[i] == "-reset" then
            print("🔄 Opsi '-reset' terdeteksi. Menghapus konfigurasi lama...\n")
            os.remove(config_file)
            break
        end
    end
end

local function file_exists(name)
    local f = io.open(name, "r")
    if f ~= nil then io.close(f) return true else return false end
end

if file_exists(config_file) then
    local f = io.open(config_file, "r")
    local content = f:read("*a")
    f:close()
    
    config.YES_KEY = content:match('"YES_KEY"%s*:%s*"([^"]+)"')
    config.PLACE_ID = content:match('"PLACE_ID"%s*:%s*"([^"]+)"')
    config.MSRV_URL = content:match('"MSRV_URL"%s*:%s*"([^"]+)"')
else
    print("🚀 Setup Konfigurasi Pertama Kali:")
    
    io.write("Masukkan YES_KEY Solver: ")
    config.YES_KEY = io.read()
    
    io.write("Masukkan PLACE_ID [Default: 121864768012064]: ")
    local pid_input = io.read()
    if pid_input == "" or pid_input == nil then
        config.PLACE_ID = "121864768012064"
    else
        config.PLACE_ID = pid_input
    end
    
    io.write("Masukkan MSRV_URL (tanpa https:// tidak apa-apa): ")
    local msrv_input = io.read()
    if msrv_input then
        msrv_input = msrv_input:match("^%s*(.-)%s*$")
        if msrv_input ~= "" and not msrv_input:match("^https?://") then
            config.MSRV_URL = "https://" .. msrv_input
        else
            config.MSRV_URL = msrv_input
        end
    else
        config.MSRV_URL = ""
    end
    
    local f = io.open(config_file, "w")
    local json_str = string.format('{\n  "YES_KEY": "%s",\n  "PLACE_ID": "%s",\n  "MSRV_URL": "%s"\n}', 
        config.YES_KEY, config.PLACE_ID, config.MSRV_URL)
    f:write(json_str)
    f:close()
    print("✅ Konfigurasi berhasil disimpan. Melanjutkan program...\n")
    sleep(1500)
    os.execute("clear")
end

-- --- CONFIGURATION LENGKAP ---
local SOLVER_API_URL = "http://134.199.219.230:3000/solve"
local AUTO_RANDOM_CODE = false

-- GRID SETTINGS (XML)
local GRID_COLS = 3
local BOX_SIZE = 150
local START_OFFSET_Y = 50
local GAP_X = 5
local GAP_Y = 60

-- TIMING & DETEKSI
local CHECK_INTERVAL = 60000 -- 1 menit dalam ms
local MIN_RAM_THRESHOLD = 10
local PRESENCE_CHECK_DELAY = 60000
local DEBUG_MODE = false

local accountStates = {}
local csrfTokens = {}
local launchTimers = {}

-- --- FUNGSI SISTEM ---
local function applyPerformanceTweaks()
    print("🚀 Menerapkan Tweak Performa (CPU, Thermal, UI)...")
    local tweaksCmd = [[
        for i in {0..7}; do
            echo 1 > /sys/devices/system/cpu/cpu$i/online 2>/dev/null;
            echo performance > /sys/devices/system/cpu/cpu$i/cpufreq/scaling_governor 2>/dev/null;
        done;
        stop thermal-engine 2>/dev/null;
        stop thermald 2>/dev/null;
        killall -9 thermal-engine thermald 2>/dev/null;
        for tz in /sys/class/thermal/thermal_zone*/trip_point_*_temp; do
            [ -f "$tz" ] && echo 99999 > "$tz" 2>/dev/null;
        done;
        echo 10 > /proc/sys/vm/swappiness 2>/dev/null;
        settings put global window_animation_scale 0 2>/dev/null;
        settings put global transition_animation_scale 0 2>/dev/null;
        settings put global animator_duration_scale 0 2>/dev/null;
    ]]
    os.execute("su -c '" .. tweaksCmd .. "' >/dev/null 2>&1")
    print("✅ Tweak Performa Aktif!\n")
end

local function getPackages()
    local output = exec("pm list packages | grep roblox")
    local packages = {}
    for pkg in output:gmatch("package:([^\n]+)") do
        -- Kurung ganda () mencegah nilai ganda dari gsub
        table.insert(packages, (pkg:gsub("%s+", "")))
    end
    table.sort(packages)
    return packages
end

local function getRobloxCookie(packageName)
    local tempPath = "/sdcard/temp_cookie_" .. packageName .. "_" .. tostring(os.time()) .. ".db"
    os.execute("su -c 'cp /data/data/" .. packageName .. "/app_webview/Default/Cookies " .. tempPath .. " 2>/dev/null'")
    local query = "sqlite3 " .. tempPath .. " \"SELECT value FROM cookies WHERE name = '.ROBLOSECURITY' LIMIT 1\""
    local cookie = exec(query)
    os.execute("rm -f " .. tempPath)
    
    if cookie and cookie ~= "" then
        if not cookie:match("^_") then cookie = "_" .. cookie end
        return cookie
    end
    return nil
end

local function getUserInfo(cookie)
    if not cookie then return { id = nil, name = "No Cookie" } end
    local cmd = string.format("curl -s -H 'Cookie: .ROBLOSECURITY=%s' -H 'User-Agent: Mozilla/5.0 (Android 10; Mobile)' https://users.roblox.com/v1/users/authenticated", cookie)
    local res = exec(cmd)
    
    local id = res:match('"id"%s*:%s*(%d+)')
    local name = res:match('"name"%s*:%s*"([^"]+)"')
    
    if id and name then
        return { id = tonumber(id), name = name }
    else
        return { id = nil, name = "Expired" }
    end
end

local function getCsrfToken(cookie)
    local cmd = string.format("curl -s -D - -o /dev/null -X POST -H 'Cookie: .ROBLOSECURITY=%s' -H 'User-Agent: Mozilla/5.0' https://auth.roblox.com/v2/logout", cookie)
    local res = exec(cmd)
    local token = res:match("[xX]%-[cC][sS][rR][fF]%-[tT][oO][kK][eE][nN]:%s*([^\r\n]+)")
    return token
end

local function checkRobloxPresence(cookie, userId, pkg)
    if not csrfTokens[pkg] then
        csrfTokens[pkg] = getCsrfToken(cookie)
    end
    
    local token = csrfTokens[pkg] or ""
    local data = '{"userIds":[' .. userId .. ']}'
    local cmd = string.format("curl -s -X POST -H 'Cookie: .ROBLOSECURITY=%s' -H 'x-csrf-token: %s' -H 'Content-Type: application/json' -d '%s' https://presence.roblox.com/v1/presence/users", cookie, token, data)
    
    local res = exec(cmd)
    
    if res:match("Token Validation Failed") then
        csrfTokens[pkg] = getCsrfToken(cookie)
        token = csrfTokens[pkg] or ""
        cmd = string.format("curl -s -X POST -H 'Cookie: .ROBLOSECURITY=%s' -H 'x-csrf-token: %s' -H 'Content-Type: application/json' -d '%s' https://presence.roblox.com/v1/presence/users", cookie, token, data)
        res = exec(cmd)
    end
    
    local presenceType = res:match('"userPresenceType"%s*:%s*(%d+)')
    if presenceType then
        local pType = tonumber(presenceType)
        return {
            isInGame = (pType == 2),
            presenceType = pType
        }
    end
    return { isInGame = false, presenceType = 0 }
end

local function stopPackage(pkg)
    os.execute("su -c 'am force-stop " .. pkg .. "' >/dev/null 2>&1")
end

local function releaseMemory()
    os.execute("su -c 'sync; echo 3 > /proc/sys/vm/drop_caches' >/dev/null 2>&1")
end

local function getAppRam(pkg)
    local pid = exec("su -c 'pidof " .. pkg .. "'")
    if pid == "" then return "0 MB" end
    
    local memInfo = exec("su -c 'dumpsys meminfo " .. pkg .. " | grep -E \"TOTAL:|TOTAL PSS:\"'")
    local kb = memInfo:match("(%d+)")
    if kb then
        local mb = tonumber(kb) / 1024
        return string.format("%.1f MB", mb)
    end
    return "N/A"
end

local function isAppRunning(pkg)
    local pid = exec("su -c 'pidof " .. pkg .. "'")
    return pid ~= ""
end

local function isUserInGame(pkg, cookie, userId)
    local now = os.time() * 1000
    local lastLaunch = launchTimers[pkg] or 0
    local timeSinceLaunch = now - lastLaunch
    
    if lastLaunch > 0 and timeSinceLaunch < PRESENCE_CHECK_DELAY then
        return { isInGame = true, status = "loading", timeRemaining = PRESENCE_CHECK_DELAY - timeSinceLaunch }
    end
    
    if cookie and userId then
        local presence = checkRobloxPresence(cookie, userId, pkg)
        if presence.isInGame then
            return { isInGame = true, status = "in-game", source = "roblox-api" }
        end
        if presence.presenceType == 0 then
            return { isInGame = false, status = "offline", source = "roblox-api" }
        end
    end
    
    return { isInGame = false, status = "unknown" }
end

local function isAppHealthy(pkg, cookie, userId)
    if not isAppRunning(pkg) then
        return { healthy = false, reason = "Process Not Running", ram = 0, priority = "critical" }
    end
    
    local ramStr = getAppRam(pkg)
    local ramValue = tonumber(ramStr:match("([%d%.]+)")) or 0
    
    if ramValue < MIN_RAM_THRESHOLD and ramValue > 0 then
        return { healthy = false, reason = string.format("Low RAM (%.1fMB) - Crash", ramValue), ram = ramValue, priority = "high" }
    end
    
    local presence = isUserInGame(pkg, cookie, userId)
    
    if presence.status == "loading" then
        return { healthy = true, reason = string.format("Loading (%ds left)", math.floor(presence.timeRemaining/1000)), ram = ramValue, priority = "normal", loading = true }
    end
    
    if not presence.isInGame then
        return { healthy = false, reason = "User Not In Game", ram = ramValue, priority = "high" }
    end
    
    return { healthy = true, reason = "Healthy", ram = ramValue, priority = "normal" }
end

local function autoArrangeXML(packages)
    print("📐 Mengatur XML (Grid " .. GRID_COLS .. "xN | Size " .. BOX_SIZE .. " | Gap Y " .. GAP_Y .. ")...")
    for index, pkg in ipairs(packages) do
        local idx0 = index - 1
        local col = idx0 % GRID_COLS
        local row = math.floor(idx0 / GRID_COLS)
        
        local left = col * (BOX_SIZE + GAP_X)
        local top = (row * (BOX_SIZE + GAP_Y)) + START_OFFSET_Y
        local right = left + BOX_SIZE
        local bottom = top + BOX_SIZE
        
        local prefsFile = "/data/data/" .. pkg .. "/shared_prefs/" .. pkg .. "_preferences.xml"
        local cmd = string.format([[su -c "
            sed -i 's|app_cloner_current_window_left\" value=\"[0-9]*|app_cloner_current_window_left\" value=\"%d|' %s;
            sed -i 's|app_cloner_current_window_top\" value=\"[0-9]*|app_cloner_current_window_top\" value=\"%d|' %s;
            sed -i 's|app_cloner_current_window_right\" value=\"[0-9]*|app_cloner_current_window_right\" value=\"%d|' %s;
            sed -i 's|app_cloner_current_window_bottom\" value=\"[0-9]*|app_cloner_current_window_bottom\" value=\"%d|' %s;
            sed -i 's|<int name=\"GraphicsQualityLevel\" value=\".*\" />|<int name=\"GraphicsQualityLevel\" value=\"1\" />|g' %s;
            chmod 660 %s
        "]], left, prefsFile, top, prefsFile, right, prefsFile, bottom, prefsFile, prefsFile, prefsFile)
        
        os.execute(cmd .. " >/dev/null 2>&1")
    end
    print("✅ Posisi XML tersimpan dan Grafis dipaksa rata kiri.\n")
end

local function launchPackage(pkg, url)
    local cmd = "su -c 'am start -n " .. pkg .. "/com.roblox.client.ActivityProtocolLaunch -f 0x18080000 -a android.intent.action.VIEW -d \"" .. url .. "\"'"
    os.execute(cmd .. " >/dev/null 2>&1")
    launchTimers[pkg] = os.time() * 1000
end

local function protectProcessFromLMK(pkg)
    local pid = exec("su -c 'pidof " .. pkg .. "'")
    if pid ~= "" then
        os.execute("su -c 'echo -900 > /proc/" .. pid .. "/oom_score_adj' >/dev/null 2>&1")
    end
end

local function fetchLinkCodes()
    print("🌐 Fetching codes from " .. config.MSRV_URL .. " ...")
    local res = exec("curl -s " .. config.MSRV_URL)
    local lines = split(res, "\n")
    local codes = {}
    for _, l in ipairs(lines) do
        local trimmed = l:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then
            table.insert(codes, trimmed)
        end
    end
    return codes
end

local function renderDashboard(codeDisplay, statusMsg)
    os.execute("clear")
    print("📱 SYS: BOOSTER ON 🔥 | LUA 5.3")
    print(string.format("📏 MODE: XML GRID (%d) | GAP Y: %dpx", GRID_COLS, GAP_Y))
    print(string.format("📊 STAT: %s | Code: %s\n", statusMsg, codeDisplay))
    
    -- SUSUNAN BARU AGAR RAPI DI HP: Pkg | User | RAM | State | Status (Emoji Paling Kanan)
    print(string.format("%-14s | %-10s | %-7s | %-6s | %s", "Package", "User", "RAM", "State", "Status"))
    print(string.rep("-", 60))
    
    local sorted_pkgs = {}
    for pkg in pairs(accountStates) do table.insert(sorted_pkgs, pkg) end
    table.sort(sorted_pkgs)
    
    for _, pkg in ipairs(sorted_pkgs) do
        local s = accountStates[pkg]
        
        -- Memotong string agar tidak melebar
        local shortPkg = pkg:gsub("com%.roblox%.client", "..client")
        shortPkg = string.sub(shortPkg, 1, 14)
        local shortUser = string.sub(s.username, 1, 10)
        local stateStr = s.isRunning and "Run" or "Wait"
        
        print(string.format("%-14s | %-10s | %-7s | %-6s | %s", shortPkg, shortUser, s.ramUsage, stateStr, s.serverStatus))
    end
    print("\n")
end

local function runSolver(fullCookie, accPkg)
    local encodedCookie = urlencode(fullCookie)
    local cmd = string.format("curl -s '%s?cookie=%s&yeskey=%s'", SOLVER_API_URL, encodedCookie, config.YES_KEY)
    local res = exec(cmd)
    
    if res and res ~= "" then
        accountStates[accPkg].serverStatus = "✅ Solver Passed"
        return true
    else
        accountStates[accPkg].serverStatus = "❌ Setup/Server Error"
        return false
    end
end

-- --- MAIN LOGIC ---
applyPerformanceTweaks()

local packages = getPackages()
if #packages == 0 then
    print("❌ No Roblox packages found.")
    os.exit(0)
end

local accounts = {}
for _, pkg in ipairs(packages) do
    print("⏳ Membaca " .. pkg .. "...")
    
    local cookie = getRobloxCookie(pkg)
    local userInfo = getUserInfo(cookie)
    
    if userInfo.id and userInfo.name ~= "Expired" then
        table.insert(accounts, { pkg = pkg, cookie = cookie, userId = userInfo.id, username = userInfo.name })
        accountStates[pkg] = { username = userInfo.name, isRunning = false, serverStatus = "Waiting...", ramUsage = "0 MB" }
        csrfTokens[pkg] = getCsrfToken(cookie)
    else
        print("⚠️ Skipping " .. pkg .. ": Cookie Expired/Invalid.")
    end
end

if #accounts == 0 then
    print("\n❌ Tidak ada akun valid untuk dijalankan.")
    os.exit(0)
end

print("\n✅ Loaded " .. #accounts .. " valid accounts.\n")
sleep(1000)
os.execute("clear")

local codes = fetchLinkCodes()
if #codes == 0 then
    print("⚠️ No codes found from MSRV.")
    os.exit(1)
end

local cleanCode = ""
if not AUTO_RANDOM_CODE then
    print("\n📜 Available Codes:")
    for i, c in ipairs(codes) do
        print(string.format("[%d] %s", i, c))
    end
    io.write("\n👉 Choose Server: ")
    local sel = tonumber(io.read())
    if not sel or sel < 1 or sel > #codes then
        print("❌ Invalid selection.")
        os.exit(1)
    end
    cleanCode = codes[sel]
end

os.execute("clear")
local codeDisplay = AUTO_RANDOM_CODE and "RANDOM" or "..." .. string.sub(cleanCode, -4)
local pkgs_only = {}
for _, a in ipairs(accounts) do table.insert(pkgs_only, a.pkg) end
autoArrangeXML(pkgs_only)

-- --- FASE 1: LAUNCH ---
for _, acc in ipairs(accounts) do
    accountStates[acc.pkg].serverStatus = "Solving Captcha"
    renderDashboard(codeDisplay, "🤖 Mengirim cookie " .. acc.username .. " ke Solver...")
    runSolver(acc.cookie, acc.pkg)
    renderDashboard(codeDisplay, "✅ Solver selesai untuk " .. acc.username .. ". Launching...")
    sleep(1500)
    
    local currentCode = AUTO_RANDOM_CODE and codes[math.random(1, #codes)] or cleanCode
    if currentCode:match("linkCode=") then
        currentCode = currentCode:match("linkCode=([^&]+)")
    end
    
    local finalLaunchUrl = string.format("roblox://placeID=%s&linkCode=%s", config.PLACE_ID, currentCode)
    local isStable = false
    
    while not isStable do
        stopPackage(acc.pkg)
        releaseMemory()
        sleep(1500)
        
        launchPackage(acc.pkg, finalLaunchUrl)
        accountStates[acc.pkg].isRunning = true
        accountStates[acc.pkg].serverStatus = "Launching..."
        
        sleep(3000)
        protectProcessFromLMK(acc.pkg)
        
        local crashed = false
        for sec = 1, 60 do
            if sec % 5 == 0 then accountStates[acc.pkg].ramUsage = getAppRam(acc.pkg) end
            renderDashboard(codeDisplay, string.format("⏳ %s Stabilizing... (%ds/60s)", acc.username, sec))
            sleep(1000)
            
            local healthCheck = isAppHealthy(acc.pkg, acc.cookie, acc.userId)
            if not healthCheck.healthy then
                accountStates[acc.pkg].serverStatus = "Crash: " .. healthCheck.reason
                renderDashboard(codeDisplay, string.format("⚠️ %s %s! Buka ulang...", acc.username, healthCheck.reason))
                crashed = true
                sleep(3000)
                break
            elseif healthCheck.loading then
                accountStates[acc.pkg].serverStatus = "⏳ " .. healthCheck.reason
            end
        end
        
        if not crashed then
            accountStates[acc.pkg].serverStatus = "In Game 🎮"
            renderDashboard(codeDisplay, "✅ " .. acc.username .. " Stabil! Lanjut...")
            isStable = true
            sleep(2000)
        end
    end
end

-- --- FASE 2: MONITORING ---
releaseMemory()

while true do
    local anyCrashed = false
    
    for _, acc in ipairs(accounts) do
        renderDashboard(codeDisplay, "🔒 Cek cookie " .. acc.username .. "...")
        local cookieStatus = getUserInfo(acc.cookie)
        
        if not cookieStatus.id or cookieStatus.name == "Expired" then
            accountStates[acc.pkg].serverStatus = "❌ Banned (403)"
            accountStates[acc.pkg].isRunning = false
            accountStates[acc.pkg].ramUsage = "0 MB"
            stopPackage(acc.pkg)
            sleep(2000)
            goto continue
        end
        
        renderDashboard(codeDisplay, "👀 Cek status " .. acc.username .. "...")
        sleep(1500)
        accountStates[acc.pkg].ramUsage = getAppRam(acc.pkg)
        
        local healthCheck = isAppHealthy(acc.pkg, acc.cookie, acc.userId)
        
        if healthCheck.healthy then
            accountStates[acc.pkg].isRunning = true
            if healthCheck.loading then
                accountStates[acc.pkg].serverStatus = "⏳ " .. healthCheck.reason
            else
                accountStates[acc.pkg].serverStatus = "In Game 🎮"
            end
        else
            anyCrashed = true
            local isStable = false
            local currentCrashReason = healthCheck.reason
            
            while not isStable do
                accountStates[acc.pkg].isRunning = false
                accountStates[acc.pkg].serverStatus = "⚠️ " .. currentCrashReason
                renderDashboard(codeDisplay, "⚠️ " .. acc.username .. " Crash - Auto-Reopen...")
                
                stopPackage(acc.pkg)
                releaseMemory()
                sleep(1500)
                
                runSolver(acc.cookie, acc.pkg)
                
                local currentCode = AUTO_RANDOM_CODE and codes[math.random(1, #codes)] or cleanCode
                if currentCode:match("linkCode=") then currentCode = currentCode:match("linkCode=([^&]+)") end
                
                local finalLaunchUrl = string.format("roblox://placeID=%s&linkCode=%s", config.PLACE_ID, currentCode)
                launchPackage(acc.pkg, finalLaunchUrl)
                
                sleep(3000)
                protectProcessFromLMK(acc.pkg)
                
                local crashedDuringRec = false
                for w = 1, 60 do
                    if w % 5 == 0 then accountStates[acc.pkg].ramUsage = getAppRam(acc.pkg) end
                    renderDashboard(codeDisplay, string.format("⏳ Re-open %s... (%ds/60s)", acc.username, w))
                    sleep(1000)
                    
                    local recoveryHealth = isAppHealthy(acc.pkg, acc.cookie, acc.userId)
                    if not recoveryHealth.healthy then
                        currentCrashReason = recoveryHealth.reason
                        accountStates[acc.pkg].serverStatus = "Crash: " .. currentCrashReason
                        crashedDuringRec = true
                        sleep(3000)
                        break
                    elseif recoveryHealth.loading then
                        accountStates[acc.pkg].serverStatus = "⏳ " .. recoveryHealth.reason
                    end
                end
                
                if not crashedDuringRec then
                    accountStates[acc.pkg].isRunning = true
                    accountStates[acc.pkg].serverStatus = "In Game 🎮"
                    isStable = true
                    sleep(2000)
                end
            end
        end
        ::continue::
    end
    
    if anyCrashed then releaseMemory() end
    renderDashboard(codeDisplay, "👀 Monitoring Selesai | Cek lagi " .. (CHECK_INTERVAL/1000) .. "s")
    sleep(CHECK_INTERVAL)
end
