#!/usr/bin/env lua5.3

local os = require("os")
local io = require("io")

-- BERSIHKAN LAYAR
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
    return (result:gsub("^%s*(.-)%s*$", "%1"))
end

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
    print("🚀 SETUP KONFIGURASI:")
    print("---------------------------------")
    
    io.write("🔑 YES_KEY Solver  : ")
    config.YES_KEY = io.read()
    
    io.write("🎮 PLACE_ID        : ")
    local pid_input = io.read()
    config.PLACE_ID = (pid_input == "" or pid_input == nil) and "121864768012064" or pid_input
    
    io.write("🌐 MSRV_URL (Link) : ")
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
    print("\n✅ Konfigurasi tersimpan!\n")
    sleep(1000)
    os.execute("clear")
end

-- --- CONFIGURATION LENGKAP ---
local SOLVER_API_URL = "http://134.199.219.230:3000/solve"
local AUTO_RANDOM_CODE = false

local GRID_COLS = 3
local BOX_SIZE = 150
local START_OFFSET_Y = 80
local GAP_X = 5
local GAP_Y = 60

local CHECK_INTERVAL = 60000 
local MIN_RAM_THRESHOLD = 10
local PRESENCE_CHECK_DELAY = 60000
local DEBUG_MODE = false

local accountStates = {}
local csrfTokens = {}
local launchTimers = {}

-- --- FUNGSI SISTEM ---
local function applyPerformanceTweaks()
    print("⚙️  Menerapkan Tweak Performa...")
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
    print("✅ Tweak Selesai!\n")
end

local function getPackages()
    local output = exec("pm list packages | grep roblox")
    local packages = {}
    for pkg in output:gmatch("package:([^\n]+)") do
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
    local cmd = string.format("curl -s -H 'Cookie: .ROBLOSECURITY=%s' -H 'User-Agent: Mozilla/5.0' https://users.roblox.com/v1/users/authenticated", cookie)
    local res = exec(cmd)
    
    local id = res:match('"id"%s*:%s*(%d+)')
    local name = res:match('"name"%s*:%s*"([^"]+)"')
    if id and name then return { id = tonumber(id), name = name } else return { id = nil, name = "Expired" } end
end

local function getCsrfToken(cookie)
    local cmd = string.format("curl -s -D - -o /dev/null -X POST -H 'Cookie: .ROBLOSECURITY=%s' -H 'User-Agent: Mozilla/5.0' https://auth.roblox.com/v2/logout", cookie)
    local res = exec(cmd)
    return res:match("[xX]%-[cC][sS][rR][fF]%-[tT][oO][kK][eE][nN]:%s*([^\r\n]+)")
end

local function checkRobloxPresence(cookie, userId, pkg)
    if not csrfTokens[pkg] then csrfTokens[pkg] = getCsrfToken(cookie) end
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
        return { isInGame = (pType == 2), presenceType = pType }
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
    if kb then return string.format("%.1f MB", tonumber(kb) / 1024) end
    return "N/A"
end

local function isAppRunning(pkg)
    return exec("su -c 'pidof " .. pkg .. "'") ~= ""
end

local function isUserInGame(pkg, cookie, userId)
    local timeSinceLaunch = (os.time() * 1000) - (launchTimers[pkg] or 0)
    if (launchTimers[pkg] or 0) > 0 and timeSinceLaunch < PRESENCE_CHECK_DELAY then
        return { isInGame = true, status = "loading", timeRemaining = PRESENCE_CHECK_DELAY - timeSinceLaunch }
    end
    
    if cookie and userId then
        local presence = checkRobloxPresence(cookie, userId, pkg)
        if presence.isInGame then return { isInGame = true, status = "in-game" } end
        if presence.presenceType == 0 then return { isInGame = false, status = "offline" } end
    end
    return { isInGame = false, status = "unknown" }
end

