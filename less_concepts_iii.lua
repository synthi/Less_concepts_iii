--- less concepts iii (v5.1 - THE MASTERPIECE)
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
--- less concepts iii (v5.1 - TIGHT TIMING & MPE)
--- Monolithic Standalone Port for iii

local FPS = 30 -- Reduced to 30fps to guarantee zero MIDI jitter
local PPQN = 24

local lut_sin = {}
for i = 1, 60 do
    lut_sin[i] = math.floor(11 + 3 * math.sin((i / 60) * math.pi * 2))
end

local scales = {
    {0, 2, 4, 5, 7, 9, 11}, {0, 2, 3, 5, 7, 8, 10}, {0, 2, 3, 5, 7, 9, 10},
    {0, 1, 3, 5, 7, 8, 10}, {0, 2, 4, 6, 7, 9, 11}, {0, 2, 4, 5, 7, 9, 10},
    {0, 1, 3, 5, 6, 8, 10}, {0, 2, 4, 7, 9},        {0, 3, 5, 7, 10},
    {0, 2, 3, 5, 7, 8, 11}, {0, 2, 3, 5, 7, 9, 11}, {0, 2, 4, 6, 8, 10},
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11},         {0, 3, 5, 6, 7, 10},
    {0, 1, 4, 5, 7, 8, 11}, {0, 2, 4, 7, 8}
}

