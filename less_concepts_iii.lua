--- less concepts iii (v8.0 - FLAWLESS EDITION)
--- Monolithic Standalone Port for iii
---
--- PAGE 1: PERFORMANCE
--- R1: V1 Bits (1-8) | Mute (9) | Octaves (10-16)
--- R2: V2 Bits (1-8) | Mute (9) | Octaves (10-16)
--- R3: Randomize Triggers (1-16)
--- R4: Low Limits (1-16)
--- R5: High Limits (1-16)
--- R6: Momentary (1,2) | Olafur (8) | Cycle Modes (9-11)
--- R7: Smart Snapshots (1-16) [Tap: Load/Save, Double: Overwrite, Hold: Clear]
--- R8: Time Divs (1-3) | Page Nav (14-16)
---
--- PAGE 2: CONFIGURATION
--- R1: Seed (1-8) | Rule (9-16)
--- R2: V1 Gate Prob (1-16)
--- R3: V2 Gate Prob (1-16)
--- R4: V1 Transpose Prob (1-16)
--- R5: V2 Transpose Prob (1-16)
--- R6: Scale Select (1-16)
--- R7: Olafur Pool Visualizer (1-16)
--- R8: Page Nav (14-16)
---
--- PAGE 3: MIDI & MPE
--- R1: MPE IN Vel Amt (1-8) | MPE IN Ratchet Amt (9-16)
--- R2: MPE OUT Timbre Amt (1-16)
--- R3: MIDI IN Channel (1-16)
--- R4: MIDI OUT Channel (1-16)
--- R5: MPE IN (1) | MPE OUT (2) | CLOCK IN (4) | CLOCK OUT (5)
--- R6: BPM Coarse 60-210 (1-16)
--- R7: BPM Fine +0..+9 (1-10)
--- R8: Page Nav (14-16)


local dirty = true
local flash_x, flash_y, flash_frames = 0, 0, 0

-- Zero-Allocation MIDI Messages
local msg_clock = {0xF8}
local msg_start = {0xFA}
local msg_stop  = {0xFC}

local scales = {
    {0, 2, 4, 5, 7, 9, 11}, {0, 2, 3, 5, 7, 8, 10}, {0, 2, 3, 5, 7, 9, 10},
    {0, 1, 3, 5, 7, 8, 10}, {0, 2, 4, 6, 7, 9, 11}, {0, 2, 4, 5, 7, 9, 10},
    {0, 1, 3, 5, 6, 8, 10}, {0, 2, 4, 7, 9},        {0, 3, 5, 7, 10},
    {0, 2, 3, 5, 7, 8, 11}, {0, 2, 3, 5, 7, 9, 11}, {0, 2, 4, 6, 8, 10},
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11},         {0, 3, 5, 6, 7, 10},
    {0, 1, 4, 5, 7, 8, 11}, {0, 2, 4, 7, 8}
}

-- 10 Time Divisions (Ticks per step based on 24 PPQN)
-- 1/1, 1/2, 1/4, 1/4t, 1/8, 1/8t, 1/16, 1/16t, 1/32, 1/32t
local div_ticks = {96, 48, 24, 16, 12, 8, 6, 4, 3, 2}

local st = {
    page = 1, seed = 36, rule = 30, low = 1, high = 14, scale = 1,
    bpm_coarse = 6, bpm_fine = 0, bpm = 120, time_div = 3,
    olafur_on = false, mpe_in = false, mpe_out = false,
    clock_in = false, clock_out = false, midi_in_ch = 1, midi_out_ch = 1,
    mpe_vel_amt = 8, mpe_ratchet_amt = 4, mpe_timbre_amt = 8, cycle_mode = 0,
    active_snap = 0
}

local v = {
    { bits = {1,0,0,0,0,0,0,0}, mute = false, oct = 0, gate_prob = 16, trans_prob = 1, active_notes = {} },
    { bits = {0,0,0,0,0,0,0,1}, mute = false, oct = 0, gate_prob = 16, trans_prob = 1, active_notes = {} }
}