local function isAppHealthy(pkg, cookie, userId)
    if not isAppRunning(pkg) then return { healthy = false, reason = "App Closed", ram = 0 } end
    
    local ramStr = getAppRam(pkg)
    local ramValue = tonumber(ramStr:match("([%d%.]+)")) or 0
    if ramValue < MIN_RAM_THRESHOLD and ramValue > 0 then return { healthy = false, reason = "Low RAM Crash", ram = ramValue } end
    
    local presence = isUserInGame(pkg, cookie, userId)
    if presence.status == "loading" then return { healthy = true, reason = "Loading...", ram = ramValue, loading = true } end
    if not presence.isInGame then return { healthy = false, reason = "Not In Game", ram = ramValue } end
    
    return { healthy = true, reason = "Healthy", ram = ramValue }
end

local function autoArrangeXML(packages)
    for index, pkg in ipairs(packages) do
        local idx0 = index - 1
        local left, top = (idx0 % GRID_COLS) * (BOX_SIZE + GAP_X), math.floor(idx0 / GRID_COLS) * (BOX_SIZE + GAP_Y) + START_OFFSET_Y
        local right, bottom = left + BOX_SIZE, top + BOX_SIZE
        local prefsFile = "/data/data/" .. pkg .. "/shared_prefs/" .. pkg .. "_preferences.xml"
        local cmd = string.format([[su -c "sed -i 's|app_cloner_current_window_left\" value=\"[0-9]*|app_cloner_current_window_left\" value=\"%d|' %s; sed -i 's|app_cloner_current_window_top\" value=\"[0-9]*|app_cloner_current_window_top\" value=\"%d|' %s; sed -i 's|app_cloner_current_window_right\" value=\"[0-9]*|app_cloner_current_window_right\" value=\"%d|' %s; sed -i 's|app_cloner_current_window_bottom\" value=\"[0-9]*|app_cloner_current_window_bottom\" value=\"%d|' %s; sed -i 's|<int name=\"GraphicsQualityLevel\" value=\".*\" />|<int name=\"GraphicsQualityLevel\" value=\"1\" />|g' %s; chmod 660 %s"]], left, prefsFile, top, prefsFile, right, prefsFile, bottom, prefsFile, prefsFile, prefsFile)
        os.execute(cmd .. " >/dev/null 2>&1")
    end
end

local function launchPackage(pkg, url)
    os.execute("su -c 'am start -n " .. pkg .. "/com.roblox.client.ActivityProtocolLaunch -f 0x18080000 -a android.intent.action.VIEW -d \"" .. url .. "\" >/dev/null 2>&1'")
    launchTimers[pkg] = os.time() * 1000
end

local function protectProcessFromLMK(pkg)
    local pid = exec("su -c 'pidof " .. pkg .. "'")
    if pid ~= "" then os.execute("su -c 'echo -900 > /proc/" .. pid .. "/oom_score_adj' >/dev/null 2>&1") end
end

local function fetchLinkCodes()
    print("🌐 Mengunduh kode server...")
    local res = exec("curl -sL '" .. config.MSRV_URL .. "'")
    local codes = {}
    -- Fix CRLF: Membersihkan setiap baris dari karakter aneh dan spasi
    for line in res:gmatch("[^\r\n]+") do
        local clean_code = line:gsub("[%c%s]", "") 
        if clean_code ~= "" and not clean_code:match("<html") then
            table.insert(codes, clean_code)
        end
    end
    return codes
end

-- TAMPILAN DASHBOARD BARU (LEBIH RAPI DI HP)
local function renderDashboard(codeDisplay, statusMsg)
    os.execute("clear")
    print("=====================================")
    print(" 🔥 LUA SYSTEM BOOSTER - TERMUX")
    print("=====================================")
    print(string.format(" 🎯 Target Code : %s", codeDisplay))
    print(string.format(" 📌 Status      : %s", statusMsg))
    print("-------------------------------------")
    
    local sorted_pkgs = {}
    for pkg in pairs(accountStates) do table.insert(sorted_pkgs, pkg) end
    table.sort(sorted_pkgs)
    
    for _, pkg in ipairs(sorted_pkgs) do
        local s = accountStates[pkg]
        local shortUser = string.sub(s.username, 1, 12)
        local stateIcon = s.isRunning and "🟢 RUN " or "⚪ WAIT"
        
        -- Layout 2 baris agar muat di layar sempit
        print(string.format(" 👤 %-12s | %s | 💾 %s", shortUser, stateIcon, s.ramUsage))
        print(string.format("    └─ 💬 %s\n", s.serverStatus))
    end
    print("=====================================\n")