local st = {
    page = 1, seed = 36, rule = 30, low = 1, high = 14, scale = 1,
    bpm_coarse = 6, bpm_fine = 0, bpm = 120, time_div = 2,
    olafur_on = false, mpe_in = false, mpe_out = false,
    clock_in = false, clock_out = false, midi_in_ch = 1, midi_out_ch = 1,
    mpe_vel_amt = 8, mpe_ratchet_amt = 4, mpe_timbre_amt = 8, cycle_mode = 0,
    active_snap = 0, momentary = {false, false}
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

local olafur_notes = {}
local olafur_count = 0
local olafur_pressure = {}
local olafur_cc74 = {}
for i=0, 127 do 
    olafur_pressure[i] = 64
    olafur_cc74[i] = 64 
end

local global_cc1 = 64
local global_cc2 = 64

local g_buf = {}
local g_shd = {}
local g_press = {}
for x = 1, 16 do
    g_buf[x] = {}
    g_shd[x] = {}
    g_press[x] = {}
    for y = 1, 8 do
        g_buf[x][y] = 0
        g_shd[x][y] = -1
        g_press[x][y] = false
    end
end

local snaps = {}
local snap_press_time = {}
local snap_last_tap = {}
for i = 1, 16 do
    snaps[i] = nil
    snap_press_time[i] = 0
    snap_last_tap[i] = 0
end

local tick_counter = 0
local frame_counter = 0
local mpe_out_rotator = 2
local is_playing = true
local metro_seq = nil
local metro_ui = nil

-- ============================================================
-- MATH & CELLULAR AUTOMATA
-- ============================================================
local function update_binaries()
    for i = 0, 7 do
        seed_bin[8-i] = (st.seed >> i) & 1
        rule_bin[8-i] = (st.rule >> i) & 1
    end
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

    if st.olafur_on and olafur_count > 0 then
        local scaled_idx = math.floor(((st.seed / 255) * (st.high - st.low)) + st.low)
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
-- SNAPSHOTS & CYCLING
-- ============================================================
local function pack_state()
    local s = {}
    for k,val in pairs(st) do 
        if type(val) ~= "table" then s[k] = val end 
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
        -- DO NOT load BPM or momentary states from snapshots to prevent jitter/jumps
        if st[k] ~= nil and type(st[k]) ~= "table" and k ~= "bpm_coarse" and k ~= "bpm_fine" and k ~= "bpm" then 
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

local function cycle_snapshots()
    if st.cycle_mode == 0 then return end
    
    local available = {}
    for i=1, 16 do if snaps[i] then table.insert(available, i) end end
    if #available < 2 then return end

    local current_idx = 1
    for i=1, #available do
        if available[i] == st.active_snap then current_idx = i break end
    end

    local next_idx = current_idx
    if st.cycle_mode == 1 then -- < (Prev)
        next_idx = current_idx - 1
        if next_idx < 1 then next_idx = #available end
    elseif st.cycle_mode == 2 then -- > (Next)
        next_idx = current_idx + 1
        if next_idx > #available then next_idx = 1 end
    elseif st.cycle_mode == 3 then -- ~ (Random)
        next_idx = math.random(1, #available)
    end

    st.active_snap = available[next_idx]
    unpack_state(snaps[st.active_snap])
end

-- ============================================================
-- TIME ENGINE (WITH PER-NOTE RATCHET)
-- ============================================================
local function seq_tick()
    if not is_playing then return end

    if st.clock_out then midi_out({0xF8}) end

    local step_ticks = 24
    if st.time_div == 2 then step_ticks = 12
    elseif st.time_div == 3 then step_ticks = 6 end

    if tick_counter % step_ticks == 0 then
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
                        -- CC2 overrides/adds to MPE CC74 if pushed
                        local r_val = global_cc2
                        if st.mpe_in and st.olafur_on and olafur_cc74[n.note] then
                            r_val = math.max(global_cc2, olafur_cc74[n.note])
                        end
                        
                        local sub_div = 0
                        if r_val > 96 then sub_div = math.floor(step_ticks / 4)
                        elseif r_val > 64 then sub_div = math.floor(step_ticks / 2) end
                        
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
    local new_bpm = 60 + (st.bpm_coarse * 10) + st.bpm_fine
    if new_bpm ~= st.bpm then
        st.bpm = new_bpm
        if not st.clock_in and metro_seq then
            -- Update time without restarting phase (fixes jitter)
            metro_seq.time = 60.0 / (st.bpm * 24)
        end
    end
end

-- ============================================================
-- MIDI IN CALLBACK
-- ============================================================
function event_midi(b1, b2, b3)
    local status = b1 & 0xF0
    local ch = (b1 & 0x0F) + 1

    if status == 0xF8 and st.clock_in then
        seq_tick()
        return
    elseif status == 0xFA and st.clock_in then
        is_playing = true
        tick_counter = 0
        return
    elseif status == 0xFC and st.clock_in then
        is_playing = false
        notes_off(1)
        notes_off(2)
        return
    end

    if not st.mpe_in and ch ~= st.midi_in_ch then return end

    if status == 0x90 and b3 > 0 then
        if st.olafur_on then
            local exists = false
            for i=1, olafur_count do
                if olafur_notes[i] == b2 then exists = true break end
            end
            if not exists and olafur_count < 128 then
                olafur_count = olafur_count + 1
                olafur_notes[olafur_count] = b2
            end
        end
    elseif status == 0x80 or (status == 0x90 and b3 == 0) then
        if st.olafur_on then
            for i=1, olafur_count do
                if olafur_notes[i] == b2 then
                    olafur_notes[i] = olafur_notes[olafur_count]
                    olafur_count = olafur_count - 1
                    break
                end
            end
        end
    elseif status == 0xD0 then
        if st.mpe_in then
            for i=1, olafur_count do olafur_pressure[olafur_notes[i]] = b2 end
        end
    elseif status == 0xB0 then
        if b2 == 74 and st.mpe_in then
            for i=1, olafur_count do olafur_cc74[olafur_notes[i]] = b3 end
        elseif b2 == 1 then global_cc1 = b3
        elseif b2 == 2 then global_cc2 = b3
        end
    end
end

-- ============================================================
-- GRID UI & DELTA RENDER
-- ============================================================
local function clear_buffer()
    for x = 1, 16 do
        for y = 1, 8 do g_buf[x][y] = 0 end
    end
end

local function flush_grid()
    local dirty = false
    for x = 1, 16 do
        for y = 1, 8 do
            local val = g_press[x][y] and 15 or g_buf[x][y]
            if val ~= g_shd[x][y] then
                grid_led(x, y, val)
                g_shd[x][y] = val
                dirty = true
            end
        end
    end
    if dirty then grid_refresh() end
end

local function draw_page_1()
    for i=1, 8 do
        g_buf[i][1] = v[1].bits[i] == 1 and 12 or 4
        g_buf[i][2] = v[2].bits[i] == 1 and 12 or 4
    end
    g_buf[9][1] = v[1].mute and 10 or 2
    g_buf[9][2] = v[2].mute and 10 or 2
    for i=10, 16 do
        g_buf[i][1] = (v[1].oct == i-13) and 14 or 4
        g_buf[i][2] = (v[2].oct == i-13) and 14 or 4
    end

    for i=1, 16 do g_buf[i][3] = 5 end

    for i=1, 16 do
        g_buf[i][4] = (st.low == i) and 12 or 2
        g_buf[i][5] = (st.high == i) and 13 or 3
    end

    g_buf[1][6] = st.momentary[1] and 6 or 6
    g_buf[2][6] = st.momentary[2] and 6 or 6
    g_buf[8][6] = st.olafur_on and lut_sin[(frame_counter % 60) + 1] or 4
    for i=9, 11 do g_buf[i][6] = (st.cycle_mode == i-8) and 14 or 5 end

    for i=1, 16 do
        if snaps[i] then 
            g_buf[i][7] = (st.active_snap == i) and 15 or 6 
        else 
            g_buf[i][7] = 0 
        end
    end

    local pulse = lut_sin[(frame_counter % 60) + 1]
    for i=1, 3 do g_buf[i][8] = (st.time_div == i) and pulse or 4 end
end

local function draw_page_2()
    for i=1, 8 do
        g_buf[i][1] = seed_bin[i] == 1 and 14 or 4
        g_buf[i+8][1] = rule_bin[i] == 1 and 10 or 2
    end

    for i=1, 16 do
        g_buf[i][2] = (i <= v[1].gate_prob) and 5 or 0
        if i == v[1].gate_prob then g_buf[i][2] = 12 end
        
        g_buf[i][3] = (i <= v[2].gate_prob) and 5 or 0
        if i == v[2].gate_prob then g_buf[i][3] = 12 end
        
        g_buf[i][4] = (i <= v[1].trans_prob) and 5 or 0
        if i == v[1].trans_prob then g_buf[i][4] = 12 end
        
        g_buf[i][5] = (i <= v[2].trans_prob) and 5 or 0
        if i == v[2].trans_prob then g_buf[i][5] = 12 end
    end

    for i=1, 16 do g_buf[i][6] = (st.scale == i) and 14 or 3 end

    if st.olafur_on then
        for i=1, olafur_count do
            local x = ((olafur_notes[i] % 12) + 1)
            g_buf[x][7] = math.floor(5 + (olafur_pressure[olafur_notes[i]] / 127) * 9)
        end
    end
end

local function draw_page_3()
    for i=1, 8 do
        g_buf[i][1] = (i <= st.mpe_vel_amt) and 6 or 0
        if i == st.mpe_vel_amt then g_buf[i][1] = 12 end
        
        g_buf[i+8][1] = (i <= st.mpe_ratchet_amt) and 6 or 0
        if i == st.mpe_ratchet_amt then g_buf[i+8][1] = 12 end
    end

    for i=1, 16 do
        g_buf[i][2] = (i <= st.mpe_timbre_amt) and 6 or 0
        if i == st.mpe_timbre_amt then g_buf[i][2] = 12 end
    end

    for i=1, 16 do
        g_buf[i][3] = (st.midi_in_ch == i) and 12 or 3
        g_buf[i][4] = (st.midi_out_ch == i) and 12 or 3
    end

    g_buf[1][5] = st.mpe_in and 14 or 4
    g_buf[2][5] = st.mpe_out and 14 or 4
    g_buf[4][5] = st.clock_in and 14 or 4
    g_buf[5][5] = st.clock_out and 14 or 4

    local pulse = lut_sin[(frame_counter % 60) + 1]
    for i=1, 16 do
        g_buf[i][6] = (st.bpm_coarse == i) and pulse or 4
    end
    for i=1, 10 do
        g_buf[i][7] = (st.bpm_fine == i-1) and pulse or 3
    end
end

local function ui_tick()
    frame_counter = frame_counter + 1
    clear_buffer()

    if st.page == 1 then draw_page_1()
    elseif st.page == 2 then draw_page_2()
    elseif st.page == 3 then draw_page_3()
    end

    g_buf[14][8] = (st.page == 1) and 14 or 4
    g_buf[15][8] = (st.page == 2) and 14 or 4
    g_buf[16][8] = (st.page == 3) and 14 or 4

    flush_grid()
end

-- ============================================================
-- GRID INPUT
-- ============================================================
function event_grid(x, y, z)
    local is_press = (z == 1)
    g_press[x][y] = is_press

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
            elseif x == 13 then st.time_div = math.random(1, 3)
            elseif x == 16 then 
                st.seed = math.random(0, 255); st.rule = math.random(0, 255)
                st.low = math.random(1, 16); st.high = math.random(1, 16)
                v[1].oct = math.random(-3, 3); v[2].oct = math.random(-3, 3)
                update_binaries()
            end
        elseif y == 4 and is_press then st.low = x
        elseif y == 5 and is_press then st.high = x
        elseif y == 6 and is_press then
            if x == 8 then st.olafur_on = not st.olafur_on
            elseif x >= 9 and x <= 11 then st.cycle_mode = x - 8 end
        elseif y == 7 then
            if is_press then
                snap_press_time[x] = frame_counter
            else
                local dur = frame_counter - snap_press_time[x]
                if dur > 24 then -- Long press (>800ms at 30fps)
                    snaps[x] = nil
                    pset_write(x, nil)
                    if st.active_snap == x then st.active_snap = 0 end
                else
                    if snaps[x] == nil then
                        snaps[x] = pack_state()
                        pset_write(x, snaps[x])
                        st.active_snap = x
                    else
                        if frame_counter - snap_last_tap[x] < 9 then -- Double tap (<300ms at 30fps)
                            snaps[x] = pack_state()
                            pset_write(x, snaps[x])
                            st.active_snap = x
                        else
                            unpack_state(snaps[x])
                            st.active_snap = x
                        end
                    end
                end
                snap_last_tap[x] = frame_counter
            end
        elseif y == 8 and x <= 3 and is_press then
            st.time_div = x
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
                update_tempo()
            elseif x == 5 then 
                st.clock_out = not st.clock_out 
                if st.clock_out then midi_out({0xFA}) else midi_out({0xFC}) end
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

for i = 1, 16 do
    local ok, data = pcall(pset_read, i)
    if ok and data then snaps[i] = data end
end

metro_ui = metro.init(ui_tick, 1.0 / FPS)
metro_ui:start()

metro_seq = metro.init(seq_tick, 60.0 / (st.bpm * 24))
if not st.clock_in then metro_seq:start() end