for i=1,2 do
    for j=1, 16 do v[i].active_notes[j] = {note=0, ch=0, last_vel=0, active=false} end
end

local seed_bin = {0,0,0,0,0,0,0,0}
local rule_bin = {0,0,0,0,0,0,0,0}

-- True Olafur System
local olafur_notes = {}
local olafur_held = {}
local olafur_count = 0
local sustain_on = false

local olafur_pressure = {}
local olafur_cc74 = {}
for i=0, 127 do 
    olafur_pressure[i] = 64
    olafur_cc74[i] = 64 
    olafur_notes[i] = 0
    olafur_held[i] = false
end

local global_cc1 = 64
local global_cc2 = 64

local snaps = {}
local snap_press_time = {}
local snap_last_tap = {}
for i = 1, 16 do
    snaps[i] = nil
    snap_press_time[i] = 0
    snap_last_tap[i] = 0
end
local available_snaps = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}

local tick_counter = 0
local mpe_out_rotator = 2
local is_playing = true
local metro_seq = nil
local metro_ui = nil
local retime = false

-- ============================================================
-- STARTUP MARQUEE (EASTER EGG)
-- ============================================================
local is_starting = true
local marquee_pos = 16.0
local marquee_text = "Less concepts iii   "
local font = {
    ["L"]={4,4,4,4,7},["e"]={2,5,7,4,3}, ["s"]={3,4,2,1,6}, ["c"]={3,4,4,4,3},
    ["o"]={0,2,5,5,2}, ["n"]={0,6,5,5,5},["p"]={0,6,5,6,4}, ["t"]={2,7,2,2,1},
    ["i"]={2,0,2,2,2}, [" "]={0,0,0,0,0}
}

-- ============================================================
-- MATH & CELLULAR AUTOMATA
-- ============================================================
local function update_binaries()
    for i = 0, 7 do
        seed_bin[8-i] = (st.seed >> i) & 1
        rule_bin[8-i] = (st.rule >> i) & 1
    end
    dirty = true
end

local function bang()
    local next_seed = 0
    for i = 0, 7 do
        local left_bit = seed_bin[8 - ((i + 1) % 8)]
        local center_bit = seed_bin[8 - i]
        local right_bit = seed_bin[8 - ((i - 1 + 8) % 8)]
        local idx = (left_bit << 2) | (center_bit << 1) | right_bit
        local bit = (st.rule >> idx) & 1
        next_seed = next_seed | (bit << i)
    end
    st.seed = next_seed
    update_binaries()
end

-- ============================================================
-- MIDI & MPE ENGINE
-- ============================================================
local function get_next_mpe_ch()
    local ch = mpe_out_rotator
    mpe_out_rotator = mpe_out_rotator + 1
    if mpe_out_rotator > 15 then mpe_out_rotator = 2 end
    return ch
end

local function notes_off(voice_idx)
    for j = 1, 16 do
        if v[voice_idx].active_notes[j].active then
            midi_note_off(v[voice_idx].active_notes[j].note, 0, v[voice_idx].active_notes[j].ch)
            v[voice_idx].active_notes[j].active = false
        end
    end
end

