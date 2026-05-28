--[[
    ╔══════════════════════════════════════════════╗
    ║        TICK RATE MANIPULATOR  v2.0           ║
    ║   Matcha LuaVM  ·  Auto-updating Offsets     ║
    ╚══════════════════════════════════════════════╝

    Fetches the latest Roblox offsets from a remote URL on
    startup, so the pointer chain stays valid across Roblox
    updates without needing to edit the script manually.

    Offset source:  OFFSETS_URL  (see constant below)
    Fallback:       hardcoded values used if fetch fails

    Memory chain:
        RobloxPlayerBeta.exe + FakeDataModel::Pointer
            → fake DataModel + FakeDataModel::RealDataModel
            → real DataModel + DataModel::Workspace
            → Workspace      + Workspace::World
            → World          + World::worldStepsPerSec  ← write here

    Physics rate value = target_fps × 4
    Roblox default     = 240  (60 fps × 4)
]]

-- ──────────────────────────────────────────────
--  1.  SAFE WAIT HELPER
-- ──────────────────────────────────────────────
local function get_wait()
    if type(task) == "table" and type(task.wait) == "function" then
        return task.wait
    end
    return wait
end
local t_wait = get_wait()

-- ──────────────────────────────────────────────
--  2.  CONFIG
-- ──────────────────────────────────────────────

-- URL to fetch latest offsets from (raw text, one "Key = 0xVALUE" per line)
local OFFSETS_URL = "https://imtheo.lol/Offsets/Offsets.txt"

-- How often to re-fetch offsets in the background (seconds). 0 = only on startup.
local AUTO_UPDATE_INTERVAL = 300  -- 5 minutes

local DEFAULT_RATE    = 240   -- Roblox default physics rate (60 fps × 4)
local RATE_MULTIPLIER = 4     -- internal rate = fps × 4
local LOOP_INTERVAL   = 0.2   -- seconds between each write cycle

-- Hardcoded fallback offsets (used if fetch fails)
local FALLBACK_OFFSETS = {
    fake_dm   = 0x74f8758,  -- FakeDataModel::Pointer
    real_dm   = 0x1d0,      -- FakeDataModel::RealDataModel
    workspace = 0x178,      -- DataModel::Workspace
    world     = 0x408,      -- Workspace::World
    phys_rate = 0x678,      -- World::worldStepsPerSec
}

-- ──────────────────────────────────────────────
--  3.  OFFSET AUTO-UPDATER
-- ──────────────────────────────────────────────

-- Maps offset file keys → our internal OFFSETS table keys
local OFFSET_KEY_MAP = {
    ["FakeDataModel::Pointer"]       = "fake_dm",
    ["FakeDataModel::RealDataModel"] = "real_dm",
    ["DataModel::Workspace"]         = "workspace",
    ["Workspace::World"]             = "world",
    ["World::worldStepsPerSec"]      = "phys_rate",
}

-- Live offsets table (starts as a copy of fallback, updated by fetch)
local OFFSETS = {}
for k, v in pairs(FALLBACK_OFFSETS) do OFFSETS[k] = v end

--- Attempt to fetch and parse the remote offsets file.
--- Returns (true, updated_count) on success, (false, err) on failure.
--- Try every known HTTP method Matcha/Roblox might expose, return body string or nil+err.
local function http_get(url)
    -- 1. Matcha's HttpGet Service class
    local ok, res = pcall(function()
        return game:GetService("HttpGet Service"):Get(url)
    end)
    if ok and type(res) == "string" and #res > 0 then return res end

    -- 2. Standard Roblox HttpService
    ok, res = pcall(function()
        return game:GetService("HttpService"):GetAsync(url)
    end)
    if ok and type(res) == "string" and #res > 0 then return res end

    -- 3. game:HttpGet (older Roblox API)
    ok, res = pcall(function()
        return game:HttpGet(url)
    end)
    if ok and type(res) == "string" and #res > 0 then return res end

    -- 4. game:HttpGetAsync (tried first, keep as final fallback)
    ok, res = pcall(function()
        return game:HttpGetAsync(url)
    end)
    if ok and type(res) == "string" and #res > 0 then return res end

    return nil, tostring(res)
end

local function fetch_offsets()
    local body, err = http_get(OFFSETS_URL)

    if not body then
        return false, tostring(err)
    end
    local result = body

    local updated = 0
    for line in result:gmatch("[^\r\n]+") do
        -- Match lines like:  SomeKey::SubKey = 0x1A2B3C
        local full_key, hex_val = line:match("^%s*([%w:]+)%s*=%s*(0x%x+)%s*$")
        if full_key and hex_val then
            local internal_key = OFFSET_KEY_MAP[full_key]
            if internal_key then
                local new_val = tonumber(hex_val)
                if new_val and new_val ~= OFFSETS[internal_key] then
                    OFFSETS[internal_key] = new_val
                    updated = updated + 1
                end
            end
        end
    end

    return true, updated
end

-- State tracking for the updater
local offset_state = {
    source        = "fallback",   -- "fallback" | "remote"
    last_fetch    = 0,            -- os.clock() of last attempt
    last_err      = "",
    fetch_count   = 0,
}

--- Run a fetch and update offset_state accordingly.
local function try_update_offsets()
    offset_state.last_fetch = os.clock()
    local ok, result = fetch_offsets()
    if ok then
        offset_state.source      = "remote"
        offset_state.last_err    = ""
        offset_state.fetch_count = offset_state.fetch_count + 1
        print(("[TRM] offsets updated from remote (%d changed)"):format(result))
    else
        offset_state.last_err = tostring(result)
        print(("[TRM] offset fetch failed, using %s: %s"):format(offset_state.source, offset_state.last_err))
    end
