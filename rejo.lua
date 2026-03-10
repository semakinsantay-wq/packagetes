#!/usr/bin/env lua5.3

-- ==========================================
-- CONFIGURATION
-- ==========================================
local MSRV_URL = "https://ghostbin.axel.org/paste/nk4fh/raw"
local PLACE_ID = "121864768012064"

local SOLVER_API_URL = "http://134.199.219.230:3000/solve"
local YES_KEY = "f7a1a420f1ae90ca6c9d4d71437262edbd0ea31237995"

local AUTO_RECONNECT = true
local AUTO_RANDOM_CODE = false

-- GRID SETTINGS (XML)
local GRID_COLS = 3
local BOX_SIZE = 150
local START_OFFSET_Y = 50
local GAP_X = 5
local GAP_Y = 60

-- TIMING & DETEKSI
local CHECK_INTERVAL = 60000 -- 1 menit (ms)
local PRESENCE_CHECK_DELAY = 60000
local MIN_RAM_THRESHOLD = 10 -- MB

local DEBUG_MODE = false

-- Data Storage
local accountStates = {}
local csrfTokens = {}
local launchTimers = {}
local accounts = {}
local codesList = {}
local currentCleanCode = ""

-- ==========================================
-- HELPER FUNCTIONS
-- ==========================================
local function sleep(ms)
    os.execute("sleep " .. tonumber(ms / 1000))
end

local function execShell(cmd)
    local handle = io.popen(cmd)
    if not handle then return "" end
    local result = handle:read("*a")
    handle:close()
    return result:gsub("^%s*(.-)%s*$", "%1") -- trim
end

local function execRoot(cmd)
    -- Menggunakan su -c dan escape quotes
    local safeCmd = cmd:gsub("'", "'\\''")
    return execShell("su -c '" .. safeCmd .. "'")
end

