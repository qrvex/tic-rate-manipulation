--[[
    ╔══════════════════════════════════════════════╗
    ║        TICK RATE MANIPULATOR  v1.0           ║
    ║         Matcha LuaVM  ·  Physics FPS         ║
    ╚══════════════════════════════════════════════╝

    Targets the Roblox physics simulation rate by directly
    writing to the World's physics step accumulator float
    via Matcha's memory_read / memory_write API.

    Memory chain:
        RobloxPlayerBeta.exe + 0x7C1A148   →  fake DataModel ptr
        fake DataModel      + 0x1D0        →  real DataModel ptr
        real DataModel      + 0x178        →  Workspace ptr
        Workspace           + 0x408        →  World ptr
        World               + 0x6B8        →  physics rate float  ← write here

    The physics rate value = target_fps × 4.
    Default Roblox physics rate = 240  (60 fps × 4).

    UI:
        Tab  ─ "Tick Rate"
          Section "Settings" (left)
            Toggle  ─ enable / disable override
            Slider  ─ target physics FPS  (0 – 240, default 60)
            Toggle  ─ auto-reset on disable  (restores 240)
          Section "Info" (right)
            Status label showing current applied rate
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
--  2.  CONSTANTS
-- ──────────────────────────────────────────────
local OFFSETS = {
    fake_dm   = 0x74f6758,  -- base  → fake DataModel
    real_dm   = 0x1D0,      -- fake DataModel → real DataModel
    workspace = 0x178,      -- real DataModel → Workspace
    world     = 0x408,      -- Workspace      → World
    phys_rate = 0x678,      -- World          → physics rate float
}

local DEFAULT_RATE   = 240   -- Roblox default  (60 fps × 4)
local RATE_MULTIPLIER = 4    -- internal rate = fps × 4
local LOOP_INTERVAL  = 0.2   -- seconds between each write cycle

-- ──────────────────────────────────────────────
--  3.  MEMORY HELPERS
-- ──────────────────────────────────────────────

--- Follow the pointer chain and return (world_ptr, nil) on success,
--- or (nil, reason_string) on failure so the caller can log exactly what broke.
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

--- Write `val` (float) to the physics rate field.
--- Returns true on success, false + reason string on failure (no console spam).
local function apply_rate(val)
    local world_ptr, chain_err = resolve_world_ptr()
    if not world_ptr then
        return false, chain_err
    end
    local ok, err = pcall(memory_write, "float", world_ptr + OFFSETS.phys_rate, val)
    return ok, err
end

-- ──────────────────────────────────────────────
--  4.  STATE
-- ──────────────────────────────────────────────
local state = {
    enabled       = false,
    target_fps    = 60,
    auto_reset    = true,     -- restore DEFAULT_RATE when disabled
    last_ok       = true,
    last_err      = "",
    applied_rate  = DEFAULT_RATE,
}

-- ──────────────────────────────────────────────
--  5.  UI  (Matcha UI.AddTab API)
-- ──────────────────────────────────────────────
UI.AddTab("Tick Rate", function(tab)

    -- ── Left section: controls ────────────────
    local ctrl = tab:Section("Settings", "Left")

    ctrl:Toggle("trm_enabled", "Enable Tick Rate Override", false, function(value)
        state.enabled = (value == true)

        if not state.enabled and state.auto_reset then
            -- Immediately restore default rate when toggled off
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

    -- ── Right section: live status ────────────
    local info = tab:Section("Info", "Right")

    -- Status label updated each loop iteration
    info:Label("trm_status", function()
        if not state.last_ok then
            return "Status: ERROR – " .. tostring(state.last_err):sub(1, 60)
        end
        if state.enabled then
            return string.format(
                "Status: ACTIVE  |  Rate: %d  (FPS ×4)  |  Target: %d FPS",
                state.applied_rate,
                state.target_fps
            )
        end
        return string.format("Status: INACTIVE  |  Rate: %d (default)", DEFAULT_RATE)
    end)

    info:Label("trm_rate_hint", function()
        return string.format(
            "Roblox default = %d  ·  Current target = %d",
            DEFAULT_RATE,
            state.target_fps * RATE_MULTIPLIER
        )
    end)

end)

-- ──────────────────────────────────────────────
--  6.  MAIN LOOP
-- ──────────────────────────────────────────────
local last_err_msg = ""  -- track last error so we don't spam identical lines

while true do
    t_wait(LOOP_INTERVAL)

    if state.enabled then
        local clamped_fps = math.max(0, math.min(240, state.target_fps))
        local write_val   = clamped_fps * RATE_MULTIPLIER

        local ok, err = apply_rate(write_val)

        state.last_ok  = ok
        state.last_err = ok and "" or tostring(err)

        if ok then
            state.applied_rate = write_val
            last_err_msg = ""
        else
            -- Print once per unique error message so the console isn't flooded
            local msg = "[TRM] write failed: " .. state.last_err
            if msg ~= last_err_msg then
                print(msg)
                last_err_msg = msg
            end
        end
    else
        -- Reset tracking when idle
        state.last_ok  = true
        state.last_err = ""
        last_err_msg   = ""
    end
end