end

local function runSolver(fullCookie, accPkg)
    local cmd = string.format("curl -s '%s?cookie=%s&yeskey=%s'", SOLVER_API_URL, urlencode(fullCookie), config.YES_KEY)
    local res = exec(cmd)
    if res and res ~= "" then
        accountStates[accPkg].serverStatus = "✅ Captcha Terselesaikan"
        return true
    else
        accountStates[accPkg].serverStatus = "❌ Error API Solver"
        return false
    end
end

-- --- MAIN LOGIC ---
applyPerformanceTweaks()

local packages = getPackages()
if #packages == 0 then print("❌ Roblox tidak ditemukan."); os.exit(0) end

local accounts = {}
for _, pkg in ipairs(packages) do
    io.write("⏳ Membaca " .. pkg .. "...\r")
    io.flush()
    local cookie = getRobloxCookie(pkg)
    local userInfo = getUserInfo(cookie)
    if userInfo.id and userInfo.name ~= "Expired" then
        table.insert(accounts, { pkg = pkg, cookie = cookie, userId = userInfo.id, username = userInfo.name })
        accountStates[pkg] = { username = userInfo.name, isRunning = false, serverStatus = "Menunggu Giliran...", ramUsage = "0 MB" }
        csrfTokens[pkg] = getCsrfToken(cookie)
    end
end