local function padRight(str, len)
    str = tostring(str)
    if #str >= len then return str:sub(1, len) end
    return str .. string.rep(" ", len - #str)
end

-- ==========================================
-- SYSTEM & TWEAKS
-- ==========================================
local function applyPerformanceTweaks()
    print("\n🚀 Menerapkan Tweak Performa (CPU, Thermal, UI)...")
    local tweakScript = [[
        for i in 0 1 2 3 4 5 6 7; do
            echo 1 > /sys/devices/system/cpu/cpu$i/online 2>/dev/null
            echo performance > /sys/devices/system/cpu/cpu$i/cpufreq/scaling_governor 2>/dev/null
        done
        stop thermal-engine 2>/dev/null
        stop thermald 2>/dev/null
        killall -9 thermal-engine thermald 2>/dev/null
        echo 10 > /proc/sys/vm/swappiness 2>/dev/null
        settings put global window_animation_scale 0 2>/dev/null
        settings put global transition_animation_scale 0 2>/dev/null
        settings put global animator_duration_scale 0 2>/dev/null
    ]]
    execRoot(tweakScript)
    print("   ✅ Tweak Performa Aktif!")
end

local function releaseMemory()
    execRoot("sync; echo 3 > /proc/sys/vm/drop_caches")
end

-- ==========================================
-- ROBLOX FUNCTIONS
-- ==========================================
local function getPackages()
    local result = execShell("pm list packages | grep roblox")
    local pkgs = {}
    for line in result:gmatch("[^\r\n]+") do
        local pkg = line:gsub("package:", ""):gsub("%s+", "")
        if pkg ~= "" then table.insert(pkgs, pkg) end
    end
    table.sort(pkgs)
    return pkgs
end

local TERMUX_PREFIX = "/data/data/com.termux/files/usr/bin"
local SQLITE_PATH = TERMUX_PREFIX .. "/sqlite3"

local function getRobloxCookie(pkg)
    -- 1. Gunakan folder HOME termux, BUKAN /sdcard/ untuk menghindari masalah akses Android
    local homeDir = os.getenv("HOME") or "/data/data/com.termux/files/home"
    local tempPath = homeDir .. "/temp_cookie_" .. pkg .. ".db"
    local sourcePath = "/data/data/" .. pkg .. "/app_webview/Default/Cookies"

    -- 2. Salin database menggunakan root dan ubah izinnya agar bisa dibaca Termux biasa
    local cpCmd = string.format("su -c 'cp \"%s\" \"%s\" && chmod 777 \"%s\"'", sourcePath, tempPath, tempPath)
    os.execute(cpCmd)

    -- 3. Eksekusi sqlite3 TANPA akses root
    -- Ini mencegah error command not found dan error tanda kutip (escaping)
    local query = "SELECT value FROM cookies WHERE name = '.ROBLOSECURITY' LIMIT 1"
    local sqliteCmd = string.format('%s "%s" "%s"', SQLITE_PATH, tempPath, query)
    
    local handle = io.popen(sqliteCmd)
    local cookie = ""
    if handle then
        cookie = handle:read("*a")
        handle:close()
    end

    -- 4. Hapus file sementara
    os.execute(string.format("su -c 'rm \"%s\"'", tempPath))

    -- 5. Bersihkan karakter enter/spasi yang terikut (Trim)
    cookie = cookie:gsub("^%s*(.-)%s*$", "%1")

    -- 6. Validasi dan Format
    if cookie and cookie ~= "" then
        if cookie:sub(1,1) ~= "_" then 
            cookie = "_" .. cookie 
        end
        return cookie
    end
    
    return nil
end

local function getUserInfo(cookie)
    if not cookie then return nil, "No Cookie" end
    local cmd = string.format('curl -s -H "Cookie: .ROBLOSECURITY=%s" "https://users.roblox.com/v1/users/authenticated"', cookie)
    local res = execShell(cmd)
    
    local id = res:match('"id":%s*(%d+)')
    local name = res:match('"name":%s*"([^"]+)"')
    
    if id and name then
        return id, name
    end
    return nil, "Expired"
end

local function getCsrfToken(cookie)
    local cmd = string.format('curl -s -I -X POST -H "Cookie: .ROBLOSECURITY=%s" "https://auth.roblox.com/v2/logout"', cookie)
    local res = execShell(cmd)
    local token = res:match("[Xx]%-[Cc]srf%-[Tt]oken:%s*([%w%-_]+)")
    return token
end

local function checkRobloxPresence(cookie, userId, pkg)
    if not csrfTokens[pkg] then
        csrfTokens[pkg] = getCsrfToken(cookie)
    end
    
    local data = '{"userIds":[' .. userId .. ']}'
    local cmd = string.format('curl -s -X POST -H "Cookie: .ROBLOSECURITY=%s" -H "x-csrf-token: %s" -H "Content-Type: application/json" -d \'%s\' "https://presence.roblox.com/v1/presence/users"', cookie, csrfTokens[pkg] or "", data)
    
    local res = execShell(cmd)
    
    if res:match("Token Validation Failed") or res:match("403 Forbidden") then
        csrfTokens[pkg] = getCsrfToken(cookie)
        cmd = string.format('curl -s -X POST -H "Cookie: .ROBLOSECURITY=%s" -H "x-csrf-token: %s" -H "Content-Type: application/json" -d \'%s\' "https://presence.roblox.com/v1/presence/users"', cookie, csrfTokens[pkg] or "", data)
        res = execShell(cmd)
    end

    local presenceType = res:match('"userPresenceType":%s*(%d+)')
    if presenceType then
        return tonumber(presenceType) == 2, tonumber(presenceType)
    end
    return false, 0
end

local function getAppRam(pkg)
    local pid = execRoot("pidof " .. pkg)
    if pid == "" then return "0" end
    
    local memInfo = execRoot("dumpsys meminfo " .. pkg .. " | grep -E 'TOTAL:|TOTAL PSS:'")
    local kb = memInfo:match("(%d+)")
    if kb then
        return string.format("%.1f", tonumber(kb) / 1024)
    end
    return "0"
end

local function isAppHealthy(pkg, cookie, userId)
    local pid = execRoot("pidof " .. pkg)
    if pid == "" then return false, "Process Not Running", "0" end
    
    local ramValueStr = getAppRam(pkg)
    local ramValue = tonumber(ramValueStr) or 0
    
    if ramValue < MIN_RAM_THRESHOLD and ramValue > 0 then
        return false, "Low RAM (" .. ramValueStr .. "MB)", ramValueStr
    end
    
    local lastLaunch = launchTimers[pkg] or 0
    local timeSinceLaunch = (os.time() * 1000) - lastLaunch
    
    if timeSinceLaunch < PRESENCE_CHECK_DELAY then
        local left = math.floor((PRESENCE_CHECK_DELAY - timeSinceLaunch) / 1000)
        return true, "Loading (" .. left .. "s left)", ramValueStr, true
    end
    
    local isInGame, pType = checkRobloxPresence(cookie, userId, pkg)
    if not isInGame then
        return false, "User Not In Game", ramValueStr
    end
    
    return true, "Healthy", ramValueStr, false
end

-- ==========================================
-- APP CONTROL
-- ==========================================
local function stopPackage(pkg)
    execRoot("am force-stop " .. pkg)
end

local function launchPackage(pkg, url)
    local cmd = string.format('am start -n %s/com.roblox.client.ActivityProtocolLaunch -f 0x18080000 -a android.intent.action.VIEW -d "%s"', pkg, url)
    execRoot(cmd)
    launchTimers[pkg] = os.time() * 1000
end

local function runSolver(cookie, pkg)
    local encodedCookie = cookie:gsub("%%", "%%25"):gsub("=", "%%3D"):gsub(";", "%%3B"):gsub(" ", "%%20")
    local cmd = string.format('curl -s -m 30 "%s?cookie=%s&yeskey=%s"', SOLVER_API_URL, encodedCookie, YES_KEY)
    execShell(cmd)
    accountStates[pkg].serverStatus = "✅ Solver Passed"
end

local function autoArrangeXML()
    print("\n📐 Mengatur XML (Grid " .. GRID_COLS .. "xN)...")
    for i, acc in ipairs(accounts) do
        local index = i - 1
        local col = index % GRID_COLS
        local row = math.floor(index / GRID_COLS)

        local left = col * (BOX_SIZE + GAP_X)
        local top = (row * (BOX_SIZE + GAP_Y)) + START_OFFSET_Y
        local right = left + BOX_SIZE
        local bottom = top + BOX_SIZE

        local prefsFile = "/data/data/" .. acc.pkg .. "/shared_prefs/" .. acc.pkg .. "_preferences.xml"
        
        local sedCmd = string.format([[
            sed -i 's|app_cloner_current_window_left" value="[0-9]*|app_cloner_current_window_left" value="%d|' %s;
            sed -i 's|app_cloner_current_window_top" value="[0-9]*|app_cloner_current_window_top" value="%d|' %s;
            sed -i 's|app_cloner_current_window_right" value="[0-9]*|app_cloner_current_window_right" value="%d|' %s;
            sed -i 's|app_cloner_current_window_bottom" value="[0-9]*|app_cloner_current_window_bottom" value="%d|' %s;
            sed -i 's|<int name="GraphicsQualityLevel" value=".*" />|<int name="GraphicsQualityLevel" value="1" />|g' %s;
        ]], left, prefsFile, top, prefsFile, right, prefsFile, bottom, prefsFile, prefsFile)
        
        execRoot(sedCmd)
    end
end

-- ==========================================
-- UI / DASHBOARD
-- ==========================================
local function renderDashboard(codeDisplay, statusMessage)
    os.execute("clear")
    print(string.format("📱 SYSTEM: BOOSTER: ON 🔥"))
    print(string.format("📏 MODE: XML GRID (%d cols) | DETEKSI: ROBLOX API (1m cooldown)", GRID_COLS))
    print(string.format("📊 STATUS: %s | Mode: CONTINUOUS | Code: %s\n", statusMessage, codeDisplay))
    
    print(string.format("%s | %s | %s | %s | %s | %s", 
        padRight("Package", 18), padRight("User", 12), padRight("State", 8), padRight("Status", 22), padRight("RAM", 8), "Action"))
    print(string.rep("-", 85))
    
    for _, acc in ipairs(accounts) do
        local state = accountStates[acc.pkg]
        local shortPkg = acc.pkg:gsub("com.roblox.client", "...client")
        local runStr = state.isRunning and "Run 🟢" or "Wait ⚪"
        
        print(string.format("%s | %s | %s | %s | %s | %s",
            padRight(shortPkg, 18),
            padRight(state.username:sub(1,12), 12),
            padRight(runStr, 8),
            padRight(state.serverStatus, 22),
            padRight(state.ramUsage .. " MB", 8),
            state.action
        ))
    end
    print("\n")
end

-- ==========================================
-- MAIN LOGIC
-- ==========================================
local function main()
    os.execute("clear")
    print("🚀 Initializing Manager (LUA 5.3 Edition)...")
    applyPerformanceTweaks()
    
    local pkgs = getPackages()
    if #pkgs == 0 then
        print("❌ No Roblox packages found.")
        os.exit(0)
    end
    
    for _, pkg in ipairs(pkgs) do
        io.write("Reading " .. pkg .. "... \r")
        local cookie = getRobloxCookie(pkg)
        local id, name = getUserInfo(cookie)
        
        if id and name ~= "Expired" then
            table.insert(accounts, {pkg = pkg, cookie = cookie, userId = id, username = name})
            accountStates[pkg] = {
                username = name, isRunning = false, serverStatus = "Waiting...", ramUsage = "0", action = "-"
            }
            csrfTokens[pkg] = getCsrfToken(cookie)
        else
            print("\n⚠️ Skipping " .. pkg .. ": Cookie Expired/Invalid.")
        end
    end
    
    if #accounts == 0 then
        print("❌ Tidak ada akun valid.")
        os.exit(0)
    end
    print("\n✅ Loaded " .. #accounts .. " valid accounts.")
    
    -- Fetch Codes
    print("🌐 Fetching codes...")
    local codesRaw = execShell('curl -s "' .. MSRV_URL .. '"')
    for line in codesRaw:gmatch("[^\r\n]+") do
        if line:len() > 5 then table.insert(codesList, line) end
    end
    
    if #codesList == 0 then
        print("⚠️ No codes found.")
        os.exit(1)
    end
    
    currentCleanCode = codesList[1] -- Simplified: Ambil kode pertama. Bisa dimodifikasi untuk input manual
    local codeDisplay = AUTO_RANDOM_CODE and "RANDOM" or "..." .. currentCleanCode:sub(-4)
    
    autoArrangeXML()
    
    -- FASE 1: LAUNCH
    for _, acc in ipairs(accounts) do
        accountStates[acc.pkg].serverStatus = "Solving Captcha ⏳"
        renderDashboard(codeDisplay, "🤖 Mengirim cookie " .. acc.username .. " ke Solver API...")
        
        runSolver(acc.cookie, acc.pkg)
        
        local finalCode = currentCleanCode
        if finalCode:match("linkCode=") then
            finalCode = finalCode:match("linkCode=([^&]+)")
        end
        local launchUrl = string.format("roblox://placeID=%s&linkCode=%s", PLACE_ID, finalCode)
        
        stopPackage(acc.pkg)
        releaseMemory()
        sleep(1500)
        
        launchPackage(acc.pkg, launchUrl)
        accountStates[acc.pkg].isRunning = true
        accountStates[acc.pkg].serverStatus = "Launching..."
        
        sleep(5000) -- Tunggu app terbuka
        
        accountStates[acc.pkg].ramUsage = getAppRam(acc.pkg)
        accountStates[acc.pkg].serverStatus = "In Game 🎮"
        renderDashboard(codeDisplay, "✅ " .. acc.username .. " Launch selesai.")
    end
    
    -- FASE 2: MONITORING
    releaseMemory()
    while true do
        for _, acc in ipairs(accounts) do
            renderDashboard(codeDisplay, "👀 Mengecek status " .. acc.username .. "...")
            
            local healthy, reason, ram, isLoading = isAppHealthy(acc.pkg, acc.cookie, acc.userId)
            accountStates[acc.pkg].ramUsage = ram
            
            if healthy then
                accountStates[acc.pkg].isRunning = true
                if isLoading then
                    accountStates[acc.pkg].serverStatus = "⏳ " .. reason
                else
                    accountStates[acc.pkg].serverStatus = "In Game 🎮"
                end
                accountStates[acc.pkg].action = "✅ OK"
            else
                accountStates[acc.pkg].isRunning = false
                accountStates[acc.pkg].serverStatus = "⚠️ " .. reason
                accountStates[acc.pkg].action = "Reopening"
                
                renderDashboard(codeDisplay, "⚠️ " .. acc.username .. " Crash/Offline. Reopening...")
                
                stopPackage(acc.pkg)
                releaseMemory()
                sleep(1500)
                
                runSolver(acc.cookie, acc.pkg)
                
                local finalCode = currentCleanCode
                if finalCode:match("linkCode=") then
                    finalCode = finalCode:match("linkCode=([^&]+)")
                end
                local launchUrl = string.format("roblox://placeID=%s&linkCode=%s", PLACE_ID, finalCode)
                
                launchPackage(acc.pkg, launchUrl)
                sleep(3000)
            end
        end
        
        renderDashboard(codeDisplay, "👀 Monitoring Selesai | Next check in " .. (CHECK_INTERVAL/1000) .. "s")
        sleep(CHECK_INTERVAL)
    end
end

main()
