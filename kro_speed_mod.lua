-- KRO_SPEED_MOD: standalone, save-directory-only mod. Version 1.2.0.
-- Targets the Windows Steam 6.4.46 interfaces. No game assets are redistributed.
local M = {
    version = "1.2.0", rates = {1, 1.5, 2, 3, 5}, index = 1,
    installed = false, failed = false, active = false,
    -- Own tracked userdata until we finish restoring it. LuaJIT 2.0 weak
    -- keys can still contain userdata AFTER its native __gc has run.
    sources = {}, held_keys = {}, hooks = {},
}
local unpack = unpack
local function pack(...) return {n = select("#", ...), ...} end
local function visible(view)
    if not view then return false end
    while view do
        if view.hidden or (view.alpha and view.alpha <= 0) then return false end
        view = view.parent
    end
    return true
end
local function finite(x) return type(x) == "number" and x == x and x < math.huge and x > -math.huge end

function M:log(message)
    print("[kro_speed_mod] " .. tostring(message))
end

function M:restore_audio()
    for source, info in pairs(self.sources) do
        pcall(source.setPitch, source, info.base)
        info.factor = 1
    end
end

function M:fail(message)
    if self.failed then return end
    self.failed, self.index = true, 1
    self:restore_audio()
    self.sources = {}
    self.held_keys = {}
    if self.button then self.button.hidden = true end
    if self.hint then self.hint.hidden = true end
    self:log("Disabled; original game behavior retained: " .. tostring(message))
end

-- Catch only mod-owned bookkeeping. Exceptions in original game functions
-- still propagate; a partially executed simulation is never retried.
function M:guard(fn, ...)
    local result = pack(pcall(fn, ...))
    if not result[1] then self:fail(result[2]); return nil end
    return unpack(result, 2, result.n)
end

