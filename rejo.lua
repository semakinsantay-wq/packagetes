#!/data/data/com.termux/files/usr/bin/lua

-- Manajer Roblox Multi-Akun untuk Termux (Lua 5.3)
-- Hanya membutuhkan: pkg install lua53 sqlite

-- ============================================
-- KONFIGURASI AWAL
-- ============================================
local CONFIG_FILE = "roblox_config.json"
local config = {}

-- Fungsi untuk membaca file
local function readFile(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*all")
    file:close()
    return content
end

-- Fungsi untuk menulis file
local function writeFile(path, content)
    local file = io.open(path, "w")
    if not file then return false end
    file:write(content)
    file:close()
    return true
end

-- JSON sederhana (tanpa library eksternal)
local function simpleJsonEncode(t)
    local function encode(val)
        local t = type(val)
        if t == "string" then
            return '"' .. val:gsub('"', '\\"') .. '"'
        elseif t == "number" then
            return tostring(val)
        elseif t == "boolean" then
            return val and "true" or "false"
        elseif t == "table" then
            local parts = {}
            for k, v in pairs(val) do
                table.insert(parts, '"' .. k .. '":' .. encode(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        else
            return "null"
        end
    end
    return encode(t)
end

local function simpleJsonDecode(str)
    -- Implementasi sederhana, asumsi format standar
    local t = {}
    -- Hapus kurung kurawal
    str = str:match("{(.*)}")
    if not str then return nil end
    
    for k, v in str:gmatch('"([^"]+)":([^,]+)') do
        v = v:gsub('^%s*(.-)%s*$', '%1')
        if v:sub(1,1) == '"' then
            t[k] = v:sub(2, -2)
        elseif v == "true" then
            t[k] = true
        elseif v == "false" then
            t[k] = false
        elseif tonumber(v) then
            t[k] = tonumber(v)
        end
    end
    return t
end

-- Load konfigurasi
local function loadConfig()
    local content = readFile(CONFIG_FILE)
    if content and content ~= "" then
        config = simpleJsonDecode(content) or {}
    end
    
    -- Set default
    config.PLACE_ID = config.PLACE_ID or "121864768012064"
    config.MSRV_URL = config.MSRV_URL or "ghostbin.axel.org/paste/nk4fh/raw"
    config.YES_KEY = config.YES_KEY or ""
    
    return config
end

-- Simpan konfigurasi
local function saveConfig()
    local content = simpleJsonEncode(config)
    if writeFile(CONFIG_FILE, content) then
        print("✅ Konfigurasi tersimpan di " .. CONFIG_FILE)
    else
        print("❌ Gagal menyimpan konfigurasi")
    end
end

-- Reset konfigurasi
local function resetConfig()
    os.remove(CONFIG_FILE)
    print("✅ Konfigurasi telah direset")
    os.exit(0)
end

-- Cek argumen
for i = 1, #arg do
    if arg[i] == "-reset" then
        resetConfig()
    end
end

-- Load konfigurasi
loadConfig()

-- Input YES_KEY
if config.YES_KEY == "" then
    print("\n🔑 Masukkan YES_KEY (tidak ada default):")
    io.write("> ")
    config.YES_KEY = io.read():match("^%s*(.-)%s*$")
    if config.YES_KEY == "" then
        print("❌ YES_KEY tidak boleh kosong!")
        os.exit(1)
    end
end

-- Input PLACE_ID
print("\n🎮 Masukkan PLACE_ID [default: " .. config.PLACE_ID .. "]:")
io.write("> ")
local newPlaceId = io.read():match("^%s*(.-)%s*$")
if newPlaceId ~= "" then
    config.PLACE_ID = newPlaceId
end

-- Input MSRV_URL
print("\n🌐 Masukkan MSRV_URL (tanpa https://) [default: " .. config.MSRV_URL .. "]:")
io.write("> ")
local newMsrvUrl = io.read():match("^%s*(.-)%s*$")
if newMsrvUrl ~= "" then
    config.MSRV_URL = newMsrvUrl
end

-- Simpan konfigurasi
saveConfig()

-- ============================================
-- KONFIGURASI SCRIPT
-- ============================================
local SETTINGS = {
    PLACE_ID = config.PLACE_ID,
    MSRV_URL = "https://" .. config.MSRV_URL,
    YES_KEY = config.YES_KEY,
    
    SOLVER_API_URL = "http://134.199.219.230:3000/solve",
    
    CHECK_SERVER_PRESENCE = false,
    AUTO_RECONNECT = true,
    AUTO_RANDOM_CODE = false,
    
    GRID_COLS = 3,
    BOX_SIZE = 150,
    START_OFFSET_Y = 50,
    GAP_X = 5,
    GAP_Y = 60,
    
    CHECK_INTERVAL = 120,
    POST_GAME_WAIT = 15,
    MAX_FINAL_RETRIES = 3,
    
    MIN_RAM_THRESHOLD = 10,
    PRESENCE_CHECK_DELAY = 60,
    DEBUG_MODE = false
}

-- ============================================
-- GLOBAL VARIABLES
-- ============================================
local accountStates = {}
local csrfTokens = {}
local launchTimers = {}
local lastRestartMap = {}

-- ============================================
-- UTILITY FUNCTIONS (TANPA SOCKET)
-- ============================================
local function sleep(seconds)
    os.execute("sleep " .. seconds)
end

local function executeCommand(cmd)
    local handle = io.popen(cmd .. " 2>&1")
    local result = handle:read("*a")
    handle:close()
    return result
end

-- HTTP Request sederhana menggunakan wget/curl
local function httpGet(url)
    -- Coba wget dulu
    local cmd = 'wget -q -O- --timeout=30 "' .. url .. '" 2>/dev/null'
    local result = executeCommand(cmd)
    if result and result ~= "" then
        return result, 200
    end
    
    -- Fallback ke curl
    cmd = 'curl -s -L --max-time 30 "' .. url .. '" 2>/dev/null'
    result = executeCommand(cmd)
    if result and result ~= "" then
        return result, 200
    end
    
    return nil, 0
end

local function httpPost(url, data, headers)
    local headerStr = ""
    if headers then
        for k, v in pairs(headers) do
            headerStr = headerStr .. ' -H "' .. k .. ': ' .. v .. '"'
        end
    end
    
    local cmd = 'curl -s -L -X POST --max-time 30' .. headerStr .. ' --data "' .. data .. '" "' .. url .. '" 2>/dev/null'
    local result = executeCommand(cmd)
    
    if result and result ~= "" then
        return result, 200
    end
    return nil, 0
end

-- ============================================
-- SYSTEM FUNCTIONS
-- ============================================
local function applyPerformanceTweaks()
    print("\n🚀 Menerapkan Tweak Performa...")
    local tweaksCmd = [[
        for i in 0 1 2 3 4 5 6 7; do
            echo 1 > /sys/devices/system/cpu/cpu$i/online 2>/dev/null;
            echo performance > /sys/devices/system/cpu/cpu$i/cpufreq/scaling_governor 2>/dev/null;
        done 2>/dev/null;
        stop thermal-engine 2>/dev/null;
        stop thermald 2>/dev/null;
        echo 10 > /proc/sys/vm/swappiness 2>/dev/null;
    ]]
    executeCommand("su -c '" .. tweaksCmd .. "'")
    print("   ✅ Tweak Performa Aktif!")
end

local function initSystem()
    local uid = executeCommand("id -u"):gsub("%s+", "")
    if uid ~= "0" then
        local luaPath = "/data/data/com.termux/files/usr/bin/lua"
        local args = table.concat(arg, " ")
        os.execute("su -c '" .. luaPath .. " " .. arg[0] .. " " .. args .. "'")
        os.exit(0)
    end
    executeCommand("termux-wake-lock")
end

-- ============================================
-- ROBLOX FUNCTIONS
-- ============================================
local function getPackages()
    local result = executeCommand("pm list packages | grep roblox")
    local packages = {}
    for line in result:gmatch("[^\r\n]+") do
        local pkg = line:gsub("package:", "")
        table.insert(packages, pkg)
    end
    return packages
end

local function getRobloxCookie(packageName)
    local cookiesPath = "/data/data/" .. packageName .. "/app_webview/Default/Cookies"
    local tempPath = "/sdcard/temp_cookie_" .. packageName .. "_" .. os.time() .. ".db"
    
    executeCommand("cp '" .. cookiesPath .. "' '" .. tempPath .. "'")
    
    local query = 'sqlite3 "' .. tempPath .. '" "SELECT value FROM cookies WHERE name = \'.ROBLOSECURITY\' LIMIT 1"'
    local cookie = executeCommand(query):gsub("%s+", "")
    
    executeCommand("rm '" .. tempPath .. "'")
    
    if cookie ~= "" and cookie:sub(1,1) ~= "_" then
        cookie = "_" .. cookie
    end
    
    return cookie ~= "" and cookie or nil
end

local function getUserInfo(cookie)
    if not cookie then return { id = nil, name = "No Cookie" } end
    
    local response, code = httpGet("https://users.roblox.com/v1/users/authenticated")
    
    if code == 200 and response then
        -- Parse JSON sederhana
        local id = response:match('"id":(%d+)')
        local name = response:match('"name":"([^"]+)"')
        if id and name then
            return { id = tonumber(id), name = name }
        end
    end
    
    return { id = nil, name = "Expired" }
end

-- ============================================
-- API FUNCTIONS
-- ============================================
local function fetchLinkCodes()
    print("🌐 Fetching codes...")
    
    local response, code = httpGet(SETTINGS.MSRV_URL)
    
    if code == 200 and response then
        local codes = {}
        for line in response:gmatch("[^\r\n]+") do
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" then
                table.insert(codes, line)
            end
        end
        return codes
    end
    
    return {}
end

local function runSolver(fullCookie, accPkg)
    print("🤖 Running solver for " .. accPkg .. "...")
    
    local url = SETTINGS.SOLVER_API_URL .. "?cookie=" .. fullCookie .. "&yeskey=" .. SETTINGS.YES_KEY
    local response, code = httpGet(url)
    
    if code == 200 then
        accountStates[accPkg].serverStatus = "✅ Solver Passed"
        return true
    else
        accountStates[accPkg].serverStatus = "❌ Solver Failed"
        return false
    end
end

-- ============================================
-- APP MANAGEMENT FUNCTIONS
-- ============================================
local function stopPackage(pkg)
    executeCommand("am force-stop " .. pkg)
end

local function isAppRunning(pkg)
    local output = executeCommand("su -c 'pidof " .. pkg .. "'"):gsub("%s+", "")
    return output ~= ""
end

local function getAppRam(pkg)
    local pid = executeCommand("su -c 'pidof " .. pkg .. "'"):gsub("%s+", "")
    if pid == "" then return "0 MB" end
    
    local memInfo = executeCommand("su -c 'dumpsys meminfo " .. pkg .. " | grep -E \"TOTAL:|TOTAL PSS:\"'")
    local match = memInfo:match("(%d+)")
    if match then
        local mb = tonumber(match) / 1024
        return string.format("%.1f MB", mb)
    end
    return "N/A"
end

local function protectProcessFromLMK(pkg)
    local pid = executeCommand("su -c 'pidof " .. pkg .. "'"):gsub("%s+", "")
    if pid ~= "" then
        executeCommand("su -c 'echo -900 > /proc/" .. pid .. "/oom_score_adj'")
        return true
    end
    return false
end

local function releaseMemory()
    executeCommand("su -c 'sync; echo 3 > /proc/sys/vm/drop_caches'")
    return true
end

local function launchPackage(pkg, url)
    local cmd = "am start -n " .. pkg .. "/com.roblox.client.ActivityProtocolLaunch -f 0x18080000 -a android.intent.action.VIEW -d \"" .. url .. "\""
    executeCommand(cmd)
    launchTimers[pkg] = os.time()
end

local function autoArrangeXML(packages)
    print("\n📐 Mengatur XML...")
    table.sort(packages)
    
    for index, pkg in ipairs(packages) do
        local col = (index - 1) % SETTINGS.GRID_COLS
        local row = math.floor((index - 1) / SETTINGS.GRID_COLS)
        
        local left = col * (SETTINGS.BOX_SIZE + SETTINGS.GAP_X)
        local top = (row * (SETTINGS.BOX_SIZE + SETTINGS.GAP_Y)) + SETTINGS.START_OFFSET_Y
        local right = left + SETTINGS.BOX_SIZE
        local bottom = top + SETTINGS.BOX_SIZE
        
        local prefsFile = "/data/data/" .. pkg .. "/shared_prefs/" .. pkg .. "_preferences.xml"
        
        local cmd = [[su -c "
            sed -i 's|app_cloner_current_window_left\\" value=\\"[0-9]*|app_cloner_current_window_left\\" value=\\"]] .. left .. [[|' ]] .. prefsFile .. [[;
            sed -i 's|app_cloner_current_window_top\\" value=\\"[0-9]*|app_cloner_current_window_top\\" value=\\"]] .. top .. [[|' ]] .. prefsFile .. [[;
            sed -i 's|app_cloner_current_window_right\\" value=\\"[0-9]*|app_cloner_current_window_right\\" value=\\"]] .. right .. [[|' ]] .. prefsFile .. [[;
            sed -i 's|app_cloner_current_window_bottom\\" value=\\"[0-9]*|app_cloner_current_window_bottom\\" value=\\"]] .. bottom .. [[|' ]] .. prefsFile .. [[;
            chmod 660 ]] .. prefsFile .. [[
        "]]
        
        executeCommand(cmd)
    end
    print("✅ Posisi XML tersimpan.")
end

-- ============================================
-- HEALTH CHECK FUNCTIONS
-- ============================================
local function isUserInGame(pkg, cookie, userId)
    local now = os.time()
    local lastLaunch = launchTimers[pkg] or 0
    local timeSinceLaunch = now - lastLaunch
    
    if lastLaunch > 0 and timeSinceLaunch < SETTINGS.PRESENCE_CHECK_DELAY then
        return { 
            isInGame = true, 
            status = "loading", 
            timeRemaining = SETTINGS.PRESENCE_CHECK_DELAY - timeSinceLaunch 
        }
    end
    
    -- Fallback ke deteksi lokal
    local foregroundApp = executeCommand("su -c 'dumpsys window windows | grep -E \"mCurrentFocus|mFocusedApp\" | head -1'")
    if foregroundApp:find(pkg) or foregroundApp:find("Roblox") then
        return { isInGame = true, status = "in-game", source = "foreground" }
    end
    
    return { isInGame = false, status = "unknown" }
end

local function isAppHealthy(pkg, cookie, userId)
    local processRunning = isAppRunning(pkg)
    if not processRunning then
        return { healthy = false, reason = "Process Not Running", ram = 0 }
    end
    
    local ramStr = getAppRam(pkg)
    local ramValue = tonumber(ramStr:match("%d+%.?%d*")) or 0
    
    if ramValue < SETTINGS.MIN_RAM_THRESHOLD and ramValue > 0 then
        return { 
            healthy = false, 
            reason = "Low RAM (" .. ramValue .. "MB)", 
            ram = ramValue
        }
    end
    
    local presenceResult = isUserInGame(pkg, cookie, userId)
    
    if presenceResult.status == "loading" then
        return { 
            healthy = true, 
            reason = "Loading (" .. presenceResult.timeRemaining .. "s)", 
            ram = ramValue,
            loading = true
        }
    end
    
    if not presenceResult.isInGame then
        return { 
            healthy = false, 
            reason = "User Not In Game", 
            ram = ramValue
        }
    end
    
    return { 
        healthy = true, 
        reason = "Healthy", 
        ram = ramValue
    }
end

-- ============================================
-- DASHBOARD RENDER
-- ============================================
local function renderDashboard(cleanCode, statusMessage)
    os.execute("clear")
    
    print("📱 SYSTEM: BOOSTER: ON 🔥")
    print("📏 MODE: XML GRID | GAP Y: " .. SETTINGS.GAP_Y .. "px")
    print("📊 STATUS: " .. statusMessage .. " | Code: " .. cleanCode)
    print("")
    
    print(string.format("%-20s %-15s %-10s %-20s %-8s %s", 
        "Package", "User", "State", "Status", "RAM", "Action"))
    print(string.rep("-", 80))
    
    local packages = {}
    for pkg, _ in pairs(accountStates) do
        table.insert(packages, pkg)
    end
    table.sort(packages)
    
    for _, pkg in ipairs(packages) do
        local s = accountStates[pkg]
        local pkgShort = pkg:gsub("com.roblox.client", "...client")
        local username = s.username:sub(1, 12)
        local state = s.isRunning and "Run 🟢" or "Wait ⚪"
        
        print(string.format("%-20s %-15s %-10s %-20s %-8s %s",
            pkgShort,
            username,
            state,
            s.serverStatus,
            s.ramUsage,
            s.action))
    end
    print("")
end

-- ============================================
-- MAIN FUNCTION
-- ============================================
local function main()
    initSystem()
    os.execute("clear")
    print("🚀 Initializing Manager...")
    
    applyPerformanceTweaks()
    
    local packages = getPackages()
    if #packages == 0 then
        print("❌ No Roblox packages found.")
        os.exit(0)
    end
    
    local accounts = {}
    table.sort(packages)
    
    for _, pkg in ipairs(packages) do
        io.write("Reading " .. pkg .. "... \r")
        io.flush()
        
        local cookie = getRobloxCookie(pkg)
        local userInfo = getUserInfo(cookie)
        
        if userInfo.id and userInfo.name ~= "Expired" then
            table.insert(accounts, {
                pkg = pkg,
                cookie = cookie,
                userId = userInfo.id,
                username = userInfo.name
            })
            lastRestartMap[pkg] = 0
            accountStates[pkg] = {
                username = userInfo.name,
                isRunning = false,
                serverStatus = "Waiting...",
                ramUsage = "0 MB",
                action = "-"
            }
        else
            print("⚠️ Skipping " .. pkg .. ": Cookie Expired")
        end
    end
    
    if #accounts == 0 then
        print("❌ Tidak ada akun valid.")
        os.exit(0)
    end
    
    print("\n✅ Loaded " .. #accounts .. " valid accounts.")
    
    local codes = fetchLinkCodes()
    if #codes == 0 then
        print("⚠️ No codes found.")
        os.exit(1)
    end
    
    local cleanCode = ""
    
    if not SETTINGS.AUTO_RANDOM_CODE then
        local selectedIdx = -1
        for i, v in ipairs(arg) do
            if v == "-server" and arg[i+1] then
                selectedIdx = tonumber(arg[i+1]) - 1
                break
            end
        end
        
        if selectedIdx and selectedIdx >= 0 and selectedIdx < #codes then
            print("\n✅ Auto-selecting Server [" .. (selectedIdx + 1) .. "]")
            cleanCode = codes[selectedIdx + 1]
        else
            print("\n📜 Available Codes:")
            for i, code in ipairs(codes) do
                print("[" .. i .. "] " .. code)
            end
            
            print("\n👉 Pilih Server (nomor):")
            io.write("> ")
            local selection = io.read()
            local idx = tonumber(selection)
            
            if not idx or idx < 1 or idx > #codes then
                print("❌ Invalid selection.")
                os.exit(1)
            end
            cleanCode = codes[idx]
        end
    end
    
    local codeDisplay = SETTINGS.AUTO_RANDOM_CODE and "RANDOM" or cleanCode:sub(-4)
    autoArrangeXML(accounts)
    
    -- LAUNCH SEQUENCE
    print("\n🚀 Launching instances...")
    
    for i, acc in ipairs(accounts) do
        accountStates[acc.pkg].serverStatus = "Solving Captcha ⏳"
        renderDashboard(codeDisplay, "🤗 Memproses " .. acc.username .. "...")
        
        runSolver(acc.cookie, acc.pkg)
        renderDashboard(codeDisplay, "✅ Launching " .. acc.username .. "...")
        sleep(2)
        
        local currentCode = cleanCode
        if currentCode:find("linkCode=") then
            currentCode = currentCode:match("linkCode=([^&]+)")
        end
        local finalLaunchUrl = "roblox://placeID=" .. SETTINGS.PLACE_ID .. "&linkCode=" .. currentCode
        
        stopPackage(acc.pkg)
        releaseMemory()
        sleep(1.5)
        
        launchPackage(acc.pkg, finalLaunchUrl)
        lastRestartMap[acc.pkg] = os.time()
        accountStates[acc.pkg].isRunning = true
        accountStates[acc.pkg].serverStatus = "Launching..."
        
        sleep(3)
        protectProcessFromLMK(acc.pkg)
        
        -- Tunggu stabil
        for sec = 1, 60 do
            if sec % 10 == 0 then
                accountStates[acc.pkg].ramUsage = getAppRam(acc.pkg)
            end
            renderDashboard(codeDisplay, "⏳ Menstabilkan " .. acc.username .. " (" .. sec .. "/60s)")
            sleep(1)
        end
        
        accountStates[acc.pkg].serverStatus = "In Game 🎮"
        accountStates[acc.pkg].ramUsage = getAppRam(acc.pkg)
        renderDashboard(codeDisplay, "✅ " .. acc.username .. " Siap!")
        sleep(2)
    end
    
    -- MONITORING LOOP
    print("\n🔄 Mode Monitoring...")
    
    while true do
        for i, acc in ipairs(accounts) do
            renderDashboard(codeDisplay, "👀 Cek " .. acc.username .. "...")
            
            accountStates[acc.pkg].ramUsage = getAppRam(acc.pkg)
            local healthCheck = isAppHealthy(acc.pkg, acc.cookie, acc.userId)
            
            if healthCheck.healthy then
                accountStates[acc.pkg].isRunning = true
                accountStates[acc.pkg].serverStatus = "In Game 🎮"
                accountStates[acc.pkg].action = "✅ " .. healthCheck.ram .. "MB"
            else
                accountStates[acc.pkg].isRunning = false
                accountStates[acc.pkg].serverStatus = "⚠️ " .. healthCheck.reason
                accountStates[acc.pkg].action = "⚠️ Crash"
                
                renderDashboard(codeDisplay, "🔄 Reopen " .. acc.username .. "...")
                
                -- Reopen
                stopPackage(acc.pkg)
                releaseMemory()
                sleep(1.5)
                
                local currentCode = cleanCode
                if currentCode:find("linkCode=") then
                    currentCode = currentCode:match("linkCode=([^&]+)")
                end
                local finalLaunchUrl = "roblox://placeID=" .. SETTINGS.PLACE_ID .. "&linkCode=" .. currentCode
                
                launchPackage(acc.pkg, finalLaunchUrl)
                launchTimers[acc.pkg] = os.time()
                accountStates[acc.pkg].isRunning = true
                accountStates[acc.pkg].serverStatus = "Reopening..."
                
                sleep(3)
                protectProcessFromLMK(acc.pkg)
            end
        end
        
        renderDashboard(codeDisplay, "✅ Cek selesai | Next in " .. SETTINGS.CHECK_INTERVAL .. "s")
        sleep(SETTINGS.CHECK_INTERVAL)
    end
end

-- JALANKAN
local success, err = pcall(main)
if not success then
    print("❌ Error: " .. tostring(err))
end