end

-- Initial fetch on startup
try_update_offsets()

-- ──────────────────────────────────────────────
--  4.  MEMORY HELPERS
-- ──────────────────────────────────────────────

--- Follow the pointer chain → (world_ptr, nil) or (nil, reason).
local function resolve_world_ptr()
    local base = getbase()
    if not base or base == 0 then
        return nil, "getbase() returned 0"
    end

    local fake_dm = memory_read("uintptr_t", base + OFFSETS.fake_dm)
    if not fake_dm or fake_dm == 0 then
        return nil, ("fake_dm nil/0  (base=0x%X)"):format(base)
    end

    local real_dm = memory_read("uintptr_t", fake_dm + OFFSETS.real_dm)
    if not real_dm or real_dm == 0 then
        return nil, ("real_dm nil/0  (fake_dm=0x%X)"):format(fake_dm)
    end

    local ws_ptr = memory_read("uintptr_t", real_dm + OFFSETS.workspace)
    if not ws_ptr or ws_ptr == 0 then
        return nil, ("ws_ptr nil/0  (real_dm=0x%X)"):format(real_dm)
    end

    local world_ptr = memory_read("uintptr_t", ws_ptr + OFFSETS.world)
    if not world_ptr or world_ptr == 0 then
        return nil, ("world_ptr nil/0  (ws_ptr=0x%X)"):format(ws_ptr)
    end

    return world_ptr, nil
end

--- Write physics rate float → (true) or (false, reason).
local function apply_rate(val)
    local world_ptr, chain_err = resolve_world_ptr()
    if not world_ptr then return false, chain_err end
    local ok, err = pcall(memory_write, "float", world_ptr + OFFSETS.phys_rate, val)
    return ok, err
end

-- ──────────────────────────────────────────────
--  5.  STATE
-- ──────────────────────────────────────────────
local state = {
    enabled      = false,
    target_fps   = 60,
    auto_reset   = true,
    last_ok      = true,
    last_err     = "",
    applied_rate = DEFAULT_RATE,
}

-- ──────────────────────────────────────────────
--  6.  UI
-- ──────────────────────────────────────────────
UI.AddTab("Tick Rate", function(tab)

    -- ── Left: controls ────────────────────────
    local ctrl = tab:Section("Settings", "Left")

    ctrl:Toggle("trm_enabled", "Enable Tick Rate Override", false, function(value)
        state.enabled = (value == true)
        if not state.enabled and state.auto_reset then
            apply_rate(DEFAULT_RATE)
            state.applied_rate = DEFAULT_RATE
        end
    end)

    ctrl:SliderInt("trm_target_fps", "Target Physics FPS", 0, 240, 60, function(value)
        state.target_fps = tonumber(value) or 60
    end)

    ctrl:Toggle("trm_auto_reset", "Restore Default on Disable", true, function(value)
        state.auto_reset = (value == true)
    end)

    ctrl:Button("trm_force_update", "Force Refresh Offsets", function()
        spawn(function()
            try_update_offsets()
            notify("TRM", "Offsets refreshed: " .. offset_state.source, 3)
        end)
    end)

    -- ── Right: status ─────────────────────────
    local info = tab:Section("Info", "Right")

    info:Label("trm_status", function()
        if not state.last_ok then
            return "Status: ERROR – " .. tostring(state.last_err):sub(1, 60)
        end
        if state.enabled then
            return ("Status: ACTIVE  |  Rate: %d  |  Target: %d FPS"):format(
                state.applied_rate, state.target_fps)
        end
        return ("Status: INACTIVE  |  Default rate: %d"):format(DEFAULT_RATE)
    end)

    info:Label("trm_offset_src", function()
        if offset_state.last_err ~= "" then
            return "Offsets: FALLBACK (fetch failed)"
        end
        return ("Offsets: %s  |  updates: %d"):format(
            offset_state.source, offset_state.fetch_count)
    end)

    info:Label("trm_offsets_detail", function()
        return ("fake_dm=0x%X  phys=0x%X"):format(OFFSETS.fake_dm, OFFSETS.phys_rate)
    end)

end)

-- ──────────────────────────────────────────────
--  7.  MAIN LOOP
-- ──────────────────────────────────────────────
local last_err_msg = ""

while true do
    t_wait(LOOP_INTERVAL)

    -- Background auto-refresh of offsets
    if AUTO_UPDATE_INTERVAL > 0 then
        local elapsed = os.clock() - offset_state.last_fetch
        if elapsed >= AUTO_UPDATE_INTERVAL then
            spawn(try_update_offsets)
        end
    end

    -- Physics rate write
    if state.enabled then
        local clamped = math.max(0, math.min(240, state.target_fps))
        local write_val = clamped * RATE_MULTIPLIER

        local ok, err = apply_rate(write_val)
        state.last_ok  = ok
        state.last_err = ok and "" or tostring(err)

        if ok then
            state.applied_rate = write_val
            last_err_msg = ""
        else
            local msg = "[TRM] write failed: " .. state.last_err
            if msg ~= last_err_msg then
                print(msg)
                last_err_msg = msg
            end
        end
    else
        state.last_ok  = true
        state.last_err = ""
        last_err_msg   = ""
    end
end