function M:hook(object, name, wrapper)
    local original = assert(object[name], "Missing interface: " .. name)
    assert(type(original) == "function", "Invalid interface: " .. name)
    local replacement = wrapper(original)
    self.hooks[#self.hooks + 1] = {object, name, original, replacement}
    object[name] = replacement
end

function M:in_level()
    if self.failed or not self.active or not self.game or not self.game.game_gui then return false end
    if self.game.store ~= self.store or self.store.game_outcome then return false end
    local director = package.loaded.director
    return not director or (director.active_item == self.game and not director.next_item_name
        and not director.queued_item and not director.queue_unload_item)
end

function M:interactive()
    if not self:in_level() or self.store.paused then return false end
    if love.window and love.window.hasFocus and not love.window.hasFocus() then return false end
    local gg = self.game.game_gui
    if gg.keys_disabled or gg.manual_gui_hide then return false end
    for _, name in ipairs({"pauseview", "notiview", "victoryview", "defeatview"}) do
        if visible(gg[name]) then return false end
    end
    return visible(gg.layer_gui_hud) and not (gg.window and gg.window._focused)
end

function M:rate() return self.rates[self.index] end

-- The native bank mixes a few skill effects into TAUNTS, and dialogue into
-- SPECIALS/BULLETS. Classify these by sound ID instead of by hero name: a
-- hero's projectiles still follow simulation speed; spoken lines do not.
local combat_sounds = {
    ElvesHeroArivanStorm = true, ElvesHeroRagHammerTime = true,
    ElvesHeroBolverkSlash = true,
    ElvesHeroFaustusAttack = true, ElvesHeroFaustusEnervation = true,
    ElvesHeroFaustusFire = true, ElvesHeroFaustusRayKill = true,
    ElvesHeroFaustusTeleport = true, ElvesHeroFaustusUltimate = true,
}
local voice_sounds = {
    ElvesAshbiteConfirm = true, ElvesDrowTaunt = true,
    ElvesEwokAttack = true, ElvesEwokTaunt = true,
    ElvesGnomeNew = true, ElvesGnomePower = true,
    ElvesHeroDenasSworn = true, ElvesHeroEldritchShield = true,
    ElvesSpecialDrowBlademail = true, ElvesSpecialDrowDaggers = true,
    ElvesSpecialDrowLifeDrain = true,
    HeroReinforcementHit = true, HeroReinforcementJump = true,
    HeroReinforcementSpecial = true,
    -- These assets mix voice and effects; preserve the whole native recording.
    ElvesHeroDenasMighty = true, TowerGoldenBowFlareShot = true,
    ElvesFinalBossCastSpellWithLaugh = true, ElvesMaliciaSpellCast = true,
}
function M:is_game_sound(id, group)
    if voice_sounds[id] then return false end
    if combat_sounds[id] then return true end
    return group ~= "MUSIC" and group ~= "GUI" and group ~= "TAUNTS"
end

function M:audio_factor(id, group)
    return self:in_level() and self:is_game_sound(id, group) and self:rate() or 1
end

function M:bind_source(source, request, pool)
    local info = self.sources[source]
    -- Menu/map playback must not start a new ownership lifetime. Retain only
    -- the current level's sources, including throughout its unload/GC phase.
    if not self:in_level() then
        local master = pool and self.sources[pool[1]]
        local base = info and info.base or (master and master.base)
        if base then source:setPitch(base) end
        if info then info.factor = 1 end
        return
    end
    if not info then
        -- New pool clones inherit the master's current (possibly sped-up)
        -- pitch, so inherit its saved baseline instead of multiplying twice.
        local master = pool and self.sources[pool[1]]
        info = {base = master and master.base or source:getPitch()}
        self.sources[source] = info
    end
    info.id = request and request.id
    info.group = request and request.options and request.options.source_group
    local factor = self:audio_factor(info.id, info.group)
    source:setPitch(info.base * factor)
    info.factor = factor
end

function M:refresh_audio()
    for source, info in pairs(self.sources) do
        local factor = self:audio_factor(info.id, info.group)
        if factor ~= info.factor then
            source:setPitch(info.base * factor)
            info.factor = factor
        end
    end
end

function M:set_index(index)
    if self.failed then return end
    assert(self.rates[index], "Invalid speed index")
    self.index = index
    if self.button then self.button.text = tostring(self:rate()) .. "x" end
    if self.rate_label then self.rate_label.text = tostring(self:rate()) .. "x" end
    self:refresh_audio()
end

function M:remove_button()
    for _, view in ipairs({self.hint or false, self.button or false}) do
        if view and view.parent then view:remove_from_parent() end
    end
    self.button, self.hint, self.ui_window, self.rate_label = nil, nil, nil, nil
end

function M:leave()
    self.active, self.index = false, 1
    self:restore_audio()
    -- Native unload_group forces GC before game.destroy. Strong references
    -- above keep Sources valid until this restoration has finished; release
    -- them now so unloaded groups are collected normally afterwards.
    self.sources = {}
    self.held_keys = {}
    self:remove_button()
    self.store = nil
end

function M:enter(game)
    self.game, self.store, self.active, self.index = game, game.store, true, 1
    self:restore_audio()
    self.sources = {}
end

-- Display-only native artwork. The entire subtree is absent from hit-testing.
function M:create_button()
    local gg = self.game.game_gui
    local parent, skill = gg.layer_gui_hud, gg.power_3
    if not parent or not skill or not gg.window then return end
    if self.button and self.ui_window == gg.window then return end
    self:remove_button()
    assert(KView and KImageView and KLabel and skill.view_to_view, "Unsupported HUD interfaces")
    local V = self.vector
    local plate = KView:new()
    plate.id, plate.size = "kro_speed_indicator", V.v(118, 54)
    plate.focus_nav_ignore = true
    plate.hit_all = function() return {} end
    plate.hit_topmost = function() return nil end
    local frame = KImageView:new("button_border_0001")
    frame.scale = V.v(plate.size.x / frame.size.x, plate.size.y / frame.size.y)
    frame.focus_nav_ignore = true
    plate:add_child(frame)
    local label = KLabel:new()
    label.size, label.text_size = V.v(118, 30), V.v(118, 30)
    label.pos, label.text_offset = V.v(0, -1), V.v(0, 0)
    label.font_name, label.font_size, label.text_align = "hud", 20, "center"
    label.colors.text = {255, 235, 172, 255}
    label.focus_nav_ignore = true
    plate:add_child(label)
    local hint = KLabel:new()
    hint.size, hint.text_size = V.v(118, 16), V.v(118, 16)
    hint.pos, hint.text_offset = V.v(0, 30), V.v(0, 0)
    -- The HUD digit font lacks angle brackets; this bundled font has them.
    hint.font_name, hint.font_size, hint.text_align = "DroidSansMono", 10, "center"
    hint.colors.text = {223, 211, 176, 255}
    hint.text, hint.focus_nav_ignore = "Q<  R:1x  >E", true
    plate:add_child(hint)
    parent:add_child(plate)
    self.button, self.hint, self.ui_window = plate, hint, gg.window
    self.rate_label = label
    plate.text, label.text = tostring(self:rate()) .. "x", tostring(self:rate()) .. "x"
end

function M:update_ui()
    if not self.active or not self.game.game_gui then return end
    self:create_button()
    if not self.button then return end
    local gg, plate = self.game.game_gui, self.button
    local skill = gg.power_3
    local x, y = skill:view_to_view(skill.size.x, skill.size.y, gg.layer_gui_hud)
    plate.pos.x, plate.pos.y = x + 8, y - plate.size.y - 4
    plate.hidden = not self:in_level() or not visible(skill) or gg.manual_gui_hide or false
end

function M:handle_key(key, isrepeat)
    if (key ~= "q" and key ~= "e" and key ~= "r") or not self:interactive() then return false end
    if love.keyboard.isDown("lctrl", "rctrl", "lalt", "ralt", "lgui", "rgui", "lshift", "rshift") then return false end
    if not isrepeat and not self.held_keys[key] then
        if key == "r" then
            self:set_index(1)
        else
            local direction = key == "q" and -1 or 1
            self:set_index((self.index - 1 + direction) % #self.rates + 1)
        end
    end
    self.held_keys[key] = true
    return true
end

function M:install_audio(sound)
    local original_play, pool_index, original_pool = sound._play
    for i = 1, 32 do
        local name, value = debug.getupvalue(original_play, i)
        if not name then break end
        if name == "get_or_create_source" then pool_index, original_pool = i, value; break end
    end
    assert(type(original_pool) == "function", "Unsupported audio source pool")
    local current_request
    local wrapped_pool = function(pool)
        local source = original_pool(pool)
        if not M.failed then M:guard(M.bind_source, M, source, current_request, pool) end
        return source
    end
    debug.setupvalue(original_play, pool_index, wrapped_pool)
    self.audio_upvalue = {original_play, pool_index, original_pool, wrapped_pool}
    self:hook(sound, "_play", function(original)
        return function(db, request, pool)
            local previous = current_request
            current_request = request
            local result = pack(pcall(original, db, request, pool))
            current_request = previous
            if not result[1] then error(result[2], 0) end
            return unpack(result, 2, result.n)
        end
    end)
    self:hook(sound, "update", function(original)
        return function(db, dt)
            if not M.failed then
                M:guard(function()
                    M:refresh_audio()
                    -- Keep queued combat sound delays and repeat suppression
                    -- on gameplay time; leave GUI/music scheduling untouched.
                    if M:in_level() and not M.store.paused and not db.paused and M:rate() ~= 1 then
                        local extra = dt * (M:rate() - 1)
                        for _, req in ipairs(db.request_queue) do
                            if M:is_game_sound(req.id, req.options.source_group) and req.options.delay then req.qts = req.qts - extra end
                        end
                        for id, info in pairs(db.sound_extras) do
                            local def = db.sounds[id]
                            if info.last_play_ts and def and M:is_game_sound(id, def.source_group) then
                                info.last_play_ts = info.last_play_ts - extra
                            end
                        end
                    end
                end)
            end
            return original(db, dt)
        end
    end)
end

function M:install()
    assert(version and version.string_short == "6.4.46", "Game version is not verified (expected 6.4.46)")
    local game = require("game")
    local sim, sound, storage = require("klove.simulation"), require("sound_db"), require("storage")
    require("klove.kui")
    self.vector = require("klua.vector")
    self.game, self.sound = game, sound
    assert(love.keypressed and love.keyreleased, "Missing keyboard interfaces")
    assert(sim.update and game.init and game.restart and game.destroy and storage.write_lua, "Missing game interfaces")
    self:install_audio(sound)
    self:hook(storage, "write_lua", function(original)
        return function(db, filename, data, ...)
            -- save_settings filters unknown fields; reinsert only our loader
            -- key into settings writes, never into save slots or globals.
            if filename == db.SETTINGS_FILE and type(data) == "table" then
                local copy = {}; for k, v in pairs(data) do copy[k] = v end
                copy.custom_script = "kro_speed_mod"
                data = copy
            end
            return original(db, filename, data, ...)
        end
    end)
    for _, method in ipairs({"init", "restart"}) do
        self:hook(game, method, function(original)
            return function(g, ...)
                M:guard(M.leave, M)
                local result = pack(original(g, ...))
                if not M.failed then M:guard(M.enter, M, g) end
                return unpack(result, 1, result.n)
            end
        end)
    end
    self:hook(game, "destroy", function(original)
        return function(g, ...)
            M:guard(M.leave, M)
            return original(g, ...)
        end
    end)
    self:hook(sim, "update", function(original)
        return function(s, dt)
            if M.failed or not M.active or s ~= game.simulation or s.store ~= M.store
                or M:rate() == 1 or s.store.paused or s.store.game_outcome then
                return original(s, dt)
            end
            local step = s.store.tick_length
            if not finite(dt) or dt < 0 or not finite(step) or step <= 0
                or (game.DBG_TIME_MULT and game.DBG_TIME_MULT ~= 1) then
                M:fail("Unexpected simulation timing interface")
                return original(s, dt)
            end
            local remaining, rate = dt * M:rate(), M:rate()
            -- The original update handles at most one tick and clamps its
            -- remainder. Substeps retain the original fixed tick length and
            -- system order while preventing lost ticks at lower frame rates.
            while remaining > 0 do
                local part = math.min(remaining, step)
                original(s, part)
                remaining = remaining - part
                if s.store.paused or s.store.game_outcome or not M.active or M:rate() ~= rate then break end
            end
        end
    end)
    self:hook(love, "keypressed", function(original)
        return function(key, scancode, isrepeat)
            local physical = type(scancode) == "string" and scancode or key
            if not M.failed and M:guard(M.handle_key, M, physical, isrepeat) then return end
            return original(key, scancode, isrepeat)
        end
    end)
    self:hook(love, "keyreleased", function(original)
        return function(key, scancode, ...)
            local physical = type(scancode) == "string" and scancode or key
            if M.held_keys[physical] then M.held_keys[physical] = nil; return end
            return original(key, scancode, ...)
        end
    end)
    self.installed = true
    self:log("Loaded 1x / 1.5x / 2x / 3x / 5x; Q/E cycle, R resets; voices unchanged")
end

function M:init()
    if self.installed or self.failed then return end
    local ok, err = pcall(self.install, self)
    if not ok then
        self:fail(err)
        -- Initialization is transactional: remove any hooks installed before
        -- a failed compatibility check, without replacing unrelated changes.
        for i = #self.hooks, 1, -1 do
            local h = self.hooks[i]
            if h[1][h[2]] == h[4] then h[1][h[2]] = h[3] end
        end
        local u = self.audio_upvalue
        if u then
            local _, current = debug.getupvalue(u[1], u[2])
            if current == u[4] then debug.setupvalue(u[1], u[2], u[3]) end
        end
    end
end

function M:update(dt)
    if self.failed or not self.installed then return end
    self:guard(function()
        if self.active and (not self.game.game_gui or self.game.store ~= self.store) then self:leave() end
        self:refresh_audio()
        self:update_ui()
        if not self:interactive() then self.held_keys = {} end
    end)
end

custom_script = M
return M