if #accounts == 0 then print("\n❌ Tidak ada akun valid."); os.exit(0) end
print("\n✅ Berhasil meload " .. #accounts .. " akun.\n")

local codes = fetchLinkCodes()
if #codes == 0 then print("⚠️ Gagal mendapat kode server."); os.exit(1) end

local cleanCode = ""
if not AUTO_RANDOM_CODE then
    -- TAMPILAN PEMILIHAN SERVER YANG RAPI
    print("\n📜 DAFTAR SERVER TERSEDIA:")
    print("---------------------------------")
    for i, c in ipairs(codes) do
        -- Truncate teks agar rapi
        local display_c = #c > 16 and (c:sub(1, 6) .. "..." .. c:sub(-6)) or c
        print(string.format(" [%2d] Kode: %s", i, display_c))
    end
    print("---------------------------------")
    io.write("👉 Pilih nomor server [1-"..#codes.."]: ")
    
    local sel = tonumber(io.read())
    if not sel or sel < 1 or sel > #codes then print("❌ Pilihan tidak valid."); os.exit(1) end
    cleanCode = codes[sel]
end

local codeDisplay = AUTO_RANDOM_CODE and "RANDOM" or "..." .. string.sub(cleanCode, -5)
local pkgs_only = {}
for _, a in ipairs(accounts) do table.insert(pkgs_only, a.pkg) end
autoArrangeXML(pkgs_only)

-- --- FASE 1: LAUNCH ---
for _, acc in ipairs(accounts) do
    accountStates[acc.pkg].serverStatus = "Memproses Captcha ⏳"
    renderDashboard(codeDisplay, "Mengirim cookie ke API...")
    runSolver(acc.cookie, acc.pkg)
    renderDashboard(codeDisplay, "Meluncurkan Roblox...")
    sleep(1500)
    
    local finalLaunchUrl = string.format("roblox://placeID=%s&linkCode=%s", config.PLACE_ID, (cleanCode:match("linkCode=([^&]+)") or cleanCode))
    local isStable = false
    
    while not isStable do
        stopPackage(acc.pkg)
        releaseMemory()
        sleep(1000)
        
        launchPackage(acc.pkg, finalLaunchUrl)
        accountStates[acc.pkg].isRunning = true
        accountStates[acc.pkg].serverStatus = "Membuka Aplikasi..."
        
        sleep(3000)
        protectProcessFromLMK(acc.pkg)
        
        local crashed = false
        for sec = 1, 60 do
            if sec % 5 == 0 then accountStates[acc.pkg].ramUsage = getAppRam(acc.pkg) end
            renderDashboard(codeDisplay, string.format("Stabilisasi %s (%ds/60s)", acc.username, sec))
            sleep(1000)
            
            local healthCheck = isAppHealthy(acc.pkg, acc.cookie, acc.userId)
            if not healthCheck.healthy then
                accountStates[acc.pkg].serverStatus = "⚠️ Crash: " .. healthCheck.reason
                renderDashboard(codeDisplay, "Terjadi Crash. Reopen...")
                crashed = true
                sleep(2000)
                break
            elseif healthCheck.loading then
                accountStates[acc.pkg].serverStatus = "⏳ Sedang Loading..."
            end
        end
        
        if not crashed then
            accountStates[acc.pkg].serverStatus = "🎮 Stabil di Dalam Game"
            isStable = true
            sleep(1500)
        end
    end
end

-- --- FASE 2: MONITORING ---
releaseMemory()

while true do
    local anyCrashed = false
    for _, acc in ipairs(accounts) do
        renderDashboard(codeDisplay, "Monitoring rutin...")
        
        local cookieStatus = getUserInfo(acc.cookie)
        if not cookieStatus.id or cookieStatus.name == "Expired" then
            accountStates[acc.pkg].serverStatus = "❌ Akun Ter-Banned (403)"
            accountStates[acc.pkg].isRunning = false
            stopPackage(acc.pkg)
            goto continue
        end
        
        sleep(1000)
        accountStates[acc.pkg].ramUsage = getAppRam(acc.pkg)
        local healthCheck = isAppHealthy(acc.pkg, acc.cookie, acc.userId)
        
        if healthCheck.healthy then
            accountStates[acc.pkg].isRunning = true
            accountStates[acc.pkg].serverStatus = healthCheck.loading and "⏳ Proses Loading..." or "🎮 Aman di Dalam Game"
        else
            anyCrashed = true
            local isStable = false
            while not isStable do
                accountStates[acc.pkg].isRunning = false
                accountStates[acc.pkg].serverStatus = "⚠️ Reconnecting..."
                renderDashboard(codeDisplay, "Memulihkan koneksi...")
                
                stopPackage(acc.pkg)
                releaseMemory()
                sleep(1000)
                
                runSolver(acc.cookie, acc.pkg)
                local finalLaunchUrl = string.format("roblox://placeID=%s&linkCode=%s", config.PLACE_ID, (cleanCode:match("linkCode=([^&]+)") or cleanCode))
                launchPackage(acc.pkg, finalLaunchUrl)
                
                sleep(3000)
                protectProcessFromLMK(acc.pkg)
                
                local crashedDuringRec = false
                for w = 1, 60 do
                    if w % 5 == 0 then accountStates[acc.pkg].ramUsage = getAppRam(acc.pkg) end
                    renderDashboard(codeDisplay, string.format("Pemulihan %s (%ds/60s)", acc.username, w))
                    sleep(1000)
                    
                    local recoveryHealth = isAppHealthy(acc.pkg, acc.cookie, acc.userId)
                    if not recoveryHealth.healthy then
                        accountStates[acc.pkg].serverStatus = "⚠️ Gagal pulih. Coba lagi..."
                        crashedDuringRec = true
                        sleep(2000)
                        break
                    end
                end
                if not crashedDuringRec then
                    accountStates[acc.pkg].isRunning = true
                    accountStates[acc.pkg].serverStatus = "🎮 Berhasil Pulih"
                    isStable = true
                end
            end
        end
        ::continue::
    end
    
    if anyCrashed then releaseMemory() end
    renderDashboard(codeDisplay, "Standby | Cek lagi " .. (CHECK_INTERVAL/1000) .. "s")
    sleep(CHECK_INTERVAL)
end