local function trigger_voice(voice_idx)
    if v[voice_idx].mute then return end
    
    local bit_active = false
    for i=1, 8 do
        if v[voice_idx].bits[i] == 1 and seed_bin[i] == 1 then
            bit_active = true
            break
        end
    end
    
    if not bit_active then return end
    if math.random(1, 16) > v[voice_idx].gate_prob then return end

    local note_val = 60
    local pressure = global_cc1
    local cc74 = global_cc2

    if st.olafur_on then
        if olafur_count == 0 then return end -- SILENCE IF NO NOTES HELD
        
        local scaled_idx = math.floor((st.seed / 256) * olafur_count) + 1
        scaled_idx = math.max(1, math.min(olafur_count, scaled_idx))
        note_val = olafur_notes[scaled_idx]
        if st.mpe_in then
            pressure = olafur_pressure[note_val]
            cc74 = olafur_cc74[note_val]
        end
    else
        local scale = scales[st.scale]
        local scaled_idx = math.floor(((st.seed / 255) * (st.high - st.low)) + st.low)
        local oct = math.floor((scaled_idx - 1) / #scale)
        local degree = ((scaled_idx - 1) % #scale) + 1
        note_val = 48 + (oct * 12) + scale[degree]
    end

    if math.random(1, 16) <= v[voice_idx].trans_prob then
        note_val = note_val + (math.random(0, 1) == 0 and -12 or 12)
    end

    note_val = note_val + (v[voice_idx].oct * 12)
    note_val = math.max(0, math.min(127, note_val))

    local vel = 100
    if st.mpe_vel_amt > 1 then
        local mod = (pressure - 64) * (st.mpe_vel_amt / 8)
        vel = math.max(1, math.min(127, math.floor(100 + mod)))
    end

    local out_ch = st.midi_out_ch
    if st.mpe_out then
        out_ch = get_next_mpe_ch()
        if st.mpe_timbre_amt > 1 then
            local timbre_val = math.floor((st.seed / 255) * 127)
            timbre_val = math.floor(timbre_val * (st.mpe_timbre_amt / 16))
            timbre_val = math.max(0, math.min(127, timbre_val))
            midi_cc(74, timbre_val, out_ch)
        end
    end

    midi_note_on(note_val, vel, out_ch)
    
    for j=1, 16 do
        if not v[voice_idx].active_notes[j].active then
            v[voice_idx].active_notes[j].note = note_val
            v[voice_idx].active_notes[j].ch = out_ch
            v[voice_idx].active_notes[j].last_vel = vel
            v[voice_idx].active_notes[j].active = true
            break
        end
    end
end

-- ============================================================
-- SNAPSHOTS & CYCLING (MASTER PSET)
-- ============================================================
local function pack_state()
    local s = {}
    for k,val in pairs(st) do 
        -- STRICT ISOLATION: Do not save UI or Tempo state in snapshots
        if type(val) ~= "table" and k ~= "page" and k ~= "active_snap" and k ~= "bpm_coarse" and k ~= "bpm_fine" and k ~= "bpm" then 
            s[k] = val 
        end 
    end
    s.v1_bits = {table.unpack(v[1].bits)}
    s.v2_bits = {table.unpack(v[2].bits)}
    s.v1_oct = v[1].oct; s.v2_oct = v[2].oct
    s.v1_gp = v[1].gate_prob; s.v2_gp = v[2].gate_prob
    s.v1_tp = v[1].trans_prob; s.v2_tp = v[2].trans_prob
    return s
end

local function unpack_state(s)
    if not s then return end
    for k,val in pairs(s) do 
        if st[k] ~= nil and type(st[k]) ~= "table" and k ~= "page" and k ~= "active_snap" and k ~= "bpm_coarse" and k ~= "bpm_fine" and k ~= "bpm" then 
            st[k] = val 
        end 
    end
    v[1].bits = {table.unpack(s.v1_bits)}
    v[2].bits = {table.unpack(s.v2_bits)}
    v[1].oct = s.v1_oct; v[2].oct = s.v2_oct
    v[1].gate_prob = s.v1_gp; v[2].gate_prob = s.v2_gp
    v[1].trans_prob = s.v1_tp; v[2].trans_prob = s.v2_tp
    update_binaries()
end

local function save_all()
    local master = { state = pack_state(), snapshots = {} }
    for i=1, 16 do
        if snaps[i] then master.snapshots[i] = snaps[i] end
    end
    pset_write(1, master)
end

local function load_all()
    local ok, data = pcall(pset_read, 1)
    if ok and type(data) == "table" then
        if data.state then unpack_state(data.state) end
        if data.snapshots then
            for i=1, 16 do snaps[i] = data.snapshots[i] end
        end
    end
end

local function cycle_snapshots()
    if st.cycle_mode == 0 then return end
    
    local count = 0
    for i=1, 16 do 
        if snaps[i] then 
            count = count + 1
            available_snaps[count] = i 
        end 
    end
    if count < 2 then return end

    local current_idx = 1
    for i=1, count do
        if available_snaps[i] == st.active_snap then current_idx = i break end
    end

    local next_idx = current_idx
    if st.cycle_mode == 1 then
        next_idx = current_idx - 1
        if next_idx < 1 then next_idx = count end
    elseif st.cycle_mode == 2 then
        next_idx = current_idx + 1
        if next_idx > count then next_idx = 1 end
    elseif st.cycle_mode == 3 then
        next_idx = math.random(1, count)
    end

    st.active_snap = available_snaps[next_idx]
    unpack_state(snaps[st.active_snap])
    dirty = true
end

-- ============================================================
-- TIME ENGINE (24 PPQN - ZERO JITTER)
-- ============================================================
local function seq_tick()
    if retime and not st.clock_in then
        if metro_seq then metro_seq:start(60.0 / (st.bpm * 24)) end
        retime = false
    end

    if not is_playing then return end

    if st.clock_out then midi_out(msg_clock) end

    local ticks = div_ticks[st.time_div]
    local mod_tick = tick_counter % ticks

    local pulse_off_tick = math.max(1, math.floor(ticks / 2))
    if mod_tick == 0 or mod_tick == pulse_off_tick then
        dirty = true
    end

    if mod_tick == 0 then
        notes_off(1)
        notes_off(2)
        bang()
        trigger_voice(1)
        trigger_voice(2)
        
        if tick_counter == 0 then cycle_snapshots() end
    else
        if st.mpe_ratchet_amt > 1 then
            for voice_idx = 1, 2 do
                for j = 1, 16 do
                    local n = v[voice_idx].active_notes[j]
                    if n.active then
                        local r_val = global_cc2
                        if st.mpe_in and st.olafur_on and olafur_cc74[n.note] then
                            r_val = math.max(global_cc2, olafur_cc74[n.note])
                        end
                        
                        local sub_div = 0
                        if r_val > 96 then sub_div = math.floor(ticks / 4)
                        elseif r_val > 64 then sub_div = math.floor(ticks / 2) end
                        
                        if sub_div > 0 and tick_counter % sub_div == 0 then
                            midi_note_off(n.note, 0, n.ch)
                            midi_note_on(n.note, n.last_vel, n.ch)
                        end
                    end
                end
            end
        end
    end

    tick_counter = (tick_counter + 1) % 96
end

local function update_tempo()
    local new_bpm = 50 + (st.bpm_coarse * 10) + st.bpm_fine
    if new_bpm ~= st.bpm then
        st.bpm = new_bpm
        retime = true
    end
    dirty = true
end

-- ============================================================
-- MIDI IN CALLBACK (CRASH-PROOF)
-- ============================================================
function event_midi(b1, b2, b3)
    if not b1 then return end
    
    -- System Real-Time Messages (No channel, 1 byte)
    if b1 >= 0xF8 then
        if b1 == 0xF8 and st.clock_in then seq_tick(); return end
        if b1 == 0xFA and st.clock_in then is_playing = true; tick_counter = 0; return end
        if b1 == 0xFC and st.clock_in then is_playing = false; notes_off(1); notes_off(2); dirty = true; return end
        return
    end

    local status = b1 & 0xF0
    local ch = (b1 & 0x0F) + 1
    b2 = b2 or 0
    b3 = b3 or 0

    if not st.mpe_in and ch ~= st.midi_in_ch then return end

    if status == 0x90 and b3 > 0 then
        if st.olafur_on then
            local exists = false
            for i=1, olafur_count do
                if olafur_notes[i] == b2 then
                    olafur_held[i] = true
                    exists = true
                    break
                end
            end
            if not exists and olafur_count < 128 then
                olafur_count = olafur_count + 1
                olafur_notes[olafur_count] = b2
                olafur_held[olafur_count] = true
                dirty = true
            end
        end
    elseif status == 0x80 or (status == 0x90 and b3 == 0) then
        if st.olafur_on then
            for i=1, olafur_count do
                if olafur_notes[i] == b2 then
                    olafur_held[i] = false
                    if not sustain_on then
                        olafur_notes[i] = olafur_notes[olafur_count]
                        olafur_held[i] = olafur_held[olafur_count]
                        olafur_count = olafur_count - 1
                        dirty = true
                    end
                    break
                end
            end
        end
    elseif status == 0xD0 then
        if st.mpe_in then
            for i=1, olafur_count do olafur_pressure[olafur_notes[i]] = b2 end
            dirty = true
        end
    elseif status == 0xB0 then
        if b2 == 64 then
            sustain_on = (b3 >= 64)
            if not sustain_on and st.olafur_on then
                local i = 1
                while i <= olafur_count do
                    if not olafur_held[i] then
                        olafur_notes[i] = olafur_notes[olafur_count]
                        olafur_held[i] = olafur_held[olafur_count]
                        olafur_count = olafur_count - 1
                        dirty = true
                    else
                        i = i + 1
                    end
                end
            end
        elseif b2 == 74 and st.mpe_in then
            for i=1, olafur_count do olafur_cc74[olafur_notes[i]] = b3 end
        elseif b2 == 1 then global_cc1 = b3
        elseif b2 == 2 then global_cc2 = b3
        end
    end
end

-- ============================================================
-- GRID UI & RENDER (THE TEHN METHOD)
-- ============================================================
local function redraw()
    if not dirty then return end
    dirty = false
    grid_led_all(0)

    if is_starting then
        for x = 1, 16 do
            local char_idx = math.floor((x - marquee_pos) / 4) + 1
            local col = math.floor(x - marquee_pos) % 4
            if char_idx > 0 and char_idx <= #marquee_text and col < 3 then
                local char = marquee_text:sub(char_idx, char_idx)
                local f = font[char] or font[" "]
                for y = 1, 5 do
                    local bit = (f[y] >> (2 - col)) & 1
                    if bit == 1 then grid_led(x, y + 1, 7) end
                end
            end
        end
        grid_refresh()
        return
    end

    if st.page == 1 then
        for i=1, 8 do
            grid_led(i, 1, v[1].bits[i] == 1 and 12 or 4)
            grid_led(i, 2, v[2].bits[i] == 1 and 12 or 4)
        end
        grid_led(9, 1, v[1].mute and 10 or 2)
        grid_led(9, 2, v[2].mute and 10 or 2)
        for i=10, 16 do
            grid_led(i, 1, (v[1].oct == i-13) and 14 or 4)
            grid_led(i, 2, (v[2].oct == i-13) and 14 or 4)
        end

        for i=1, 16 do grid_led(i, 3, 2) end

        for i=1, 16 do
            grid_led(i, 4, (st.low == i) and 12 or 2)
            grid_led(i, 5, (st.high == i) and 13 or 3)
        end

        for i=9, 11 do grid_led(i, 6, (st.cycle_mode == i-8) and 14 or 5) end

        for i=1, 16 do
            if snaps[i] then grid_led(i, 7, (st.active_snap == i) and 15 or 6) end
        end

        for i=1, 10 do
            local is_selected = (st.time_div == i)
            local pulse_val = 4
            if is_selected then
                local ticks = div_ticks[i]
                local pulse_off = math.max(1, math.floor(ticks / 2))
                if tick_counter % ticks < pulse_off then pulse_val = 7 else pulse_val = 2 end
            end
            grid_led(i, 8, pulse_val)
        end
        grid_led(12, 8, st.olafur_on and 15 or 1)

    elseif st.page == 2 then
        for i=1, 8 do
            grid_led(i, 1, seed_bin[i] == 1 and 14 or 4)
            grid_led(i+8, 1, rule_bin[i] == 1 and 10 or 2)
        end

        for i=1, 16 do
            grid_led(i, 2, (i == v[1].gate_prob) and 12 or ((i < v[1].gate_prob) and 5 or 0))
            grid_led(i, 3, (i == v[2].gate_prob) and 12 or ((i < v[2].gate_prob) and 5 or 0))
            grid_led(i, 4, (i == v[1].trans_prob) and 12 or ((i < v[1].trans_prob) and 5 or 0))
            grid_led(i, 5, (i == v[2].trans_prob) and 12 or ((i < v[2].trans_prob) and 5 or 0))
        end

        for i=1, 16 do grid_led(i, 6, (st.scale == i) and 14 or 3) end

        if st.olafur_on then
            for i=1, olafur_count do
                local x = ((olafur_notes[i] % 12) + 1)
                grid_led(x, 7, math.floor(5 + (olafur_pressure[olafur_notes[i]] / 127) * 9))
            end
        end

    elseif st.page == 3 then
        for i=1, 8 do
            grid_led(i, 1, (i == st.mpe_vel_amt) and 12 or ((i < st.mpe_vel_amt) and 6 or 0))
            grid_led(i+8, 1, (i == st.mpe_ratchet_amt) and 12 or ((i < st.mpe_ratchet_amt) and 6 or 0))
        end

        for i=1, 16 do
            grid_led(i, 2, (i == st.mpe_timbre_amt) and 12 or ((i < st.mpe_timbre_amt) and 6 or 0))
        end

        for i=1, 16 do
            grid_led(i, 3, (st.midi_in_ch == i) and 12 or 3)
            grid_led(i, 4, (st.midi_out_ch == i) and 12 or 3)
        end

        grid_led(1, 5, st.mpe_in and 15 or 2)
        grid_led(2, 5, st.mpe_out and 15 or 2)
        grid_led(4, 5, st.clock_in and 15 or 4)
        grid_led(5, 5, st.clock_out and 15 or 4)

        local pulse = (tick_counter % 24 < 12) and 14 or 4
        for i=1, 16 do grid_led(i, 6, (st.bpm_coarse == i) and pulse or 4) end
        for i=1, 10 do grid_led(i, 7, (st.bpm_fine == i-1) and pulse or 3) end
    end

    -- Global Nav
    grid_led(14, 8, (st.page == 1) and 15 or 4)
    grid_led(15, 8, (st.page == 2) and 15 or 4)
    grid_led(16, 8, (st.page == 3) and 15 or 4)

    -- Instant Flash for button presses
    if flash_frames > 0 then
        grid_led(flash_x, flash_y, 15)
        flash_frames = flash_frames - 1
        if flash_frames > 0 then dirty = true end
    end

    grid_refresh()
end

local function ui_tick()
    if is_starting then
        marquee_pos = marquee_pos - 0.4
        if marquee_pos < -(#marquee_text * 4) then
            is_starting = false
        end
        dirty = true
    end
    redraw()
end

-- ============================================================
-- GRID INPUT (ZERO JITTER)
-- ============================================================
function event_grid(x, y, z)
    if is_starting then return end
    
    local is_press = (z == 1)
    if is_press then
        flash_x = x
        flash_y = y
        flash_frames = 3
        dirty = true
    end

    if y == 8 and x >= 14 and is_press then
        st.page = x - 13
        return
    end

    if st.page == 1 then
        if y == 1 and is_press then
            if x <= 8 then v[1].bits[x] = 1 - v[1].bits[x]
            elseif x == 9 then v[1].mute = not v[1].mute
            elseif x >= 10 then v[1].oct = x - 13 end
        elseif y == 2 and is_press then
            if x <= 8 then v[2].bits[x] = 1 - v[2].bits[x]
            elseif x == 9 then v[2].mute = not v[2].mute
            elseif x >= 10 then v[2].oct = x - 13 end
        elseif y == 3 and is_press then
            if x == 1 then st.seed = math.random(0, 255); update_binaries()
            elseif x == 2 then st.rule = math.random(0, 255); update_binaries()
            elseif x == 4 then v[1].bits[math.random(1,8)] = 1 - v[1].bits[math.random(1,8)]
            elseif x == 5 then v[2].bits[math.random(1,8)] = 1 - v[2].bits[math.random(1,8)]
            elseif x == 7 then st.low = math.random(1, 16)
            elseif x == 8 then st.high = math.random(1, 16)
            elseif x == 10 then v[1].oct = math.random(-3, 3)
            elseif x == 11 then v[2].oct = math.random(-3, 3)
            elseif x == 13 then st.time_div = math.random(1, 10)
            elseif x == 16 then 
                st.seed = math.random(0, 255); st.rule = math.random(0, 255)
                st.low = math.random(1, 16); st.high = math.random(1, 16)
                v[1].oct = math.random(-3, 3); v[2].oct = math.random(-3, 3)
                update_binaries()
            end
        elseif y == 4 and is_press then st.low = x
        elseif y == 5 and is_press then st.high = x
        elseif y == 6 and is_press then
            if x >= 9 and x <= 11 then st.cycle_mode = x - 8 end
        elseif y == 7 then
            if is_press then
                snap_press_time[x] = tick_counter
            else
                local dur = (tick_counter - snap_press_time[x]) % 384
                if dur > 96 then 
                    snaps[x] = nil
                    if st.active_snap == x then st.active_snap = 0 end
                    save_all()
                else
                    if snaps[x] == nil then
                        snaps[x] = pack_state()
                        st.active_snap = x
                        save_all()
                    else
                        if dur < 24 then 
                            snaps[x] = pack_state()
                            st.active_snap = x
                            save_all()
                        else
                            unpack_state(snaps[x])
                            st.active_snap = x
                        end
                    end
                end
            end
        elseif y == 8 and is_press then
            if x <= 10 then st.time_div = x
            elseif x == 12 then st.olafur_on = not st.olafur_on end
        end

    elseif st.page == 2 then
        if y == 1 and is_press then
            if x <= 8 then st.seed = st.seed ~ (1 << (8-x))
            else st.rule = st.rule ~ (1 << (16-x)) end
            update_binaries()
        elseif y == 2 and is_press then v[1].gate_prob = x
        elseif y == 3 and is_press then v[2].gate_prob = x
        elseif y == 4 and is_press then v[1].trans_prob = x
        elseif y == 5 and is_press then v[2].trans_prob = x
        elseif y == 6 and is_press then st.scale = x
        end

    elseif st.page == 3 then
        if y == 1 and is_press then
            if x <= 8 then st.mpe_vel_amt = x
            else st.mpe_ratchet_amt = x - 8 end
        elseif y == 2 and is_press then st.mpe_timbre_amt = x
        elseif y == 3 and is_press then st.midi_in_ch = x
        elseif y == 4 and is_press then st.midi_out_ch = x
        elseif y == 5 and is_press then
            if x == 1 then st.mpe_in = not st.mpe_in
            elseif x == 2 then st.mpe_out = not st.mpe_out
            elseif x == 4 then 
                st.clock_in = not st.clock_in
                if st.clock_in then st.clock_out = false end
                update_tempo()
            elseif x == 5 then 
                st.clock_out = not st.clock_out 
                if st.clock_out then st.clock_in = false end
                if st.clock_out then midi_out(msg_start) else midi_out(msg_stop) end
                update_tempo()
            end
        elseif y == 6 and is_press then 
            st.bpm_coarse = x
            update_tempo()
        elseif y == 7 and is_press then
            if x <= 10 then st.bpm_fine = x - 1 end
            update_tempo()
        end
    end
end

-- ============================================================
-- INIT
-- ============================================================
update_binaries()
load_all()

metro_ui = metro.init(ui_tick, 1.0 / FPS)
metro_ui:start()

metro_seq = metro.init(seq_tick, 60.0 / (st.bpm * 24))
if not st.clock_in then metro_seq:start() end
