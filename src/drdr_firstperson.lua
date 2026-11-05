-- Dead Rising Deluxe Remaster - first person VR camera
--
-- Moves the game's own camera to Frank's head. REFramework's VR layer adds head
-- tracking on top of wherever the camera is anchored, so this relocates the anchor rather
-- than fighting the VR camera.
--
-- Discovered by probe (tools/drdr_probe.lua), see docs/TECHNICAL_NOTES.md:
--   player          Pl_Frank (NOT Pl_Frank_UI, that is the menu model parked at y=200)
--   head joint      C_Head
--   camera          app.solid.camera.DefaultMainCamera : lateUpdate
--   render joint    MainCamera.<CameraJoint>k__BackingField
--   cutscene test   CameraManager.<BusyCameraController> is PlayerCameraController
--                   during gameplay, FixedCameraController during scripted cameras
--
-- The renderer reads the camera joint, not the Transform. The Transform drives game
-- logic. They get different values, see write_camera below.
--
-- Copyright (C) 2026 Halcyon. Licensed under GPL-3.0, see LICENSE.
-- The camera write in write_camera (Transform gets the full HMD pose, the camera
-- joint gets the pre-HMD position plus yaw only) follows praydog's re8_vr.lua from
-- REFramework, MIT License, Copyright (c) 2019 praydog. See
-- third_party/reframework/LICENSE.

if reframework:get_game_name() ~= "drdr" then return end

local TAG = "[DRDRFP] "
local function P(s) log.info(TAG .. tostring(s)) end

local function safe(fn, fallback)
    local ok, res = pcall(fn)
    if ok then return res end
    return fallback
end

-- ---------------------------------------------------------------- config

local cfg = {
    enabled          = true,
    hide_head        = true,
    -- Guaranteed last resort: hide every mesh belonging to Frank. You lose the body,
    -- but nothing can obstruct the view. Only needed if head hiding keeps failing.
    hide_whole_body  = false,
    -- RE Engine forward is -Z, not +Z. Using +Z pushed the camera BACKWARDS out of
    -- the back of the skull, which is why "eye forward" made things worse rather
    -- than better. Leave this true unless the view is provably reversed.
    forward_is_neg_z = true,
    -- Frank's C_Head sits inside the skull. Nudge forward and up to eye level.
    eye_forward      = 0.12,
    -- Near clip does the real work. Anything closer than this is clipped away by the
    -- renderer, so Frank's head cannot obstruct the view no matter where his body
    -- meshes live. This is why the head mesh does not actually need to be found.
    -- Too high and nearby walls start clipping, 0.10 to 0.20 is the usable band.
    use_near_clip    = true,
    near_clip        = 0.15,

    -- Motion controls. On by default (work in progress). If it ever breaks first
    -- person, this is the single switch to flip back.
    motion_controls  = true,
    mc_drive_weapon  = true,    -- held weapon rides the right hand
    mc_swap_hands    = false,
    -- grip calibration: where the weapon sits relative to the controller
    mc_weapon_off_x  = 0.0,
    mc_weapon_off_y  = 0.0,
    mc_weapon_off_z  = 0.0,
    mc_weapon_pitch  = 0.0,     -- degrees
    mc_weapon_yaw    = 0.0,
    mc_weapon_roll   = 0.0,
    eye_up           = 0.04,
    eye_right        = 0.0,
    -- during scripted cameras, leave the game alone
    disable_in_cutscene = true,
    debug_log        = false,
}

-- ---------------------------------------------------------------- cached handles

local tdef_transform = sdk.find_type_definition("via.Transform")
local transform_get_position = tdef_transform:get_method("get_Position")
local transform_get_rotation = tdef_transform:get_method("get_Rotation")
local transform_set_position = tdef_transform:get_method("set_Position")
local transform_set_rotation = tdef_transform:get_method("set_Rotation")

local tdef_joint = sdk.find_type_definition("via.Joint")
local joint_get_position = tdef_joint:get_method("get_Position")
local joint_get_rotation = tdef_joint:get_method("get_Rotation")
local joint_set_position = tdef_joint:get_method("set_Position")
local joint_set_rotation = tdef_joint:get_method("set_Rotation")

local tdef_component = sdk.find_type_definition("via.Component")
local component_get_gameobject = tdef_component:get_method("get_GameObject")

local tdef_gameobject = sdk.find_type_definition("via.GameObject")
local gameobject_get_transform = tdef_gameobject:get_method("get_Transform")

-- ---------------------------------------------------------------- scene helpers

local function get_scene()
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return nil end
    return safe(function()
        return sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    end, nil)
end

local typeof_cache = {}
local function find_components(typename)
    local scene = get_scene()
    if not scene then return {} end
    local t = typeof_cache[typename]
    if t == nil then
        t = safe(function() return sdk.typeof(typename) end, false)
        typeof_cache[typename] = t
    end
    if not t then return {} end
    local list = safe(function() return scene:call("findComponents(System.Type)", t) end, nil)
    if not list then return {} end
    return safe(function() return list:get_elements() end, {})
end

-- ---------------------------------------------------------------- state

local state = {
    camera_manager = nil,
    player_go      = nil,
    player_tr      = nil,
    head_joint     = nil,
    head_meshes    = {},
    body_meshes    = {},
    head_hidden    = false,
    head_method    = "none",
    head_scale_saved = false,
    head_scale_orig  = nil,
    near_clip_saved  = false,
    near_clip_orig   = nil,

    -- motion controls
    -- the room space to world transform, rebuilt each frame from the camera pose
    room_rot         = nil,
    room_pos         = nil,
    joint_r_weapon   = nil,
    joint_r_hand     = nil,
    joint_l_hand     = nil,
    joint_r_upperarm = nil,
    joint_r_forearm  = nil,
    body_right       = nil,
    body_back        = nil,
    head_world_pos   = nil,
    mc_logged        = false,
    swing_last       = -10.0,
    attack_until     = -10.0,
    arm_weight       = 1.0,
    swings           = 0,
    mc_api_dumped    = false,
    mc_status        = "off",
    logged_parts   = false,
    in_cutscene    = false,
    active         = false,
    last_error     = "",
    rescan_counter = 0,
    logged_once    = false,
}

local RESCAN_INTERVAL = 120  -- frames between rescans, scanning is not free

-- forward declaration: refresh_pointers calls this, but it is defined further down
local set_head_hidden

-- ---------------------------------------------------------------- discovery

local function find_camera_manager()
    local mgrs = find_components("app.solid.camera.CameraManager")
    if #mgrs > 0 then return mgrs[1] end
    return nil
end

-- Pl_Frank is the world model. Pl_Frank_UI is the menu model parked at y=200 and
-- must be excluded or the camera ends up in the sky.
local function find_player()
    for _, m in ipairs(find_components("via.motion.Motion")) do
        local go = safe(function() return component_get_gameobject:call(m) end, nil)
        if go then
            local name = safe(function() return go:call("get_Name") end, nil)
            if name == "Pl_Frank" then return go end
        end
    end
    return nil
end

local function find_head_joint(player_tr)
    if not player_tr then return nil end
    return safe(function() return player_tr:call("getJointByName", "C_Head") end, nil)
end

-- Collect the head mesh components belonging to Frank.
--
-- Grouping by transform parent chain does NOT work here and found nothing. Character
-- part meshes are not parented to the character transform, they sit at exactly the
-- character's world position. Proven by the probe: all five of a zombie's parts
-- (Body, ACC00, Leg, Head, Feet) reported an identical distance to the zombie itself.
-- So grouping is by position instead.
local HEAD_NAME_PATTERNS = { "^head$", "head", "hair", "face", "^hd", "_hd" }

local function looks_like_head(name)
    local l = tostring(name):lower()
    for _, pat in ipairs(HEAD_NAME_PATTERNS) do
        if l:find(pat) then return true end
    end
    return false
end

-- Walk Frank's transform hierarchy DOWNWARD. Position grouping only found
-- PREF_DefaultHands, so his parts are prefab mounted on child objects with their
-- own transforms rather than sitting at his origin. Walking down from him is the
-- reliable way to enumerate what actually belongs to him.
local function walk_hierarchy(transform, out, depth)
    if not transform or depth > 10 then return end

    local go = safe(function() return transform:call("get_GameObject") end, nil)
    if go then
        local name = safe(function() return go:call("get_Name") end, nil)
        if name then table.insert(out, { go = go, name = tostring(name), depth = depth }) end
    end

    local child = safe(function() return transform:call("get_Child") end, nil)
    while child do
        walk_hierarchy(child, out, depth + 1)
        child = safe(function() return child:call("get_Next") end, nil)
    end
end

local function collect_head_meshes(player_go)
    local out = {}
    if not player_go then return out end

    local player_tr = safe(function() return gameobject_get_transform:call(player_go) end, nil)
    if not player_tr then return out end

    local mesh_t = safe(function() return sdk.typeof("via.render.Mesh") end, nil)

    -- 1. everything under Frank in the scene graph
    local nodes = {}
    walk_hierarchy(player_tr, nodes, 0)

    local logged = {}
    state.body_meshes = {}
    for _, n in ipairs(nodes) do
        local mesh = mesh_t and safe(function()
            return n.go:call("getComponent(System.Type)", mesh_t)
        end, nil) or nil
        if mesh then
            table.insert(logged, string.format("%s%s", string.rep("  ", n.depth), n.name))
            table.insert(state.body_meshes, mesh)
            if looks_like_head(n.name) then table.insert(out, mesh) end
        end
    end

    -- 2. fallback sweep: any mesh close to the head joint, whatever its parentage
    local near = {}
    if #out == 0 and state.head_joint then
        local hp = safe(function() return joint_get_position:call(state.head_joint) end, nil)
        if hp then
            for _, mesh in ipairs(find_components("via.render.Mesh")) do
                local mgo = safe(function() return component_get_gameobject:call(mesh) end, nil)
                local mtr = mgo and safe(function() return gameobject_get_transform:call(mgo) end, nil) or nil
                local mp  = mtr and safe(function() return transform_get_position:call(mtr) end, nil) or nil
                if mp then
                    local dx, dy, dz = mp.x - hp.x, mp.y - hp.y, mp.z - hp.z
                    local d = math.sqrt(dx*dx + dy*dy + dz*dz)
                    if d < 2.5 then
                        local mn = tostring(safe(function() return mgo:call("get_Name") end, "?"))
                        table.insert(near, string.format("%-34s d=%.2f", mn, d))
                        if looks_like_head(mn) then table.insert(out, mesh) end
                    end
                end
            end
        end
    end

    if not state.logged_parts then
        state.logged_parts = true
        local ppos = safe(function() return transform_get_position:call(player_tr) end, nil)
        P("Frank transform pos: " .. (ppos and string.format("%.3f, %.3f, %.3f", ppos.x, ppos.y, ppos.z) or "?"))
        P("hierarchy nodes under Pl_Frank: " .. tostring(#nodes) .. ", of which carry a mesh: " .. tostring(#logged))
        for _, l in ipairs(logged) do P("   mesh node: " .. l) end
        if #near > 0 then
            P("meshes within 2.5m of C_Head (" .. tostring(#near) .. "):")
            for _, l in ipairs(near) do P("   near: " .. l) end
        end
        P("treated as head: " .. tostring(#out))

        -- Frank's hierarchy holds only carried items, so his body lives elsewhere.
        -- PlayerCostumeChanger is the component that swaps his outfit meshes, so it
        -- should hold the references actually needed. Dump it for the real fix.
        local cc_t = safe(function() return sdk.typeof("app.solid.PlayerCostumeChanger") end, nil)
        local cc = cc_t and safe(function()
            return player_go:call("getComponent(System.Type)", cc_t)
        end, nil) or nil
        if cc then
            P("PlayerCostumeChanger found, fields:")
            local td = safe(function() return cc:get_type_definition() end, nil)
            local d = 0
            while td and d < 3 do
                for _, f in ipairs(safe(function() return td:get_fields() end, {})) do
                    local fn = safe(function() return f:get_name() end, "?")
                    local ft = safe(function() return f:get_type():get_full_name() end, "?")
                    local fv = "?"
                    safe(function()
                        local v = f:get_data(f:is_static() and nil or cc)
                        fv = (v == nil) and "nil" or (type(v) == "userdata" and ("<" .. tostring(v:get_type_definition():get_full_name()) .. ">") or tostring(v))
                    end)
                    P(string.format("   cc %-34s %-34s = %s", fn, ft, fv))
                end
                td = safe(function() return td:get_parent_type() end, nil)
                d = d + 1
            end
        else
            P("PlayerCostumeChanger NOT on Pl_Frank")
        end
    end

    return out
end

-- Name independent fallback. If no head mesh can be identified by name, collapse
-- the head joint instead. Works regardless of how the meshes are named or grouped.
local function set_head_joint_collapsed(collapse)
    if not state.head_joint then return false end
    return safe(function()
        if collapse then
            if not state.head_scale_saved then
                state.head_scale_orig = state.head_joint:call("get_Scale")
                state.head_scale_saved = true
            end
            state.head_joint:call("set_Scale", Vector3f.new(0.001, 0.001, 0.001))
        elseif state.head_scale_saved and state.head_scale_orig then
            state.head_joint:call("set_Scale", state.head_scale_orig)
        end
        return true
    end, false)
end

local function refresh_pointers(force)
    state.rescan_counter = state.rescan_counter + 1
    local due = force or (state.rescan_counter % RESCAN_INTERVAL == 0)

    -- cheap validity check every frame
    local player_ok = state.player_go ~= nil and safe(function()
        return state.player_go:call("get_Name") == "Pl_Frank"
    end, false)

    if player_ok and not due then return true end

    state.camera_manager = state.camera_manager or find_camera_manager()

    if not player_ok then
        state.player_go = find_player()
        state.player_tr = nil
        state.head_joint = nil
        state.head_meshes = {}
        state.head_hidden = false
    end

    if state.player_go then
        state.player_tr = state.player_tr or safe(function()
            return gameobject_get_transform:call(state.player_go)
        end, nil)
        state.head_joint = state.head_joint or find_head_joint(state.player_tr)

        -- motion control joints. R_Weapon is the weapon attach point on Frank's rig.
        if state.player_tr and not state.joint_r_weapon then
            local function jn(name)
                return safe(function() return state.player_tr:call("getJointByName", name) end, nil)
            end
            state.joint_r_weapon   = jn("R_Weapon")
            state.joint_r_hand     = jn("R_Hand")
            state.joint_l_hand     = jn("L_Hand")
            state.joint_r_upperarm = jn("R_UpperArm")
            state.joint_r_forearm  = jn("R_Forearm")
            if not state.mc_logged then
                state.mc_logged = true
                P("motion control joints: R_Weapon=" .. tostring(state.joint_r_weapon ~= nil)
                    .. " R_Hand=" .. tostring(state.joint_r_hand ~= nil)
                    .. " R_UpperArm=" .. tostring(state.joint_r_upperarm ~= nil)
                    .. " R_Forearm=" .. tostring(state.joint_r_forearm ~= nil)
                    .. " L_Hand=" .. tostring(state.joint_l_hand ~= nil))
                local ctrls = safe(function() return vrmod:get_controllers() end, nil)
                P("controllers reported: " .. tostring(ctrls and #ctrls or 0))
            end
        end
        -- rescan on the periodic tick too: Frank changes costume constantly in this
        -- game and the mesh set gets swapped underneath the script
        if #state.head_meshes == 0 or due then
            local was_hidden = state.head_hidden
            if was_hidden then set_head_hidden(false) end
            state.head_meshes = collect_head_meshes(state.player_go)
            state.head_hidden = false
            if was_hidden then set_head_hidden(true) end
        end
    end

    return state.player_go ~= nil
end

-- ---------------------------------------------------------------- cutscene test

-- The game reports directly which controller is driving. PlayerCameraController
-- means normal gameplay. Anything else (FixedCameraController and friends) is a
-- scripted camera that must not be touched.
local function update_cutscene_state()
    if not state.camera_manager then state.in_cutscene = false return end

    local ctrl = safe(function()
        return state.camera_manager:get_field("<BusyCameraController>k__BackingField")
    end, nil)

    if not ctrl then
        state.in_cutscene = false
        return
    end

    local tn = safe(function() return ctrl:get_type_definition():get_full_name() end, "")
    state.in_cutscene = (tn ~= "app.solid.camera.PlayerCameraController")

    if not state.logged_once then
        P("active camera controller: " .. tostring(tn))
    end
end

-- ---------------------------------------------------------------- head mesh

-- MUST be called every frame, not only on transitions.
--
-- Mesh enable flags stay where they are put, so those only need writing on change.
-- Joint scale does NOT: the animation system rewrites joint transforms every frame,
-- so a one-shot collapse is undone immediately. That was the bug that made the
-- fallback report success while the head stayed visible.
set_head_hidden = function(hide)
    local changed = (hide ~= state.head_hidden)
    state.head_hidden = hide

    -- guaranteed option: hide everything belonging to Frank
    if cfg.hide_whole_body and state.body_meshes and #state.body_meshes > 0 then
        if changed then
            for _, mesh in ipairs(state.body_meshes) do
                safe(function() mesh:call("set_Enabled", not hide) end)
            end
        end
        state.head_method = "whole body (" .. tostring(#state.body_meshes) .. ")"
        return
    end

    if #state.head_meshes > 0 then
        if changed then
            for _, mesh in ipairs(state.head_meshes) do
                safe(function() mesh:call("set_Enabled", not hide) end)
            end
        end
        state.head_method = "mesh"
        return
    end

    -- no head mesh identified, collapse the joint instead, every frame
    if hide then
        if set_head_joint_collapsed(true) then
            state.head_method = "joint scale"
        else
            state.head_method = "FAILED"
        end
    elseif changed then
        set_head_joint_collapsed(false)
        state.head_method = "none"
    end
end

-- ---------------------------------------------------------------- the camera write

local function get_main_camera_component()
    local mains = find_components("app.solid.camera.MainCamera")
    if #mains > 0 then return mains[1] end
    return nil
end

-- ---------------------------------------------------------------- motion controls

-- Which controller axis points along the weapon. Building the rotation from a
-- direction vector avoids guessing at the Quaternion constructor's argument order,
-- and this is the degree of freedom that actually matters for a swung weapon.
local WEAPON_AXES = {
    ["-z"] = Vector3f.new(0, 0, -1),
    ["+z"] = Vector3f.new(0, 0, 1),
    ["-y"] = Vector3f.new(0, -1, 0),
    ["+y"] = Vector3f.new(0, 1, 0),
    ["-x"] = Vector3f.new(-1, 0, 0),
    ["+x"] = Vector3f.new(1, 0, 0),
}
cfg.mc_weapon_axis = "-z"

-- DEVICE indices, for poses: vrmod:get_position/get_rotation(index)
local function get_controller_indices()
    local ctrls = safe(function() return vrmod:get_controllers() end, nil)
    if not ctrls or #ctrls < 2 then return nil, nil end
    local l, r = ctrls[1], ctrls[2]
    if cfg.mc_swap_hands then l, r = r, l end
    return l, r
end

-- ACTION handles, for is_action_active. These are NOT the device indices; praydog
-- uses get_left_joystick/get_right_joystick for exactly this, and feeding device
-- indices here silently matches nothing, which is why every button did nothing while
-- the index free left stick worked.
local joy_logged = false
local function get_joysticks()
    local l = safe(function() return vrmod:get_left_joystick() end, nil)
    local r = safe(function() return vrmod:get_right_joystick() end, nil)
    if not joy_logged then
        joy_logged = true
        local ctrls = safe(function() return vrmod:get_controllers() end, nil)
        P("joysticks: left=" .. tostring(l) .. " right=" .. tostring(r)
            .. "   device indices: " .. tostring(ctrls and ctrls[1]) .. "," .. tostring(ctrls and ctrls[2]))
    end
    if cfg.mc_swap_hands then l, r = r, l end
    return l, r
end

-- Map a room space controller pose into world space using the transform captured
-- from the camera this frame.
local function controller_world_pose(index)
    if not state.room_rot or not state.room_pos or not index then return nil, nil end

    local p = safe(function() return vrmod:get_position(index) end, nil)
    local r = safe(function()
        local m = vrmod:get_rotation(index)
        return m and m:to_quat() or nil
    end, nil)
    if not p or not r then return nil, nil end

    local world_pos = state.room_pos + (state.room_rot * p)
    local world_rot = state.room_rot * r
    return world_pos, world_rot
end

-- One time reflection dump. The weapon rotated but did not translate, which points
-- at set_Position being local space while get_Position returns world. praydog only
-- ever writes the CAMERA joint, which is Joints[0] and has no parent, so local and
-- world are the same there and the question never comes up. R_Weapon is deep in the
-- arm chain. Measure the semantics rather than assume them.
local function dump_joint_api(target_joint)
    P("======== via.Joint / via.motion.Motion API ========")

    for _, tn in ipairs({ "via.Joint", "via.motion.Motion" }) do
        local td = safe(function() return sdk.find_type_definition(tn) end, nil)
        if td then
            P(tn .. ":")
            for _, m in ipairs(safe(function() return td:get_methods() end, {})) do
                local mn = safe(function() return m:get_name() end, "")
                local l = mn:lower()
                if l:find("pos") or l:find("rot") or l:find("world") or l:find("local")
                    or l:find("scale") or l:find("matrix") or l:find("parent") then
                    P(string.format("   %-42s -> %-26s args=%s", mn,
                        tostring(safe(function() return m:get_return_type():get_full_name() end, "?")),
                        tostring(safe(function() return #m:get_params() end, "?"))))
                end
            end
        else
            P(tn .. ": NOT FOUND")
        end
    end

    -- The decisive test: write a known position and read it straight back.
    if target_joint then
        local before = safe(function() return joint_get_position:call(target_joint) end, nil)
        if before then
            local probe_pos = Vector3f.new(before.x, before.y + 0.5, before.z)
            safe(function() joint_set_position:call(target_joint, probe_pos) end)
            local after = safe(function() return joint_get_position:call(target_joint) end, nil)
            P("WRITE TEST on R_Weapon:")
            P(string.format("   before : %.4f, %.4f, %.4f", before.x, before.y, before.z))
            P(string.format("   wrote  : %.4f, %.4f, %.4f", probe_pos.x, probe_pos.y, probe_pos.z))
            if after then
                P(string.format("   after  : %.4f, %.4f, %.4f", after.x, after.y, after.z))
                local dy = after.y - before.y
                if math.abs(dy - 0.5) < 0.05 then
                    P("   => set_Position is WORLD space and the write STICKS")
                elseif math.abs(dy) < 0.001 then
                    P("   => write did NOT stick, joint position is recomputed or read only")
                else
                    P("   => write landed somewhere else, likely LOCAL space. delta y = " .. tostring(dy))
                end
            else
                P("   after  : unreadable")
            end
            -- put it back
            safe(function() joint_set_position:call(target_joint, before) end)
        end
    end

    -- Where is the weapon mesh actually, relative to the joint? If the mesh is a
    -- GameObject in Frank's hierarchy, driving its transform may be the real answer.
    if state.player_go then
        local mesh_t = safe(function() return sdk.typeof("via.render.Mesh") end, nil)
        local nodes = {}
        walk_hierarchy(safe(function() return gameobject_get_transform:call(state.player_go) end, nil), nodes, 0)
        local jp = target_joint and safe(function() return joint_get_position:call(target_joint) end, nil) or nil
        P("Frank hierarchy nodes with a mesh, distance from R_Weapon:")
        for _, n in ipairs(nodes) do
            local mesh = mesh_t and safe(function() return n.go:call("getComponent(System.Type)", mesh_t) end, nil) or nil
            if mesh then
                local tr = safe(function() return gameobject_get_transform:call(n.go) end, nil)
                local p = tr and safe(function() return transform_get_position:call(tr) end, nil) or nil
                local d = "?"
                if p and jp then
                    d = string.format("%.3f", math.sqrt((p.x-jp.x)^2 + (p.y-jp.y)^2 + (p.z-jp.z)^2))
                end
                P(string.format("   %-30s enabled=%-6s d=%s", n.name,
                    tostring(safe(function() return mesh:call("get_Enabled") end, "?")), d))
            end
        end
    end

    P("======== end API dump ========")
end

-- small vector helpers, written out rather than relying on operator availability
local function v_sub(a, b) return Vector3f.new(a.x - b.x, a.y - b.y, a.z - b.z) end
local function v_add(a, b) return Vector3f.new(a.x + b.x, a.y + b.y, a.z + b.z) end
local function v_scale(a, s) return Vector3f.new(a.x * s, a.y * s, a.z * s) end
local function v_dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function v_len(a) return math.sqrt(v_dot(a, a)) end
local function v_norm(a)
    local l = v_len(a)
    if l < 1e-6 then return Vector3f.new(0, 0, 1) end
    return Vector3f.new(a.x / l, a.y / l, a.z / l)
end

local function v_cross(a, b)
    return Vector3f.new(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x)
end

-- Minimal rotation taking direction `from` to direction `to`, as a quaternion, built
-- from axis-angle. No roll by construction.
--
-- Quaternion.new's argument order (w,x,y,z or x,y,z,w) is not documented, so it is
-- not guessed: on first use build both, apply each to a known vector, keep whichever
-- actually maps it correctly, and log the residual so the log proves the maths.
local quat_order = nil   -- "wxyz" or "xyzw"

local function make_quat(w, x, y, z)
    if quat_order == "xyzw" then return Quaternion.new(x, y, z, w) end
    return Quaternion.new(w, x, y, z)
end

local function resolve_quat_order()
    if quat_order then return end
    -- 90 degrees about +Y should take +X to -Z
    local hx, hy, hz, hw = 0, math.sin(math.pi / 4), 0, math.cos(math.pi / 4)
    local f = Vector3f.new(1, 0, 0)
    local want = Vector3f.new(0, 0, -1)
    for _, cand in ipairs({ "wxyz", "xyzw" }) do
        local q = safe(function()
            if cand == "wxyz" then return Quaternion.new(hw, hx, hy, hz) end
            return Quaternion.new(hx, hy, hz, hw)
        end, nil)
        local got = q and safe(function() return q * f end, nil) or nil
        if got then
            local err = v_len(v_sub(v_norm(got), want))
            P(string.format("quat order test %s: residual %.4f", cand, err))
            if err < 0.02 then quat_order = cand end
        end
    end
    if not quat_order then
        quat_order = "wxyz"
        P("quat order UNRESOLVED, defaulting to wxyz - expect arm errors")
    else
        P("quat order resolved: " .. quat_order)
    end
end

local function rot_between(from, to)
    resolve_quat_order()
    local f = v_norm(from)
    local t = v_norm(to)

    local d = v_dot(f, t)
    if d > 0.999999 then return Quaternion.identity() end

    local axis
    if d < -0.999999 then
        axis = v_cross(f, Vector3f.new(1, 0, 0))
        if v_len(axis) < 1e-4 then axis = v_cross(f, Vector3f.new(0, 1, 0)) end
    else
        axis = v_cross(f, t)
    end
    axis = v_norm(axis)

    if d > 1 then d = 1 elseif d < -1 then d = -1 end
    local half = math.acos(d) * 0.5
    local s = math.sin(half)
    return make_quat(math.cos(half), axis.x * s, axis.y * s, axis.z * s)
end

local function joint_world_pos(j)
    if not j then return nil end
    return safe(function() return joint_get_position:call(j) end, nil)
end

-- ================================================================ VR ARMS
--
-- Full arm system, both sides. Written as LOCAL ROTATIONS ONLY on four bones per
-- side: shoulder (clavicle), upper arm, forearm, hand. Children follow through the
-- hierarchy, so bone lengths cannot change and no helper bone can be orphaned.
--
-- For a bone B with parent P:  B_world = P_world * B_local.
-- For a wanted world delta D on B, and the parent has already received a world delta
-- D_P from an upstream write, then
--     B_local_new = inv(D_P * P_world) * D * P_world * B_local
-- Every parent rotation "after upstream writes" is computed analytically rather than
-- re-read, so it does not matter whether re-reads are lazy.
--
-- Earlier versions logged the solver landing - Hinny that GOAT - the elbow and hand with zero error,
-- but the arm sat at full extension almost every frame (reach 0.549/0.550).
-- Frank's arm is 0.55m shoulder to wrist and the solver aimed his WRIST at the
-- controller, which sits in the player's FIST. So he was permanently
-- overreaching, the arm went straight, and the elbow bend became ill defined. This
-- version fixes the target (wrist offset measured from the rig, arm scale), the elbow
-- (proper hint with hysteresis), and adds clavicle participation and the left arm.

local joint_get_local_rotation = tdef_joint:get_method("get_LocalRotation")
local joint_set_local_rotation = tdef_joint:get_method("set_LocalRotation")
local joint_get_parent         = tdef_joint:get_method("get_Parent")

cfg.arm_scale        = 1.0    -- legacy head scale, kept at 1.0; arm length matching replaces it
-- Arm length matching. Frank's elbow bend equals yours when the target is scaled about
-- the shoulder by frank_arm / player_arm. Player arm length is LEARNED as the largest
-- shoulder to wrist distance seen (arms hanging straight already give it), bounded.
cfg.arm_learn             = true
cfg.arm_player_len        = 0.0    -- override in metres, 0 = use learned
cfg.arm_anchor_frank      = true   -- scale about Frank's shoulder (arms look right) vs the
                                   -- player's estimated shoulder (hands sit exactly where yours are)
cfg.body_follow_view      = false  -- OFF by default: pinning caused an endless spin,
                                   -- and a spinning game is worse than crossed arms.
                                   -- Pins Frank's yaw to the GAME CAMERA heading.
                                   -- Pinning to the VIEW instead feeds back through the
                                   -- camera's own follow behaviour and spins him endlessly.
cfg.body_pin_rate         = 0.25   -- fraction of the yaw error corrected per frame
cfg.body_pin_deadzone     = 12.0   -- degrees of slack before correcting at all
cfg.arm_neck_drop         = 0.22   -- eyes -> shoulder height
cfg.arm_neck_back         = 0.04   -- eyes -> shoulder line, backwards
cfg.arm_shoulder_half     = 0.18   -- half shoulder width
cfg.arm_clavicle     = 0.35   -- fraction of the reach swing given to the clavicle
cfg.arm_clavicle_max = 32.0   -- degrees, clavicle swing limit
cfg.arm_elbow_hyst   = 0.35   -- 0 = no smoothing of the elbow hint, 1 = frozen
cfg.arm_drive_left   = true
cfg.arm_flip_palm    = false

-- Swing to attack, and yielding the arm while the attack animation plays.
--
-- In Dead Rising the ANIMATION carries the hitbox: damage happens because the game
-- played an attack, not because a sword mesh passed through a zombie. Driving the arm
-- ourselves moves the mesh without telling the game anything, and while the game's own
-- attack plays, its animation and the script's IK write the same bones and fight each other.
-- So: a swing triggers the game's attack, and the arm gets out of the way while it runs.
cfg.swing_enabled    = true
cfg.swing_speed      = 2.2    -- m/s at the controller to count as a swing
cfg.swing_cooldown   = 0.40   -- seconds between swings
cfg.attack_yield     = true   -- hand the arm back to the animation during an attack
cfg.attack_hold      = 0.50   -- seconds the animation is assumed to own the arm
cfg.arm_blend_time   = 0.12   -- seconds to fade script control in and out

-- per side state
local arms = {
    right = { name = "R", sign = 1.0 },
    left  = { name = "L", sign = -1.0 },
}

local function arm_find_joints(arm)
    if arm.joints_ok then return true end
    local tr = state.player_tr
    if not tr then return false end
    local function jn(n) return safe(function() return tr:call("getJointByName", n) end, nil) end
    arm.j_hand  = jn(arm.name .. "_Hand")
    arm.j_fore  = jn(arm.name .. "_Forearm")
    arm.j_upper = jn(arm.name .. "_UpperArm")
    arm.j_clav  = jn(arm.name .. "_Shoulder")
    arm.joints_ok = arm.j_hand and arm.j_fore and arm.j_upper and true or false
    if arm.joints_ok and not arm.logged then
        arm.logged = true
        local chain, p, depth = {}, arm.j_hand, 0
        while p and depth < 8 do
            table.insert(chain, tostring(safe(function() return p:call("get_Name") end, "?")))
            p = safe(function() return joint_get_parent:call(p) end, nil)
            depth = depth + 1
        end
        P(arm.name .. " arm chain: " .. table.concat(chain, " <- ")
            .. "   clavicle=" .. tostring(arm.j_clav ~= nil))
    end
    return arm.joints_ok
end

-- ---------------------------------------------------------------- hand frame
--
-- The controller to hand mapping is DERIVED, not calibrated.
--
-- Calibrating against the animated hand on some arbitrary frame baked a permanent
-- rotational offset into every frame: the player's real hand at that moment is
-- nowhere near the pose Frank's animation is in. That was the left hand splayed
-- palm up and the right wrist twisted so the blade went sideways.
--
-- Two fixed facts give an exact, pose independent mapping instead:
--
--   OpenXR grip pose (spec):
--     -Z  along the fist tube, little finger toward thumb
--     +X  normal to the palm: INTO the palm for the right hand, AWAY for the left
--         (both controllers' +X point to the user's right when held symmetrically)
--     +Y  right hand rule
--
--   Frank's hand, measured once from the rig, in the hand joint's own frame:
--     f   wrist -> knuckle centroid (finger base joints are children of the hand)
--     t   toward the thumb, perpendicular to f (thumb base joint, or the finger
--         base furthest from the others)
--     n   palm side, n = s * (f x t). RE Engine is right handed, so for a right
--         hand s = -1 and for a left hand s = +1. When a weapon is held its joint
--         sits in the palm, which allows s to be verified against reality and log it.
--
-- Then Q maps hand local axes onto controller local axes, and every frame
--     hand_world = ctrl_world * Q
-- with no calibration pose involved.

local function arm_measure_hand_frame(arm)
    if arm.frame_ok then return true end
    local tr = state.player_tr
    if not tr or not arm.j_hand then return false end

    local joints = safe(function() return tr:call("get_Joints"):get_elements() end, nil)
    if not joints then return false end

    local H  = safe(function() return joint_get_position:call(arm.j_hand) end, nil)
    local HR = safe(function() return joint_get_rotation:call(arm.j_hand) end, nil)
    if not H or not HR then return false end

    -- finger base joints = children of the hand
    local bases, thumb = {}, nil
    for _, j in ipairs(joints) do
        local p = safe(function() return joint_get_parent:call(j) end, nil)
        if p == arm.j_hand then
            local jp = safe(function() return joint_get_position:call(j) end, nil)
            local jn = tostring(safe(function() return j:call("get_Name") end, "?"))
            if jp then
                table.insert(bases, { p = jp, n = jn })
                if jn:lower():find("thumb") then thumb = jp end
            end
        end
    end
    if #bases < 2 then
        P(arm.name .. " hand frame: only " .. tostring(#bases) .. " child joints, cannot build")
        return false
    end

    local names = {}
    for _, b in ipairs(bases) do table.insert(names, b.n) end
    P(arm.name .. " hand children: " .. table.concat(names, ", "))

    -- knuckle centroid excluding the thumb, if it is known which one it is
    local sum, cnt = Vector3f.new(0, 0, 0), 0
    for _, b in ipairs(bases) do
        if b.p ~= thumb then sum = v_add(sum, b.p); cnt = cnt + 1 end
    end
    if cnt == 0 then return false end
    local K = v_scale(sum, 1.0 / cnt)
    local f = v_norm(v_sub(K, H))

    -- thumb direction: named thumb joint, else the base furthest from the others
    if not thumb then
        local best, bd = nil, -1
        for _, b in ipairs(bases) do
            local d = v_len(v_sub(b.p, K))
            if d > bd then bd, best = d, b.p end
        end
        thumb = best
        P(arm.name .. " hand frame: no joint named thumb, using furthest finger base")
    end
    local traw = v_sub(thumb, H)
    local t = v_sub(traw, v_scale(f, v_dot(traw, f)))
    if v_len(t) < 1e-4 then P(arm.name .. " hand frame: thumb degenerate") return false end
    t = v_norm(t)

    local s = (arm.sign > 0) and -1.0 or 1.0        -- right: -1, left: +1
    local n = v_scale(v_cross(f, t), s)

    -- verify s against the weapon if this is the right hand and one is held
    if arm.sign > 0 and state.joint_r_weapon then
        local W = safe(function() return joint_get_position:call(state.joint_r_weapon) end, nil)
        if W then
            local side = v_dot(v_sub(W, v_scale(v_add(H, K), 0.5)), n)
            P(string.format("%s hand frame: weapon lies %s the palm side (%.3f)",
                arm.name, (side > 0) and "ON" or "OPPOSITE", side))
            if side < -0.01 then
                P(arm.name .. " hand frame: flipping palm sign to match the weapon")
                n = v_scale(n, -1.0)
            end
        end
    end

    -- hand local versions, constant properties of the rig
    local inv = HR:inverse()
    arm.f_l = v_norm(inv * f)
    arm.t_l = v_norm(inv * t)
    arm.n_l = v_norm(inv * n)

    -- controller local targets
    local t_c = Vector3f.new(0, 0, -1)
    local n_c = Vector3f.new((arm.sign > 0) and -1 or 1, 0, 0)
    if cfg.arm_flip_palm then n_c = v_scale(n_c, -1) end

    -- Q: hand local -> controller local. First align the tube axis, then roll about
    -- it until the palm normal matches.
    local q1 = rot_between(arm.t_l, t_c)
    if not q1 then return false end
    local n1 = q1 * arm.n_l
    local n1p = v_norm(v_sub(n1, v_scale(t_c, v_dot(n1, t_c))))
    local ncp = v_norm(v_sub(n_c, v_scale(t_c, v_dot(n_c, t_c))))
    local ang = (math.atan2 or math.atan)(v_dot(v_cross(n1p, ncp), t_c), v_dot(n1p, ncp))
    local hh = ang * 0.5
    local q2 = make_quat(math.cos(hh), t_c.x * math.sin(hh), t_c.y * math.sin(hh), t_c.z * math.sin(hh))
    arm.Q = q2 * q1

    -- prove it
    local rt = v_len(v_sub(arm.Q * arm.t_l, t_c))
    local rn = v_len(v_sub(arm.Q * arm.n_l, n_c))
    P(string.format("%s hand frame Q residuals: tube %.4f palm %.4f", arm.name, rt, rn))

    -- wrist offset from the fist centre, in the hand frame. The weapon joint IS the
    -- grip point when held; otherwise use the middle of the palm.
    local fist = nil
    if arm.sign > 0 and state.joint_r_weapon then
        fist = safe(function() return joint_get_position:call(state.joint_r_weapon) end, nil)
    end
    if not fist then
        fist = v_add(v_scale(v_add(H, K), 0.5), v_scale(n, 0.02))
    end
    arm.wrist_off = inv * v_sub(H, fist)
    P(string.format("%s wrist offset from fist: %.3f m", arm.name, v_len(v_sub(H, fist))))

    arm.frame_ok = true
    return true
end

-- Elbow bend direction. Down and outward from the body, a touch back, with hysteresis
-- so it cannot flip frame to frame near full extension.
local function arm_elbow_hint(arm, u)
    local down    = Vector3f.new(0, -1, 0)
    local right   = state.body_right or Vector3f.new(1, 0, 0)
    local back    = state.body_back  or Vector3f.new(0, 0, 1)
    local outward = v_scale(right, arm.sign)
    local hint = v_add(v_add(v_scale(down, 1.0), v_scale(outward, 0.55)), v_scale(back, 0.20))

    local perp = v_sub(hint, v_scale(u, v_dot(hint, u)))
    if v_len(perp) < 1e-3 then
        perp = v_sub(down, v_scale(u, v_dot(down, u)))
    end
    perp = v_norm(perp)

    if arm.prev_perp then
        local k = cfg.arm_elbow_hyst
        perp = v_add(v_scale(perp, 1.0 - k), v_scale(arm.prev_perp, k))
        perp = v_sub(perp, v_scale(u, v_dot(perp, u)))
        perp = v_norm(perp)
    end
    arm.prev_perp = perp
    return perp
end

-- scale a rotation's angle by frac, keeping its axis
local function rot_partial(q, frac, max_deg)
    -- recover axis/angle from the quaternion. quat_order is resolved by rot_between.
    resolve_quat_order()
    local okq, w, x, y, z = pcall(function() return q.w, q.x, q.y, q.z end)
    if not okq or w == nil or x == nil then
        if not state.rot_partial_warned then
            state.rot_partial_warned = true
            P("rot_partial: quaternion component access unsupported, clavicle disabled")
        end
        return Quaternion.identity()
    end
    if w > 1 then w = 1 elseif w < -1 then w = -1 end
    local ang = 2 * math.acos(w)
    if ang > math.pi then ang = ang - 2 * math.pi end
    local sn = math.sqrt(math.max(0, 1 - w * w))
    if sn < 1e-6 then return Quaternion.identity() end
    local ax = Vector3f.new(x / sn, y / sn, z / sn)
    local a = ang * frac
    local lim = math.rad(max_deg or 180)
    if a > lim then a = lim elseif a < -lim then a = -lim end
    local h = a * 0.5
    return make_quat(math.cos(h), ax.x * math.sin(h), ax.y * math.sin(h), ax.z * math.sin(h))
end

-- The solve. target_wrist is where the wrist should go, target_hand_rot the absolute
-- hand orientation. Returns ok, err, achieved_wrist_pos.
local function arm_solve(arm, target_wrist, target_hand_rot)
    if not arm_find_joints(arm) then return false, "no joints" end

    local ju, jf, jh, jc = arm.j_upper, arm.j_fore, arm.j_hand, arm.j_clav

    -- animated world state
    local s = safe(function() return joint_get_position:call(ju) end, nil)
    local e = safe(function() return joint_get_position:call(jf) end, nil)
    local h = safe(function() return joint_get_position:call(jh) end, nil)
    if not s or not e or not h then return false, "no positions" end

    local pu = safe(function() return joint_get_parent:call(ju) end, nil)
    local pf = safe(function() return joint_get_parent:call(jf) end, nil)
    local ph = safe(function() return joint_get_parent:call(jh) end, nil)
    if not pu or not pf or not ph then return false, "no parents" end

    local pu_w = safe(function() return joint_get_rotation:call(pu) end, nil)
    local pf_w = safe(function() return joint_get_rotation:call(pf) end, nil)
    local ph_w = safe(function() return joint_get_rotation:call(ph) end, nil)
    local lu = safe(function() return joint_get_local_rotation:call(ju) end, nil)
    local lf = safe(function() return joint_get_local_rotation:call(jf) end, nil)
    if not (pu_w and pf_w and ph_w and lu and lf) then return false, "no rotations" end

    -- ---- clavicle: rotate partway toward the target, rigidly carrying the arm
    local d_cl = Quaternion.identity()
    local cl_pos = nil
    if jc and cfg.arm_clavicle > 0 then
        cl_pos = safe(function() return joint_get_position:call(jc) end, nil)
        local pc = safe(function() return joint_get_parent:call(jc) end, nil)
        local pc_w = pc and safe(function() return joint_get_rotation:call(pc) end, nil) or nil
        local lc = safe(function() return joint_get_local_rotation:call(jc) end, nil)
        if cl_pos and pc_w and lc then
            local full = rot_between(v_sub(s, cl_pos), v_sub(target_wrist, cl_pos))
            if full then
                d_cl = rot_partial(full, cfg.arm_clavicle, cfg.arm_clavicle_max)
                local lc_new = pc_w:inverse() * d_cl * pc_w * lc
                safe(function() joint_set_local_rotation:call(jc, lc_new) end)
                -- carry the animated arm with the clavicle
                s = v_add(cl_pos, d_cl * v_sub(s, cl_pos))
                e = v_add(cl_pos, d_cl * v_sub(e, cl_pos))
                h = v_add(cl_pos, d_cl * v_sub(h, cl_pos))
                pu_w = d_cl * pu_w
                pf_w = d_cl * pf_w
                ph_w = d_cl * ph_w
            end
        end
    end

    local l1 = v_len(v_sub(e, s))
    local l2 = v_len(v_sub(h, e))
    if l1 < 1e-4 or l2 < 1e-4 then return false, "degenerate" end
    arm.frank_len = l1 + l2

    -- reach clamp
    local to_target = v_sub(target_wrist, s)
    local d_raw = v_len(to_target)
    local d = d_raw
    local dmax = (l1 + l2) * 0.995
    local dmin = math.abs(l1 - l2) * 1.001 + 1e-4
    if d > dmax then d = dmax end
    if d < dmin then d = dmin end
    local u = v_norm(to_target)

    -- law of cosines
    local a = (d * d + l1 * l1 - l2 * l2) / (2 * d)
    local hsq = l1 * l1 - a * a
    local hgt = (hsq > 0) and math.sqrt(hsq) or 0

    local perp = arm_elbow_hint(arm, u)
    local new_elbow = v_add(v_add(s, v_scale(u, a)), v_scale(perp, hgt))
    local new_hand  = v_add(s, v_scale(u, d))

    -- ---- upper arm and forearm as world deltas, then to local
    local d_upper = rot_between(v_sub(e, s), v_sub(new_elbow, s))
    if not d_upper then return false, "no shoulder delta" end
    local fore_after = d_upper * v_sub(h, e)
    local d_fore_x = rot_between(fore_after, v_sub(new_hand, new_elbow))
    if not d_fore_x then return false, "no elbow delta" end
    local d_fore = d_fore_x * d_upper

    -- upper: parent already carries d_cl (folded into pu_w above), its own delta is d_upper
    local lu_new = pu_w:inverse() * d_upper * pu_w * lu
    -- forearm: parent now carries d_upper on top
    local pf_new = d_upper * pf_w
    local lf_new = pf_new:inverse() * d_fore * pf_w * lf
    -- hand: absolute orientation from the controller
    local ph_new = d_fore * ph_w
    local lh_new = target_hand_rot and (ph_new:inverse() * target_hand_rot) or nil

    safe(function() joint_set_local_rotation:call(ju, lu_new) end)
    safe(function() joint_set_local_rotation:call(jf, lf_new) end)
    if lh_new then safe(function() joint_set_local_rotation:call(jh, lh_new) end) end

    -- ---- telemetry: reach statistics, so arm scale gets tuned from data
    arm.n = (arm.n or 0) + 1
    arm.clamped = (arm.clamped or 0) + ((d_raw > dmax) and 1 or 0)
    arm.max_reach = math.max(arm.max_reach or 0, d_raw)
    if arm.n % 600 == 0 then
        local e2 = safe(function() return joint_get_position:call(jf) end, nil)
        local h2 = safe(function() return joint_get_position:call(jh) end, nil)
        P(string.format("%s arm: shoulder->wrist %.3f of assumed %.3f, scaled to %.3f of arm %.3f = ext %.2f, clamped %d/%d, land err %.3f/%.3f",
            arm.name, arm.last_dist or -1, arm.last_plen or -1, d, l1 + l2, d / (l1 + l2),
            arm.clamped, arm.n,
            e2 and v_len(v_sub(e2, new_elbow)) or -1, h2 and v_len(v_sub(h2, new_hand)) or -1))
        arm.clamped, arm.n = 0, 0
    end

    return true, nil, new_hand
end

-- Drive one arm from one controller.
local function arm_update(arm, ctrl_index, head_pos)
    if not arm_find_joints(arm) then arm.status = "no joints" return nil end
    if not arm_measure_hand_frame(arm) then arm.status = "no hand frame" return nil end

    local ctrl_pos, ctrl_rot = controller_world_pose(ctrl_index)
    if not ctrl_pos or not ctrl_rot then arm.status = "no pose" return nil end

    -- read the animated hand BEFORE any write this frame
    local hand_pos_a = safe(function() return joint_get_position:call(arm.j_hand) end, nil)
    local hand_rot_a = safe(function() return joint_get_rotation:call(arm.j_hand) end, nil)
    if not hand_pos_a or not hand_rot_a then arm.status = "no animated hand" return nil end

    -- exact hand orientation from the controller, no calibration pose involved
    local hand_rot_n = ctrl_rot * arm.Q

    -- Blend script control against the animation. At weight 0 the animation owns the arm
    -- completely, which is what makes the attack hitbox land where the game expects.
    local w = state.arm_weight or 1.0
    if w <= 0.02 then arm.status = "yield to animation" return nil end
    if w < 0.999 then
        local d = safe(function() return hand_rot_n * hand_rot_a:inverse() end, nil)
        if d then hand_rot_n = rot_partial(d, w, 180) * hand_rot_a end
    end

    -- the player's wrist in world space, from the fist centre back along the hand frame
    local trim = Vector3f.new(cfg.mc_weapon_off_x, cfg.mc_weapon_off_y, cfg.mc_weapon_off_z)
    local wrist_real = v_add(ctrl_pos, hand_rot_n * v_add(arm.wrist_off, trim))

    -- Player shoulder estimate: eyes -> down to the shoulder line, a touch back, then
    -- out to the side along the body's right vector.
    local wrist_target = wrist_real
    local f_sh = safe(function() return joint_get_position:call(arm.j_upper) end, nil)
    if head_pos and f_sh then
        local right = state.body_right or Vector3f.new(1, 0, 0)
        local back  = state.body_back  or Vector3f.new(0, 0, 1)
        local p_sh = v_add(head_pos, Vector3f.new(0, -cfg.arm_neck_drop, 0))
        p_sh = v_add(p_sh, v_scale(back, cfg.arm_neck_back))
        p_sh = v_add(p_sh, v_scale(right, arm.sign * cfg.arm_shoulder_half))

        local rel = v_sub(wrist_real, p_sh)
        local dist = v_len(rel)

        -- ONE arm length for both sides. The last build learned each arm separately and
        -- the left came out at 0.42 because it was never extended, so it was scaled up
        -- 1.3x and went stiff. Seed from standing eye height (shoulder to wrist is about
        -- a third of stature), then let the largest plausible reach from EITHER arm raise it.
        if cfg.arm_learn and dist > (state.player_arm_len or 0) and dist < 0.90 then
            state.player_arm_len = dist
        end
        local prior = 0.58
        local hmd = safe(function() return vrmod:get_position(0) end, nil)
        if hmd and hmd.y and hmd.y > 1.0 and hmd.y < 2.2 then
            state.eye_height_max = math.max(state.eye_height_max or 0, hmd.y)
            prior = 0.33 * (state.eye_height_max + 0.11)
        end
        local plen = (cfg.arm_player_len > 0) and cfg.arm_player_len or math.max(prior, state.player_arm_len or 0)
        if plen < 0.45 then plen = 0.45 end
        arm.player_len = plen
        local flen = arm.frank_len or 0.55
        local k = flen / plen

        local origin = cfg.arm_anchor_frank and f_sh or p_sh
        wrist_target = v_add(origin, v_scale(rel, k))
        -- ease the position toward the animated hand as the script weight drops
        if w < 0.999 then
            wrist_target = v_add(hand_pos_a, v_scale(v_sub(wrist_target, hand_pos_a), w))
        end
        arm.last_ratio = dist / plen
        arm.last_k = k
        arm.last_dist = dist
        arm.last_plen = plen
    end

    local ok, err, achieved = arm_solve(arm, wrist_target, hand_rot_n)
    if not ok then arm.status = tostring(err) return nil end
    arm.status = "ok"

    return {
        hand_pos_a = hand_pos_a, hand_rot_a = hand_rot_a,
        hand_pos_n = achieved or wrist_target, hand_rot_n = hand_rot_n,
    }
end
-- ---------------------------------------------------------------- damage recon
--
-- REAL physical melee needs two things: custom blade collision, which is just
-- maths over the weapon joint already tracked, and a way to tell the game a zombie was
-- hit. The second is the actual unknown, so dump a nearby zombie's components and any
-- damage shaped methods once, during a normal session.
local dmg_logged = false
local function damage_recon()
    if dmg_logged then return end
    local cam = sdk.get_primary_camera()
    if not cam then return end
    local cp = safe(function()
        return component_get_gameobject:call(cam):call("get_Transform"):call("get_Position")
    end, nil)
    if not cp then return end

    local best, bestd, bestname = nil, 1e9, nil
    for _, m in ipairs(find_components("via.motion.Motion")) do
        local go = safe(function() return component_get_gameobject:call(m) end, nil)
        local nm = go and tostring(safe(function() return go:call("get_Name") end, "")) or ""
        if nm:lower():find("zombie") or nm:lower():find("zonbi") or nm:lower():find("em") == 1 then
            local tr = safe(function() return gameobject_get_transform:call(go) end, nil)
            local p = tr and safe(function() return transform_get_position:call(tr) end, nil) or nil
            if p then
                local d = math.sqrt((p.x-cp.x)^2 + (p.y-cp.y)^2 + (p.z-cp.z)^2)
                if d < bestd then bestd, best, bestname = d, go, nm end
            end
        end
    end
    if not best or bestd > 8.0 then return end

    dmg_logged = true
    P("======== DAMAGE RECON: " .. tostring(bestname) .. " at " .. string.format("%.2f", bestd) .. "m ========")
    local comps = safe(function() return best:call("get_Components") end, nil)
    local elems = comps and safe(function() return comps:get_elements() end, {}) or {}
    for i, c in ipairs(elems) do
        local tn = tostring(safe(function() return c:get_type_definition():get_full_name() end, "?"))
        P("   [" .. i .. "] " .. tn)
        local l = tn:lower()
        if l:find("damage") or l:find("hit") or l:find("health") or l:find("life")
            or l:find("condition") or l:find("body") or l:find("enemy") or l:find("chara") then
            local td = safe(function() return c:get_type_definition() end, nil)
            local names, d = {}, 0
            while td and d < 3 do
                for _, mm in ipairs(safe(function() return td:get_methods() end, {})) do
                    local mn = tostring(safe(function() return mm:get_name() end, "?"))
                    local ml = mn:lower()
                    if ml:find("damage") or ml:find("hit") or ml:find("hp") or ml:find("life")
                        or ml:find("dead") or ml:find("kill") or ml:find("attack") then
                        table.insert(names, mn)
                    end
                end
                td = safe(function() return td:get_parent_type() end, nil)
                d = d + 1
            end
            if #names > 0 then P("        -> " .. table.concat(names, " ")) end
        end
    end

    -- the global damage side: whatever manager or utility applies hits
    for _, short in ipairs({ "DamageManager", "HitManager", "AttackManager", "CombatManager",
                             "DamageUtil", "HitUtil", "AttackUtil", "DamageSystem", "HitSystem" }) do
        local full = "app.solid." .. short
        local td = safe(function() return sdk.find_type_definition(full) end, nil)
        if td then
            local names = {}
            for _, mm in ipairs(safe(function() return td:get_methods() end, {})) do
                table.insert(names, tostring(safe(function() return mm:get_name() end, "?")))
            end
            P("   TYPE " .. full .. ": " .. table.concat(names, " "))
        end
    end
    P("======== end damage recon ========")
end

local function update_motion_controls()
    if not cfg.motion_controls then state.mc_status = "off" return end
    if not state.active then state.mc_status = "camera inactive" return end
    if not vrmod:is_hmd_active() then state.mc_status = "no hmd" return end

    local left, right = get_controller_indices()
    if not right then state.mc_status = "no controllers" return end

    pcall(damage_recon)

    -- ---- swing detection: controller speed crosses a threshold
    local now = os.clock()
    if cfg.swing_enabled then
        local vel = safe(function() return vrmod:get_velocity(right) end, nil)
        if vel then
            local sp = math.sqrt((vel.x or 0)^2 + (vel.y or 0)^2 + (vel.z or 0)^2)
            state.swing_speed_now = sp
            if sp >= cfg.swing_speed and (now - state.swing_last) >= cfg.swing_cooldown then
                state.swing_last = now
                state.attack_until = now + cfg.attack_hold
                state.swing_request_until = now + 0.10   -- hold the button briefly
                state.swings = (state.swings or 0) + 1
            end
        end
    end

    -- ---- arm weight: fade out while the attack animation owns the arm
    local target_w = 1.0
    if cfg.attack_yield and now < (state.attack_until or -10) then target_w = 0.0 end
    local step = (cfg.arm_blend_time > 0.001) and (1.0 / (cfg.arm_blend_time * 60.0)) or 1.0
    local w = state.arm_weight or 1.0
    if target_w > w then w = math.min(target_w, w + step) else w = math.max(target_w, w - step) end
    state.arm_weight = w

    if not state.mc_api_dumped and state.joint_r_weapon then
        state.mc_api_dumped = true
        pcall(function() dump_joint_api(state.joint_r_weapon) end)
    end

    -- weapon relationship must be read from the animated pose BEFORE the arm writes
    local jw = state.joint_r_weapon
    local weap_pos_a = jw and safe(function() return joint_get_position:call(jw) end, nil) or nil
    local weap_rot_a = jw and safe(function() return joint_get_rotation:call(jw) end, nil) or nil

    local head_pos = state.head_world_pos

    local r = arm_update(arms.right, right, head_pos)
    local l = nil
    if cfg.arm_drive_left and left then l = arm_update(arms.left, left, head_pos) end

    -- weapon rides the right hand, preserving the animation's own grip relationship
    if r and cfg.mc_drive_weapon and jw and weap_pos_a and weap_rot_a then
        local inv_a = r.hand_rot_a:inverse()
        local rel_rot = inv_a * weap_rot_a
        local rel_pos = inv_a * v_sub(weap_pos_a, r.hand_pos_a)
        safe(function()
            joint_set_position:call(jw, v_add(r.hand_pos_n, r.hand_rot_n * rel_pos))
            joint_set_rotation:call(jw, r.hand_rot_n * rel_rot)
        end)
    end

    state.mc_status = "R:" .. tostring(arms.right.status) .. "  L:" .. tostring(arms.left.status or "-")
end

-- recalibrate both hands from the UI
-- re-measure the hand frames (eg after a costume or weapon change)
local function mc_recalibrate()
    arms.right.frame_ok = false
    arms.left.frame_ok = false
end

-- ================================================================ INPUT
--
-- Quest controllers -> the game's gamepad. Same mechanism praydog uses for RE7/RE8:
-- write stick axes and a button mask into the engine's via.hid.GamePadDevice every
-- frame, before game logic reads it. praydog's RE8 seat is a hook on the game's own
-- PadManager update; DRDR's equivalent is unknown, so this version writes at the
-- engine level (post UpdateHID and pre UpdateBehavior) AND logs everything needed
-- to move to a game level seat if the engine level one is ignored.
--
-- Movement is head relative: the left stick is rotated by the yaw difference between
-- where you are looking and where the game camera points, so pushing forward walks
-- where you look.

cfg.input_enabled     = true
cfg.input_head_steer  = true
cfg.input_invert_yaw  = false
cfg.input_deadzone    = 0.15
cfg.input_debug       = false

local hid_pad_t   = sdk.find_type_definition("via.hid.GamePad")
local hid_pad     = sdk.get_native_singleton("via.hid.GamePad")
local hid_dev_t   = sdk.find_type_definition("via.hid.GamePadDevice")
local pad_btn_t   = sdk.find_type_definition("via.hid.GamePadButton")

-- button enum: name -> value, from the type's static fields
local BTN = {}
do
    if pad_btn_t then
        for _, f in ipairs(safe(function() return pad_btn_t:get_fields() end, {})) do
            if safe(function() return f:is_static() end, false) then
                local n = safe(function() return f:get_name() end, nil)
                local v = safe(function() return f:get_data(nil) end, nil)
                if n and v then BTN[n] = v end
            end
        end
    end
end
local function btn(name) return BTN[name] or 0 end

-- default mapping. Xbox names in comments. Change here, not in the loop.
local MAP = {
    r_trigger   = { "RLeft" },                 -- X : attack
    r_a         = { "RDown", "Decide" },       -- A : jump / confirm
    r_b         = { "RRight", "Cancel" },      -- B : back
    r_grip      = { "RTrigBottom" },           -- RT
    r_stick     = { "RStickPush" },
    l_trigger   = { "LTrigTop" },              -- LB
    l_a         = { "CLeft" },                 -- X button on the left controller: back/select
    l_b         = { "RUp" },                   -- Y
    l_grip      = { "LTrigBottom" },           -- LT
    l_stick     = { "LStickPush" },
    l_menu      = { "CRight" },                -- start / pause
}

local input_state = {
    device = nil,
    device_how = "",
    logged = false,
    last_cmp = 0,
    frames = 0,
    prev_mask = 0,
    inputsys = nil,
    inputsys_hooked = false,
}

-- Every device the engine exposes. The game reads through app.solid.InputSystem's
-- get_LastInputDevice, which is the physical pad, not the merged device. So write to
-- all of them: merged, last input, and every connecting device.
local function input_all_devices()
    local out, seen = {}, {}
    local function add(d, how)
        if d and not seen[d] then seen[d] = true; table.insert(out, { d = d, how = how }) end
    end
    if hid_pad and hid_pad_t then
        add(safe(function() return sdk.call_native_func(hid_pad, hid_pad_t, "get_MergedDevice") end, nil), "merged")
        add(safe(function() return sdk.call_native_func(hid_pad, hid_pad_t, "get_LastInputDevice") end, nil), "last")
        add(safe(function() return sdk.call_native_func(hid_pad, hid_pad_t, "get_Device") end, nil), "device")
        local list = safe(function() return sdk.call_native_func(hid_pad, hid_pad_t, "get_ConnectingDevices") end, nil)
        if list then
            local elems = safe(function() return list:get_elements() end, nil)
            if elems then for i, d in ipairs(elems) do add(d, "conn" .. i) end end
        end
        local n = safe(function() return sdk.call_native_func(hid_pad, hid_pad_t, "getConnectingDevicesCount") end, nil)
        if type(n) == "number" then
            for i = 0, math.min(n, 4) - 1 do
                add(safe(function() return sdk.call_native_func(hid_pad, hid_pad_t, "getDevice", i) end, nil), "dev" .. i)
            end
        end
    end
    return out
end

local function input_get_device()
    if not hid_pad or not hid_pad_t then return nil end
    -- try the likely accessors in order; remember which one worked
    for _, m in ipairs({ "get_MergedDevice", "get_LastInputDevice", "get_ActiveDevice", "get_Device" }) do
        local d = safe(function() return sdk.call_native_func(hid_pad, hid_pad_t, m) end, nil)
        if d then input_state.device_how = m return d end
    end
    local d = safe(function() return sdk.call_native_func(hid_pad, hid_pad_t, "getDevice", 0) end, nil)
    if d then input_state.device_how = "getDevice(0)" return d end
    return nil
end

local function input_discovery_once()
    if input_state.logged then return end
    input_state.logged = true
    P("======== INPUT DISCOVERY ========")

    local names = {}
    for n, _ in pairs(BTN) do table.insert(names, n) end
    table.sort(names)
    P("via.hid.GamePadButton members (" .. tostring(#names) .. "): " .. table.concat(names, " "))

    local function list_methods(td, label, filter)
        if not td then P(label .. ": type missing") return end
        local out = {}
        local d = 0
        while td and d < 3 do
            for _, m in ipairs(safe(function() return td:get_methods() end, {})) do
                local mn = safe(function() return m:get_name() end, "")
                if mn:lower():find(filter) then table.insert(out, mn) end
            end
            td = safe(function() return td:get_parent_type() end, nil)
            d = d + 1
        end
        P(label .. " methods ~" .. filter .. ": " .. table.concat(out, " "))
    end
    list_methods(hid_pad_t, "via.hid.GamePad", "device")
    list_methods(hid_dev_t, "via.hid.GamePadDevice", "axis")
    list_methods(hid_dev_t, "via.hid.GamePadDevice", "button")
    list_methods(hid_dev_t, "via.hid.GamePadDevice", "analog")
    list_methods(hid_dev_t, "via.hid.GamePadDevice", "connect")

    P("device via: " .. tostring(input_state.device_how) .. "  -> " .. tostring(input_state.device ~= nil))

    -- the game side. Guess names; a hit shows where DRDR reads pad state.
    for _, short in ipairs({
        "PadManager", "HIDManager", "HidManager", "InputManager", "InputSystem",
        "GamePadManager", "UserInputManager", "InputDeviceManager", "PadInputManager",
        "ControllerManager", "KeyConfigManager", "SystemInputManager", "hid.PadManager",
        "hid.HIDManager", "input.InputManager", "InputBridge", "PadBridge",
    }) do
        local full = "app.solid." .. short
        local td = safe(function() return sdk.find_type_definition(full) end, nil)
        if td then
            local inst = safe(function() return sdk.get_managed_singleton(full) end, nil)
            P("TYPE " .. full .. "  singleton=" .. tostring(inst ~= nil))
            list_methods(td, "   " .. full, "pad")
            list_methods(td, "   " .. full, "input")
        end
    end

    -- Frank's WORLD component list. Never logged before (only the UI model was).
    -- The input / controller component name shows where Frank's movement comes from.
    if state.player_go then
        local comps = safe(function() return state.player_go:call("get_Components") end, nil)
        local elems = comps and safe(function() return comps:get_elements() end, {}) or {}
        P("Pl_Frank components (" .. tostring(#elems) .. "):")
        for i, c in ipairs(elems) do
            P("   [" .. i .. "] " .. tostring(safe(function() return c:get_type_definition():get_full_name() end, "?")))
        end
    end
    P("======== end INPUT DISCOVERY ========")
end

-- The game's app.solid.InputSystem does not read the engine's merged pad. It keeps its
-- own ActiveUserDevice and an active InputUnit, and with no physical pad connected
-- that device is nothing, so writes to engine devices are read by nobody. This binds
-- the game to the merged device, writes into whatever device the active unit holds,
-- and forces InputMode to the pad value discovered from the enum.
local gs = { logged = false, pad_mode = nil, mode_names = "", unit_dev_fields = nil, bound = false }

local function input_bind_game(isys, merged)
    if not isys then return {} end
    local extra = {}

    -- InputMode enum: find the pad value once
    if gs.pad_mode == nil and not gs.logged then
        local td = safe(function() return isys:get_type_definition() end, nil)
        local m = td and safe(function() return td:get_method("get_InputMode") end, nil) or nil
        local rt = m and safe(function() return m:get_return_type() end, nil) or nil
        local names = {}
        if rt then
            for _, fld in ipairs(safe(function() return rt:get_fields() end, {})) do
                if safe(function() return fld:is_static() end, false) then
                    local n = tostring(safe(function() return fld:get_name() end, "?"))
                    local v = safe(function() return fld:get_data(nil) end, nil)
                    table.insert(names, n .. "=" .. tostring(v))
                    local ln = n:lower()
                    if gs.pad_mode == nil and (ln:find("pad") or ln:find("controller") or ln:find("joy")) then
                        gs.pad_mode = v
                    end
                end
            end
        end
        gs.mode_names = table.concat(names, " ")
        P("InputMode enum: " .. gs.mode_names .. "   -> pad value " .. tostring(gs.pad_mode))
    end

    -- active user device: bind to merged if empty or different
    local aud = safe(function() return isys:call("get_ActiveUserDevice") end, nil)
    if not gs.logged then
        P("InputSystem ActiveUserDevice before: " .. (aud and tostring(safe(function() return aud:get_type_definition():get_full_name() end, "?")) or "nil"))
    end
    if merged and aud ~= merged then
        local ok1 = safe(function() isys:call("set_ActiveUserDevice", merged) return true end, false)
        local ok2 = false
        if not ok1 then ok2 = safe(function() isys:call("changeActiveUserDevice", merged) return true end, false) end
        if not gs.bound then
            gs.bound = true
            P("bind ActiveUserDevice -> merged: set=" .. tostring(ok1) .. " change=" .. tostring(ok2))
        end
        aud = safe(function() return isys:call("get_ActiveUserDevice") end, nil)
    end
    if aud then table.insert(extra, { d = aud, how = "activeUser" }) end

    -- active input unit: write into whatever GamePadDevice fields it holds
    local unit = safe(function() return isys:call("getActiveUserInputUnit") end, nil)
    if unit then
        if gs.unit_dev_fields == nil then
            gs.unit_dev_fields = {}
            local utd = safe(function() return unit:get_type_definition() end, nil)
            local all = {}
            local d = 0
            while utd and d < 4 do
                for _, fld in ipairs(safe(function() return utd:get_fields() end, {})) do
                    local n = tostring(safe(function() return fld:get_name() end, "?"))
                    local t = tostring(safe(function() return fld:get_type():get_full_name() end, "?"))
                    table.insert(all, n .. ":" .. t)
                    if t == "via.hid.GamePadDevice" then table.insert(gs.unit_dev_fields, n) end
                end
                utd = safe(function() return utd:get_parent_type() end, nil)
                d = d + 1
            end
            P("active InputUnit type: " .. tostring(safe(function() return unit:get_type_definition():get_full_name() end, "?")))
            P("active InputUnit fields: " .. table.concat(all, " "))
            P("active InputUnit device fields: " .. table.concat(gs.unit_dev_fields, " "))
            -- unit methods, so the write path is on record
            local mnames = {}
            local utd2 = safe(function() return unit:get_type_definition() end, nil)
            for _, m in ipairs(utd2 and safe(function() return utd2:get_methods() end, {}) or {}) do
                table.insert(mnames, tostring(safe(function() return m:get_name() end, "?")))
            end
            P("active InputUnit methods: " .. table.concat(mnames, " "))
            -- the stick struct layout
            local st = safe(function() return sdk.find_type_definition("app.solid.InputSystem.AnalogStick") end, nil)
            local sf = {}
            for _, fld in ipairs(st and safe(function() return st:get_fields() end, {}) or {}) do
                table.insert(sf, tostring(safe(function() return fld:get_name() end, "?")) .. ":"
                    .. tostring(safe(function() return fld:get_type():get_full_name() end, "?"))
                    .. "@" .. tostring(safe(function() return fld:get_offset_from_base() end, "?")))
            end
            P("AnalogStick fields: " .. table.concat(sf, " "))
            local sm = {}
            for _, m in ipairs(st and safe(function() return st:get_methods() end, {}) or {}) do
                table.insert(sm, tostring(safe(function() return m:get_name() end, "?")))
            end
            P("AnalogStick methods: " .. table.concat(sm, " "))
        end
        for _, fname in ipairs(gs.unit_dev_fields) do
            local dv = safe(function() return unit:get_field(fname) end, nil)
            if not dv and merged then
                safe(function() unit:set_field(fname, merged) end)
                dv = safe(function() return unit:get_field(fname) end, nil)
                if not dv then
                    safe(function() unit:call("set_Device", merged) end)
                    dv = safe(function() return unit:get_field(fname) end, nil)
                end
                if not gs.dev_bind_logged then
                    gs.dev_bind_logged = true
                    P("unit." .. fname .. " bind attempt -> " .. tostring(dv ~= nil))
                end
            end
            if dv then table.insert(extra, { d = dv, how = "unit." .. fname }) end
        end
        gs.unit = unit
    elseif not gs.logged then
        P("getActiveUserInputUnit -> nil")
    end

    -- input mode
    if gs.pad_mode ~= nil then
        local mode = safe(function() return isys:call("get_InputMode") end, nil)
        if mode ~= gs.pad_mode then
            local ok = safe(function() isys:call("set_InputMode", gs.pad_mode) return true end, false)
            if not ok then safe(function() isys:call("changeInputMode", gs.pad_mode) end) end
        end
    end

    gs.logged = true
    return extra
end

-- Write the InputUnit's OWN computed state. Its Device is nil because auto assign only
-- wires connected pads, so its ButtonOn/Down/Up and sticks are computed from nothing.
-- Those are overwritten directly, before and after the game's update, so whichever
-- moment the game samples them it finds the injected values.
local unit_write_logged = false
local cmdbits_logged = false
local stick_strategy = nil     -- decided once, by measurement
local button_strategy = nil

-- AnalogStick is a VALUE TYPE. get_LStick hands back a COPY, so mutating what it
-- returns changes nothing; the previous build wrote to temporaries every frame and
-- read back zero one line later. A value type has to be copied out, mutated, and
-- assigned back. Which assignment form works is not documented, so each is tried once,
-- verify by reading the value back, and keep the one that sticks.

local STICK_STRATS = {
    {
        name = "field-roundtrip",
        write = function(owner, fieldname, propname, v, mag)
            local st = owner:get_field(fieldname)
            if not st then return false end
            st:set_field("<Axis>k__BackingField", Vector2f.new(v.x, v.y))
            st:set_field("<RawAxis>k__BackingField", Vector2f.new(v.x, v.y))
            st:set_field("<Magnitude>k__BackingField", mag)
            st:set_field("<Direction>k__BackingField", Vector3f.new(v.x, 0.0, v.y))
            owner:set_field(fieldname, st)
            return true
        end,
    },
    {
        name = "prop-roundtrip",
        write = function(owner, fieldname, propname, v, mag)
            local st = owner:call("get_" .. propname)
            if not st then return false end
            st:call("set_Axis", Vector2f.new(v.x, v.y))
            st:call("set_RawAxis", Vector2f.new(v.x, v.y))
            st:call("set_Magnitude", mag)
            st:call("set_Direction", Vector3f.new(v.x, 0.0, v.y))
            owner:call("set_" .. propname, st)
            return true
        end,
    },
    {
        name = "field-then-propset",
        write = function(owner, fieldname, propname, v, mag)
            local st = owner:get_field(fieldname)
            if not st then return false end
            st:set_field("<Axis>k__BackingField", Vector2f.new(v.x, v.y))
            st:set_field("<RawAxis>k__BackingField", Vector2f.new(v.x, v.y))
            st:set_field("<Magnitude>k__BackingField", mag)
            st:set_field("<Direction>k__BackingField", Vector3f.new(v.x, 0.0, v.y))
            owner:call("set_" .. propname, st)
            return true
        end,
    },
}

local function stick_readback(owner, fieldname)
    local st = owner:get_field(fieldname)
    if not st then return nil end
    local ax = safe(function() return st:get_field("<Axis>k__BackingField") end, nil)
    return ax
end

-- run every strategy against a probe value and keep whichever reads back
local function decide_stick_strategy(owner, fieldname, propname)
    local probe = Vector2f.new(0.77, -0.33)
    for _, strat in ipairs(STICK_STRATS) do
        local ok = safe(function() return strat.write(owner, fieldname, propname, probe, 0.84) end, false)
        local ax = ok and stick_readback(owner, fieldname) or nil
        local good = ax and math.abs((ax.x or 0) - 0.77) < 0.01
        P(string.format("stick strategy %-18s write=%s readback=%s -> %s",
            strat.name, tostring(ok),
            ax and string.format("(%.2f,%.2f)", ax.x or 0, ax.y or 0) or "nil",
            good and "WORKS" or "no"))
        if good then return strat end
    end
    return nil
end

local function write_one_stick(owner, fieldname, propname, v)
    if not owner then return false end
    local mag = math.sqrt(v.x * v.x + v.y * v.y)
    if mag > 1.0 then mag = 1.0 end
    if stick_strategy then
        return safe(function() return stick_strategy.write(owner, fieldname, propname, v, mag) end, false)
    end
    return false
end

local function input_write_unit(unit, ls, rs, mask, down_mask, up_mask)
    if not unit then return end
    local isys = input_state.inputsys

    -- one time: work out which write form actually lands
    if stick_strategy == nil and not unit_write_logged then
        unit_write_logged = true
        local avt = safe(function() return sdk.find_type_definition("app.solid.InputSystem.AnalogStick"):is_value_type() end, nil)
        P("AnalogStick is_value_type = " .. tostring(avt))
        stick_strategy = decide_stick_strategy(unit, "<_LStick>k__BackingField", "_LStick")
        P("stick strategy chosen: " .. (stick_strategy and stick_strategy.name or "NONE - sticks cannot be written"))

        -- buttons: verify the enum write lands
        safe(function() unit:set_field("<ButtonOn>k__BackingField", 12345) end)
        local rb = safe(function() return unit:get_field("<ButtonOn>k__BackingField") end, nil)
        local field_ok = (rb == 12345)
        safe(function() unit:call("set_ButtonOn", 23456) end)
        local rb2 = safe(function() return unit:call("get_ButtonOn") end, nil)
        local prop_ok = (rb2 == 23456)
        button_strategy = field_ok and "field" or (prop_ok and "prop" or nil)
        P("button write: field=" .. tostring(field_ok) .. " (" .. tostring(rb) .. ")  prop="
            .. tostring(prop_ok) .. " (" .. tostring(rb2) .. ")  -> " .. tostring(button_strategy))
        safe(function() unit:set_field("<ButtonOn>k__BackingField", 0) end)
    end

    -- buttons
    if button_strategy == "prop" then
        safe(function() unit:call("set_ButtonOn", mask) end)
        safe(function() unit:call("set_ButtonDown", down_mask or 0) end)
        safe(function() unit:call("set_ButtonUp", up_mask or 0) end)
    else
        safe(function() unit:set_field("<ButtonOn>k__BackingField", mask) end)
        safe(function() unit:set_field("<ButtonDown>k__BackingField", down_mask or 0) end)
        safe(function() unit:set_field("<ButtonUp>k__BackingField", up_mask or 0) end)
    end

    local al = ((mask & btn("LTrigBottom")) ~= 0) and 1.0 or 0.0
    local ar = ((mask & btn("RTrigBottom")) ~= 0) and 1.0 or 0.0
    safe(function() unit:set_field("<_AnalogL>k__BackingField", al) end)
    safe(function() unit:set_field("<_AnalogR>k__BackingField", ar) end)

    -- sticks, on the unit and on InputSystem's own copies
    write_one_stick(unit, "<_LStick>k__BackingField", "_LStick", ls)
    write_one_stick(unit, "<_RStick>k__BackingField", "_RStick", rs)
    if isys then
        write_one_stick(isys, "<_LStick>k__BackingField", "_LStick", ls)
        write_one_stick(isys, "<_RStick>k__BackingField", "_RStick", rs)
        safe(function() isys:set_field("<_AnalogL>k__BackingField", al) end)
        safe(function() isys:set_field("<_AnalogR>k__BackingField", ar) end)
        safe(function() isys:set_field("<_ButtonBits>k__BackingField", mask) end)
    end

    -- The unit derives CommandBits and its key assign caches from ButtonOn and the
    -- sticks inside its update, which has already run by the time the script writes. Re-run
    -- just those derivations so the command layer the game actually queries reflects
    -- the injected values.
    local before = safe(function() return unit:get_field("<CommandBits>k__BackingField") end, nil)
    safe(function() unit:call("updateButtonBit") end)
    safe(function() unit:call("updateCommand") end)
    local after = safe(function() return unit:get_field("<CommandBits>k__BackingField") end, nil)
    if not cmdbits_logged and mask ~= 0 then
        cmdbits_logged = true
        P("CommandBits after recompute: " .. tostring(before) .. " -> " .. tostring(after) .. "  (mask " .. tostring(mask) .. ")")
    end
end

-- controller state, declared before the query intercept so its closures capture
-- these locals rather than silently reading globals
local last_ls, last_rs, last_mask, last_down, last_up = nil, nil, 0, 0, 0

-- ---------------------------------------------------------------- query intercept
--
-- The guaranteed path. Whatever the internal pipeline does, the game asks the unit
-- questions: isOn(kind), isDown(kind), isUp(kind), isRepeat(kind). Those are answered
-- from the injected mask, mapping each Kind to its physical button with the unit's own
-- getGamePadButton, so no assumption about key assignment is needed.

local qi = { hooked = false, logged = {}, calls = 0, map = {} }

-- The game's whole input pipeline is gated on the device being connected:
-- merged device Connecting = false -> hasInputPad = false -> the unit never reads the
-- device, so ButtonOn and the sticks are recomputed from nothing and CommandBits stays
-- zero no matter what is stored. There is no set_Connecting, so intercept the getter
-- and answer true for the injected device only. Everything downstream then runs the game's own
-- code path with the injected values, which is the goal.
local conn = { hooked = false, target = nil, force = false, hits = 0 }

local function install_connecting_hook()
    if conn.hooked then return end
    local td = sdk.find_type_definition("via.hid.GamePadDevice")
    if not td then P("connecting hook: GamePadDevice type missing") return end
    local m = td:get_method("get_Connecting")
    if not m then P("connecting hook: get_Connecting missing") return end
    conn.hooked = true

    local ok, err = pcall(function()
        sdk.hook(m,
            function(args)
                conn.force = false
                if conn.target ~= nil then
                    local this = args[2]
                    if this ~= nil and sdk.to_int64(this) == conn.target then
                        conn.force = true
                    end
                end
            end,
            function(retval)
                if conn.force then
                    conn.force = false
                    conn.hits = conn.hits + 1
                    return sdk.to_ptr(1)
                end
                return retval
            end)
    end)
    P("connecting hook installed: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
end

local function query_answer(kind_val, which)
    if not last_mask then return nil end
    local unit = gs.unit
    if not unit then return nil end
    local want = qi.map[kind_val]
    if want == nil then
        want = safe(function() return unit:call("getGamePadButton", kind_val) end, nil)
        qi.map[kind_val] = want or false
    end
    if not want or want == false then return nil end

    local m = (which == "down") and last_down or ((which == "up") and last_up or last_mask)
    return (m & want) ~= 0
end

local function install_query_hooks()
    if qi.hooked then return end
    qi.hooked = true
    qi.map = {}

    -- get_params() does not exist in this REFramework build; the previous version
    -- filtered on it, got -1 every time, and installed nothing at all. Hook every
    -- overload instead and let the Kind lookup decide whether to answer.
    --
    -- Hook BOTH the unit and InputSystem: the game almost certainly calls the
    -- InputSystem helpers, which delegate down, so that is the level to answer at.
    local targets = {
        { tn = "app.solid.InputUnit",    names = { isOn = "on", isDown = "down", isUp = "up", isRepeat = "on" } },
        { tn = "app.solid.InputSystem",  names = { isOn = "on", isDown = "down", isUp = "up", isRepeat = "on",
                                                   isTrigger = "down", isRelease = "up" } },
    }

    for _, t in ipairs(targets) do
        local td = safe(function() return sdk.find_type_definition(t.tn) end, nil)
        if not td then
            P("query intercept: " .. t.tn .. " NOT FOUND")
        else
            for mname, which in pairs(t.names) do
                local n = 0
                for _, m in ipairs(safe(function() return td:get_methods() end, {})) do
                    if safe(function() return m:get_name() end, "") == mname then
                        n = n + 1
                        local hok, herr = pcall(function()
                            sdk.hook(m,
                                function(args)
                                    qi.force = nil
                                    local ok, res = pcall(function()
                                        local kind = sdk.to_int64(args[3]) & 0xFFFFFFFF
                                        return query_answer(kind, which)
                                    end)
                                    if ok and res == true then
                                        qi.force = true
                                        qi.calls = qi.calls + 1
                                    end
                                end,
                                function(retval)
                                    if qi.force then
                                        qi.force = nil
                                        return sdk.to_ptr(1)
                                    end
                                    return retval
                                end)
                        end)
                        if not hok then
                            P("query intercept " .. t.tn .. "::" .. mname .. " #" .. n .. " FAILED: " .. tostring(herr))
                        end
                    end
                end
                P("query intercept " .. t.tn .. "::" .. mname .. " hooked " .. tostring(n) .. " overload(s)")
            end
        end
    end
end

function input_inject_devices_only()
    if not last_ls then return end
    local devices = input_all_devices()
    local merged = nil
    for _, e in ipairs(devices) do if e.how == "merged" then merged = e.d end end
    local seen = {}
    for _, e in ipairs(devices) do seen[e.d] = true end
    for _, e in ipairs(input_bind_game(input_state.inputsys, merged)) do
        if not seen[e.d] then seen[e.d] = true; table.insert(devices, e) end
    end
    for _, entry in ipairs(devices) do
        local d = entry.d
        safe(function() d:call("set_AxisL", last_ls) end)
        safe(function() d:call("set_RawAxisL", last_ls) end)
        safe(function() d:call("set_AxisR", last_rs) end)
        safe(function() d:call("set_RawAxisR", last_rs) end)
        if last_mask ~= 0 then
            local cur = safe(function() return d:call("get_Button") end, 0) or 0
            safe(function() d:call("set_Button", cur | last_mask) end)
        end
    end
    input_write_unit(gs.unit, last_ls, last_rs, last_mask, last_down, last_up)
end

-- post update: overwrite whatever the game just computed from its nil device
function input_post_update()
    if not last_ls then return end
    input_write_unit(gs.unit, last_ls, last_rs, last_mask, last_down, last_up)
end

local function rotate2(v, ang)
    local c, s = math.cos(ang), math.sin(ang)
    return Vector2f.new(v.x * c - v.y * s, v.x * s + v.y * c)
end

local function deadzone(v)
    local l = math.sqrt(v.x * v.x + v.y * v.y)
    if l < cfg.input_deadzone then return Vector2f.new(0, 0) end
    local k = (l - cfg.input_deadzone) / (1 - cfg.input_deadzone) / l
    return Vector2f.new(v.x * k, v.y * k)
end

local function input_inject()
    if not cfg.input_enabled then return end
    if not vrmod:is_hmd_active() then return end
    if not safe(function() return vrmod:is_using_controllers() end, false) then return end

    input_state.device = input_state.device or input_get_device()
    input_discovery_once()
    local devices = input_all_devices()
    if #devices == 0 then return end
    local dev = devices[1].d

    -- game side binding, adds the game's own active device(s) to the write list
    if not input_state.inputsys then
        input_state.inputsys = safe(function() return sdk.get_managed_singleton("app.solid.InputSystem") end, nil)
    end
    do
        local merged = nil
        for _, e in ipairs(devices) do if e.how == "merged" then merged = e.d end end
        local seen = {}
        for _, e in ipairs(devices) do seen[e.d] = true end
        for _, e in ipairs(input_bind_game(input_state.inputsys, merged)) do
            if not seen[e.d] then seen[e.d] = true; table.insert(devices, e) end
        end
    end

    local ljoy, rjoy = get_joysticks()

    local ls = safe(function() return vrmod:get_left_stick_axis() end, nil) or Vector2f.new(0, 0)
    local rs = safe(function() return vrmod:get_right_stick_axis() end, nil) or Vector2f.new(0, 0)
    ls = deadzone(ls)
    rs = deadzone(rs)

    -- head relative movement
    if cfg.input_head_steer and state.hmd_yaw_delta then
        local a = state.hmd_yaw_delta
        if cfg.input_invert_yaw then a = -a end
        ls = rotate2(ls, a)
    end

    -- ls/rs are written to every device below, after the button mask is built

    -- buttons
    local mask = 0
    local function press(name) for _, b in ipairs(MAP[name] or {}) do mask = mask | btn(b) end end
    local function active(getter, idx)
        local act = safe(function() return vrmod[getter](vrmod) end, nil)
        if not act or not idx then return false end
        return safe(function() return vrmod:is_action_active(act, idx) end, false)
    end

    -- a swing presses attack, so the game plays its own animation and its own hitbox
    if state.swing_request_until and os.clock() < state.swing_request_until then
        press("r_trigger")
    end

    if active("get_action_trigger", rjoy)        then press("r_trigger") end
    if active("get_action_grip", rjoy)           then press("r_grip") end
    if active("get_action_a_button", rjoy)       then press("r_a") end
    if active("get_action_b_button", rjoy)       then press("r_b") end
    if active("get_action_joystick_click", rjoy) then press("r_stick") end
    if ljoy then
        if active("get_action_trigger", ljoy)        then press("l_trigger") end
        if active("get_action_grip", ljoy)           then press("l_grip") end
        if active("get_action_a_button", ljoy)       then press("l_a") end
        if active("get_action_b_button", ljoy)       then press("l_b") end
        if active("get_action_joystick_click", ljoy) then press("l_stick") end
        if active("get_action_system_button", ljoy)  then press("l_menu") end
    end

    -- proper edges: Down only on the frame a bit appears, Up on the frame it clears
    local prev = input_state.prev_mask or 0
    local down_mask = mask & ~prev
    local up_mask   = prev & ~mask
    input_state.prev_mask = mask

    for _, entry in ipairs(devices) do
        local d = entry.d
        safe(function() d:call("set_AxisL", ls) end)
        safe(function() d:call("set_RawAxisL", ls) end)
        safe(function() d:call("set_AxisR", rs) end)
        safe(function() d:call("set_RawAxisR", rs) end)
        if mask ~= 0 or prev ~= 0 then
            local cur = safe(function() return d:call("get_Button") end, 0) or 0
            safe(function() d:call("set_Button", cur | mask) end)
            if down_mask ~= 0 then
                local cd = safe(function() return d:call("get_ButtonDown") end, 0) or 0
                safe(function() d:call("set_ButtonDown", cd | down_mask) end)
            end
            if up_mask ~= 0 then
                local cu = safe(function() return d:call("get_ButtonUp") end, 0) or 0
                safe(function() d:call("set_ButtonUp", cu | up_mask) end)
            end
        end
    end

    -- watch the game's own input system so the log says whether it sees pad input
    if input_state.inputsys then
        if not input_state.inputsys_hooked then
            input_state.inputsys_hooked = true
            local isys_local = input_state.inputsys
            local td = safe(function() return input_state.inputsys:get_type_definition() end, nil)
            local names = {}
            for _, m in ipairs(td and safe(function() return td:get_methods() end, {}) or {}) do
                table.insert(names, tostring(safe(function() return m:get_name() end, "?")))
            end
            P("app.solid.InputSystem all methods: " .. table.concat(names, " "))
            local mode = safe(function() return input_state.inputsys:call("get_InputMode") end, nil)
            P("InputSystem InputMode now: " .. tostring(mode))
            -- The unit recomputes its state from the device inside its own update. Hook
            -- that on the POST side so the injected values are the last word, whatever the
            -- device did or did not provide.
            local utd = safe(function() return sdk.find_type_definition("app.solid.InputUnit") end, nil)
            local um = utd and safe(function() return utd:get_method("update") end, nil) or nil
            if um then
                safe(function()
                    sdk.hook(um, nil, function(retval) pcall(input_post_update) return retval end)
                    P("hooked app.solid.InputUnit::update (post) for injection")
                end)
            else
                P("app.solid.InputUnit::update NOT FOUND")
            end

            pcall(install_query_hooks)
            pcall(install_connecting_hook)

            -- tell the connecting hook which device to vouch for
            local merged1 = safe(function() return sdk.call_native_func(hid_pad, hid_pad_t, "get_MergedDevice") end, nil)
            if merged1 then
                conn.target = safe(function() return sdk.to_int64(sdk.to_ptr(merged1)) end, nil)
                P("connecting hook target set: " .. tostring(conn.target ~= nil))
            end

            -- a device type of Unknown can stop key assignment mapping; log the enum and
            -- pick a standard pad if the current value looks unset
            local dt = safe(function() return sdk.find_type_definition("app.solid.InputDefine.InputPadDeviceType") end, nil)
            if dt then
                local names = {}
                for _, fld in ipairs(safe(function() return dt:get_fields() end, {})) do
                    if safe(function() return fld:is_static() end, false) then
                        table.insert(names, tostring(safe(function() return fld:get_name() end, "?")) .. "="
                            .. tostring(safe(function() return fld:get_data(nil) end, "?")))
                    end
                end
                P("InputPadDeviceType enum: " .. table.concat(names, " "))
            end
            local u1 = safe(function() return isys_local:call("getActiveUserInputUnit") end, nil)
            if u1 then
                P("unit InputPadDeviceType now = " .. tostring(safe(function() return u1:get_field("<InputPadDeviceType>k__BackingField") end, nil)))
            end

            -- device connectivity, the likely reason auto assign ignores the merged pad
            local merged0 = safe(function() return sdk.call_native_func(hid_pad, hid_pad_t, "get_MergedDevice") end, nil)
            if merged0 then
                P("merged device Connecting = " .. tostring(safe(function() return merged0:call("get_Connecting") end, nil)))
            end
            local u0 = safe(function() return isys_local:call("getActiveUserInputUnit") end, nil)
            if u0 then
                P("unit hasInputPad = " .. tostring(safe(function() return u0:call("hasInputPad") end, nil))
                    .. "  validGamePadDevice = " .. tostring(safe(function() return u0:call("validGamePadDevice") end, nil)))
            end

            -- also inject right before the game's own per frame update, if it has one
            for _, mn in ipairs({ "update", "lateUpdate", "updateInput", "onUpdate" }) do
                local m = td and safe(function() return td:get_method(mn) end, nil) or nil
                if m then
                    safe(function()
                        sdk.hook(m,
                            function(args) pcall(input_inject_devices_only) end,
                            function(retval) pcall(input_post_update) return retval end)
                        P("hooked app.solid.InputSystem::" .. mn .. " (pre+post) for injection")
                    end)
                end
            end
        end
    end

    last_ls, last_rs, last_mask, last_down, last_up = ls, rs, mask, down_mask, up_mask
    input_write_unit(gs.unit, ls, rs, mask, down_mask, up_mask)

    -- periodic evidence: what the game side sees
    input_state.frames = input_state.frames + 1
    if cfg.input_debug or (input_state.frames % 300 == 0) then
        if (math.abs(ls.x) + math.abs(ls.y)) > 0.3 or mask ~= 0 then
            local hows = {}
            for _, e in ipairs(devices) do table.insert(hows, e.how) end
            local isys = input_state.inputsys
            local anypad = isys and safe(function() return isys:call("checkHasAnyPadInput") end, nil) or nil
            local mode = isys and safe(function() return isys:call("get_InputMode") end, nil) or nil
            local aud = isys and safe(function() return isys:call("get_ActiveUserDevice") end, nil) or nil
            local u = gs.unit
            local ax = u and safe(function()
                local st = u:get_field("<_LStick>k__BackingField")
                return st and st:get_field("<Axis>k__BackingField") or nil
            end, nil) or nil
            local ub = u and safe(function() return u:get_field("<ButtonOn>k__BackingField") end, nil) or nil
            P(string.format("input: vrL=(%.2f,%.2f) mask=%d devices=[%s] mode=%s unitAxis=%s unitButtonOn=%s strat=%s/%s",
                ls.x, ls.y, mask, table.concat(hows, ","), tostring(mode),
                ax and string.format("(%.2f,%.2f)", ax.x or 0, ax.y or 0) or "nil",
                tostring(ub),
                stick_strategy and stick_strategy.name or "none", tostring(button_strategy))
                .. "  intercepts=" .. tostring(qi.calls)
                .. "  connHits=" .. tostring(conn.hits)
                .. "  hasInputPad=" .. tostring(gs.unit and safe(function() return gs.unit:call("hasInputPad") end, nil))
                .. "  cmdBits=" .. tostring(gs.unit and safe(function() return gs.unit:get_field("<CommandBits>k__BackingField") end, nil)))
        end
    end
end

re.on_application_entry("UpdateHID", function() pcall(input_inject) end)
re.on_pre_application_entry("UpdateBehavior", function() pcall(input_inject) end)

-- Put everything back the way the game had it. Must cover the near clip too,
-- otherwise taking the headset off leaves the flat game with a clipped view.
local function disengage()
    set_head_hidden(false)
    if state.near_clip_saved and state.near_clip_orig then
        local camera = sdk.get_primary_camera()
        if camera then
            safe(function() camera:call("set_NearClipPlane", state.near_clip_orig) end)
        end
    end
    state.active = false
end

local function write_camera(main_camera)
    if not vrmod:is_hmd_active() then
        disengage()
        return
    end

    if not cfg.enabled then
        disengage()
        return
    end

    if not refresh_pointers(false) then
        state.last_error = "no Pl_Frank"
        disengage()
        return
    end

    update_cutscene_state()

    if cfg.disable_in_cutscene and state.in_cutscene then
        disengage()
        return
    end

    if not state.head_joint then
        state.last_error = "no C_Head joint"
        state.active = false
        return
    end

    local camera = sdk.get_primary_camera()
    if not camera then state.last_error = "no primary camera" return end

    -- Near clip is the reliable way to get Frank's head out of the view. It does not
    -- care where his body meshes live in the scene graph, which matters here because
    -- his hierarchy contains only carried items, not his body.
    if cfg.use_near_clip then
        if not state.near_clip_saved then
            state.near_clip_orig = safe(function() return camera:call("get_NearClipPlane") end, nil)
            state.near_clip_saved = true
            P("original near clip: " .. tostring(state.near_clip_orig))
        end
        safe(function() camera:call("set_NearClipPlane", cfg.near_clip) end)
    end

    local camera_go = safe(function() return component_get_gameobject:call(camera) end, nil)
    if not camera_go then return end
    local camera_transform = safe(function() return gameobject_get_transform:call(camera_go) end, nil)
    if not camera_transform then return end

    -- current camera orientation is kept, only the position is relocated to the head
    local camera_rot = transform_get_rotation:call(camera_transform)
    if not camera_rot then return end

    local head_pos = joint_get_position:call(state.head_joint)
    if not head_pos then state.last_error = "no head position" return end

    -- offset out of the skull to roughly eye level, in camera space.
    -- RE Engine forward is -Z. Getting this sign wrong pushes the camera out of the
    -- BACK of the head, which looks exactly like the offset doing nothing useful.
    local fz    = cfg.forward_is_neg_z and -1.0 or 1.0
    local fwd   = camera_rot * Vector3f.new(0, 0, fz)
    local up    = camera_rot * Vector3f.new(0, 1, 0)
    local right = camera_rot * Vector3f.new(1, 0, 0)

    local camera_pos = Vector3f.new(
        head_pos.x + fwd.x * cfg.eye_forward + up.x * cfg.eye_up + right.x * cfg.eye_right,
        head_pos.y + fwd.y * cfg.eye_forward + up.y * cfg.eye_up + right.y * cfg.eye_right,
        head_pos.z + fwd.z * cfg.eye_forward + up.z * cfg.eye_up + right.z * cfg.eye_right)

    local camera_rot_pre_hmd = camera_rot:clone()
    local camera_pos_pre_hmd = camera_pos:clone()

    -- Body facing for the arm system: yaw only, from the game's own camera rotation
    -- BEFORE the hmd is applied, so turning your head does not swing the elbows.
    -- Built from the world right vector rather than to_quat, so its handedness is
    -- unambiguous: body_right is exactly what the elbow hint needs.
    do
        local r = camera_rot_pre_hmd * Vector3f.new(1, 0, 0)
        local l = math.sqrt(r.x * r.x + r.z * r.z)
        if l > 1e-4 then
            state.body_right = Vector3f.new(r.x / l, 0, r.z / l)
            local f = camera_rot_pre_hmd * Vector3f.new(0, 0, fz)
            local lf = math.sqrt(f.x * f.x + f.z * f.z)
            if lf > 1e-4 then
                state.body_back = Vector3f.new(-f.x / lf, 0, -f.z / lf)
                state.body_fwd  = Vector3f.new(f.x / lf, 0, f.z / lf)
            end
        end
    end

    -- mutates both in place
    vrmod:apply_hmd_transform(camera_rot, camera_pos)
    state.head_world_pos = camera_pos:clone()

    -- The VIEW frame: where the player is actually looking, after the headset is
    -- applied. The arms belong to the player, so every arm calculation uses this.
    -- The old body_right/body_back came from the - Hinny that GOAT - game camera BEFORE the headset,
    -- which is a different direction entirely once Frank turns, and that mismatch is
    -- what crossed the arms when walking backwards or sideways.
    do
        local r = camera_rot * Vector3f.new(1, 0, 0)
        local lr = math.sqrt(r.x * r.x + r.z * r.z)
        if lr > 1e-4 then state.view_right = Vector3f.new(r.x / lr, 0, r.z / lr) end
        local fv = camera_rot * Vector3f.new(0, 0, fz)
        local lf = math.sqrt(fv.x * fv.x + fv.z * fv.z)
        if lf > 1e-4 then
            state.view_fwd  = Vector3f.new(fv.x / lf, 0, fv.z / lf)
            state.view_back = Vector3f.new(-fv.x / lf, 0, -fv.z / lf)
        end
    end

    -- signed yaw between where the game camera points and where you are looking,
    -- positive = looking left of the game camera. Used to steer the left stick.
    do
        local fpre  = camera_rot_pre_hmd * Vector3f.new(0, 0, fz)
        local fpost = camera_rot * Vector3f.new(0, 0, fz)
        local ax, az = fpre.x, fpre.z
        local bx, bz = fpost.x, fpost.z
        local la, lb = math.sqrt(ax*ax + az*az), math.sqrt(bx*bx + bz*bz)
        if la > 1e-4 and lb > 1e-4 then
            ax, az, bx, bz = ax/la, az/la, bx/lb, bz/lb
            local cross_y = az * bx - ax * bz
            local dot = ax * bx + az * bz
            state.hmd_yaw_delta = (math.atan2 or math.atan)(cross_y, dot)
        end
    end

    -- Capture the room space to world transform for the motion control code.
    --
    -- This does not try to rebuild what apply_hmd_transform does internally, it inverts
    -- it. The final camera pose corresponds exactly to the HMD's room space pose, so
    --   room_to_world = final_camera * inverse(hmd_local)
    -- and every controller pose can then be mapped with the same transform. This
    -- stays correct through recentering and standing origin changes for free.
    do
        local hmd_pos_local = safe(function() return vrmod:get_position(0) end, nil)
        local hmd_rot_local = safe(function()
            local r = vrmod:get_rotation(0)
            return r and r:to_quat() or nil
        end, nil)
        if hmd_pos_local and hmd_rot_local then
            state.room_rot = camera_rot * hmd_rot_local:inverse()
            state.room_pos = camera_pos - (state.room_rot * hmd_pos_local)
        else
            state.room_rot, state.room_pos = nil, nil
        end
    end

    -- Transform drives game logic. Full HMD transform goes here.
    transform_set_position:call(camera_transform, camera_pos)
    transform_set_rotation:call(camera_transform, camera_rot)

    -- The joint is what actually renders. It gets the PRE hmd position and only the
    -- YAW of the hmd delta, because REFramework's stereo renderer adds the full hmd
    -- pose on top of this. Feeding it the full rotation double applies pitch and roll.
    local camera_joint = nil
    if main_camera then
        camera_joint = safe(function()
            return main_camera:get_field("<CameraJoint>k__BackingField")
        end, nil)
    end
    if not camera_joint then
        camera_joint = safe(function()
            local joints = camera_transform:call("get_Joints")
            return joints and joints[0] or nil
        end, nil)
    end

    if camera_joint then
        local rot_delta = camera_rot_pre_hmd:inverse() * camera_rot
        local forward = rot_delta * Vector3f.new(0, 0, 1)
        forward = Vector3f.new(forward.x, 0.0, forward.z):normalized()

        joint_set_position:call(camera_joint, camera_pos_pre_hmd)
        joint_set_rotation:call(camera_joint, camera_rot_pre_hmd * forward:to_quat())
    end

    -- feed the game's own camera state so its solver stops dragging the camera back
    if main_camera then
        safe(function() main_camera:set_field("<CameraPosition>k__BackingField", camera_pos_pre_hmd) end)
        safe(function() main_camera:set_field("<CameraRotation>k__BackingField", camera_rot_pre_hmd) end)
    end

    set_head_hidden(cfg.hide_head)
    state.active = true
    state.last_error = ""

    -- Align Frank's body with the view. Without this his body and the player's head
    -- point in different directions and no arm solution can look right: his right
    -- shoulder ends up on the player's left. Yaw only, written every frame because
    -- the game rotates him toward his movement direction.
    if state.player_tr and state.body_fwd then
        local cur = safe(function() return transform_get_rotation:call(state.player_tr) end, nil)
        if cur then
            local cf = cur * Vector3f.new(0, 0, fz)
            local lc = math.sqrt(cf.x * cf.x + cf.z * cf.z)
            if lc > 1e-4 then
                local cur_fwd = Vector3f.new(cf.x / lc, 0, cf.z / lc)
                local dot = cur_fwd.x * state.body_fwd.x + cur_fwd.z * state.body_fwd.z
                if dot > 1 then dot = 1 elseif dot < -1 then dot = -1 end
                state.body_angle = math.deg(math.acos(dot))

                -- Measure first. If Frank's forward reads as 180 degrees from the camera
                -- while he is walking forward, the forward sign used for the CHARACTER is
                -- wrong, and pinning would chase its own tail forever.
                if not state.body_angle_logged then
                    state.body_angle_logged = true
                    P(string.format("body vs camera heading: %.1f deg  (camera fwd %.2f,%.2f  frank fwd %.2f,%.2f)",
                        state.body_angle, state.body_fwd.x, state.body_fwd.z, cur_fwd.x, cur_fwd.z))
                end

                -- Damped and thresholded, so it can never oscillate at full rate.
                if cfg.body_follow_view and state.body_angle > cfg.body_pin_deadzone then
                    local d = rot_between(cur_fwd, state.body_fwd)
                    if d then
                        local p = rot_partial(d, cfg.body_pin_rate, 180)
                        safe(function() transform_set_rotation:call(state.player_tr, p * cur) end)
                    end
                end
            end
        end
    end

    update_motion_controls()

    if not state.logged_once then
        state.logged_once = true
        P("first person engaged")
        P("   head joint pos : " .. string.format("%.3f, %.3f, %.3f", head_pos.x, head_pos.y, head_pos.z))
        P("   camera pos     : " .. string.format("%.3f, %.3f, %.3f", camera_pos.x, camera_pos.y, camera_pos.z))
        P("   camera joint   : " .. tostring(camera_joint ~= nil))
        P("   head meshes    : " .. tostring(#state.head_meshes))
        P("   head method    : " .. tostring(state.head_method))
    end
end

-- ---------------------------------------------------------------- hook

local last_main_camera = nil

local tdef_default_main = sdk.find_type_definition("app.solid.camera.DefaultMainCamera")
if not tdef_default_main then
    P("FATAL: app.solid.camera.DefaultMainCamera not found")
    return
end

local method_late_update = tdef_default_main:get_method("lateUpdate")
if not method_late_update then
    P("FATAL: DefaultMainCamera lateUpdate not found")
    return
end

sdk.hook(method_late_update,
    function(args)
        -- args[1] is context, args[2] is `this`. Post hooks only receive retval,
        -- so stash it here.
        last_main_camera = sdk.to_managed_object(args[2])
    end,
    function(retval)
        local mc = last_main_camera
        if mc then
            local ok, err = pcall(function() write_camera(mc) end)
            if not ok then
                state.last_error = tostring(err)
                if cfg.debug_log then P("write_camera error: " .. tostring(err)) end
            end
        end
        return retval
    end)

P("hooked app.solid.camera.DefaultMainCamera::lateUpdate")

-- Animation keeps overwriting joint writes, so reapply after the motion pass as well.
-- praydog reapplies hand IK at four separate points in RE8 for the same reason.
re.on_application_entry("LateUpdateBehavior", function()
    if not cfg.motion_controls then return end
    pcall(update_motion_controls)
end)

-- ---------------------------------------------------------------- ui

re.on_draw_ui(function()
    if not imgui.tree_node("DRDR First Person VR") then return end

    local changed
    changed, cfg.enabled = imgui.checkbox("Enabled", cfg.enabled)
    changed, cfg.hide_head = imgui.checkbox("Hide head mesh", cfg.hide_head)
    changed, cfg.hide_whole_body = imgui.checkbox("Hide whole body (last resort)", cfg.hide_whole_body)
    changed, cfg.disable_in_cutscene = imgui.checkbox("Disable during scripted cameras", cfg.disable_in_cutscene)

    changed, cfg.forward_is_neg_z = imgui.checkbox("Forward is -Z (RE Engine)", cfg.forward_is_neg_z)
    changed, cfg.use_near_clip = imgui.checkbox("Use near clip to cut the head", cfg.use_near_clip)
    changed, cfg.near_clip = imgui.drag_float("Near clip", cfg.near_clip, 0.005, 0.01, 0.6)

    changed, cfg.eye_forward = imgui.drag_float("Eye forward", cfg.eye_forward, 0.005, -0.5, 0.5)
    changed, cfg.eye_up      = imgui.drag_float("Eye up", cfg.eye_up, 0.005, -0.5, 0.5)
    changed, cfg.eye_right   = imgui.drag_float("Eye right", cfg.eye_right, 0.005, -0.5, 0.5)

    imgui.text("active      : " .. tostring(state.active))
    imgui.text("in cutscene : " .. tostring(state.in_cutscene))
    imgui.text("player      : " .. tostring(state.player_go ~= nil))
    imgui.text("head joint  : " .. tostring(state.head_joint ~= nil))
    imgui.text("head meshes : " .. tostring(#state.head_meshes))
    imgui.text("head method : " .. tostring(state.head_method))
    imgui.text("last error  : " .. tostring(state.last_error))

    imgui.new_line()
    imgui.text("--- VR arms ---")
    changed, cfg.motion_controls = imgui.checkbox("Motion controls enabled", cfg.motion_controls)
    changed, cfg.mc_drive_weapon = imgui.checkbox("Weapon rides the right hand", cfg.mc_drive_weapon)
    changed, cfg.arm_drive_left  = imgui.checkbox("Drive left arm", cfg.arm_drive_left)
    changed, cfg.mc_swap_hands   = imgui.checkbox("Swap left/right controller", cfg.mc_swap_hands)

    -- Hold the controllers the way you would naturally hold a weapon, then press this.
    if imgui.button("RE-MEASURE HAND FRAMES") then mc_recalibrate() end
    imgui.same_line()
    imgui.text("R:" .. tostring(arms.right.frame_ok) .. " L:" .. tostring(arms.left.frame_ok))
    changed, cfg.arm_flip_palm = imgui.checkbox("Flip palm mapping (only if palms face the wrong way)", cfg.arm_flip_palm)
    if changed then mc_recalibrate() end

    changed, cfg.arm_learn        = imgui.checkbox("Learn player arm length", cfg.arm_learn)
    changed, cfg.arm_player_len   = imgui.drag_float("Player arm length override (0=learned)", cfg.arm_player_len, 0.005, 0.0, 0.9)
    changed, cfg.arm_anchor_frank = imgui.checkbox("Anchor at Frank's shoulder (arms right) / off = at your shoulder (hands exact)", cfg.arm_anchor_frank)
    changed, cfg.body_follow_view  = imgui.checkbox("Pin body to camera heading (EXPERIMENTAL, can spin)", cfg.body_follow_view)
    changed, cfg.body_pin_rate     = imgui.drag_float("Pin correction rate", cfg.body_pin_rate, 0.01, 0.02, 1.0)
    changed, cfg.body_pin_deadzone = imgui.drag_float("Pin deadzone deg", cfg.body_pin_deadzone, 0.5, 0.0, 90.0)
    imgui.text(string.format("body vs camera: %.1f deg", state.body_angle or 0))
    changed, cfg.arm_neck_drop     = imgui.drag_float("Eyes to shoulder drop", cfg.arm_neck_drop, 0.005, 0.05, 0.40)
    changed, cfg.arm_neck_back     = imgui.drag_float("Eyes to shoulder back", cfg.arm_neck_back, 0.005, -0.10, 0.30)
    changed, cfg.arm_shoulder_half = imgui.drag_float("Half shoulder width", cfg.arm_shoulder_half, 0.005, 0.05, 0.35)
    imgui.text(string.format("reach now  R %.3f / %.3f   ext %.2f",
        arms.right.last_dist or 0, arms.right.last_plen or 0, arms.right.last_ratio or 0))
    imgui.text(string.format("learned arm len  R %.3f  L %.3f   frank %.3f",
        arms.right.player_len or 0, arms.left.player_len or 0, arms.right.frank_len or 0))
    imgui.text(string.format("extension now    R %.2f  L %.2f", arms.right.last_ratio or 0, arms.left.last_ratio or 0))
    if imgui.button("Reset learned arm length") then state.player_arm_len = nil; state.eye_height_max = nil end
    imgui.text(string.format("eye height max %.2f  -> arm prior %.3f", state.eye_height_max or 0, 0.33 * ((state.eye_height_max or 0) + 0.11)))
    changed, cfg.arm_clavicle     = imgui.drag_float("Clavicle share", cfg.arm_clavicle, 0.01, 0.0, 0.8)
    changed, cfg.arm_clavicle_max = imgui.drag_float("Clavicle max deg", cfg.arm_clavicle_max, 0.5, 0.0, 60.0)
    changed, cfg.arm_elbow_hyst   = imgui.drag_float("Elbow hint smoothing", cfg.arm_elbow_hyst, 0.01, 0.0, 0.95)

    changed, cfg.mc_weapon_off_x = imgui.drag_float("Wrist trim X", cfg.mc_weapon_off_x, 0.005, -0.3, 0.3)
    changed, cfg.mc_weapon_off_y = imgui.drag_float("Wrist trim Y", cfg.mc_weapon_off_y, 0.005, -0.3, 0.3)
    changed, cfg.mc_weapon_off_z = imgui.drag_float("Wrist trim Z", cfg.mc_weapon_off_z, 0.005, -0.3, 0.3)

    imgui.new_line()
    imgui.text("--- Swing to attack ---")
    changed, cfg.swing_enabled  = imgui.checkbox("Swing triggers the game's attack", cfg.swing_enabled)
    changed, cfg.attack_yield   = imgui.checkbox("Yield the arm while the attack plays", cfg.attack_yield)
    changed, cfg.swing_speed    = imgui.drag_float("Swing speed threshold m/s", cfg.swing_speed, 0.05, 0.5, 8.0)
    changed, cfg.swing_cooldown = imgui.drag_float("Swing cooldown s", cfg.swing_cooldown, 0.01, 0.05, 1.5)
    changed, cfg.attack_hold    = imgui.drag_float("Animation owns arm for s", cfg.attack_hold, 0.01, 0.1, 2.0)
    changed, cfg.arm_blend_time = imgui.drag_float("Arm blend s", cfg.arm_blend_time, 0.01, 0.0, 0.6)
    imgui.text(string.format("hand speed %.2f m/s   swings %d   arm weight %.2f",
        state.swing_speed_now or 0, state.swings or 0, state.arm_weight or 1))

    imgui.new_line()
    imgui.text("mc status   : " .. tostring(state.mc_status))

    imgui.new_line()
    imgui.text("--- Input (Quest controllers -> gamepad) ---")
    changed, cfg.input_enabled    = imgui.checkbox("Inject controller input", cfg.input_enabled)
    changed, cfg.input_head_steer = imgui.checkbox("Move where you look (head relative stick)", cfg.input_head_steer)
    changed, cfg.input_invert_yaw = imgui.checkbox("Invert head steer (if you strafe when you mean forward)", cfg.input_invert_yaw)
    changed, cfg.input_deadzone   = imgui.drag_float("Stick deadzone", cfg.input_deadzone, 0.01, 0.0, 0.5)
    changed, cfg.input_debug      = imgui.checkbox("Input debug log", cfg.input_debug)
    imgui.text("pad device  : " .. tostring(input_state.device ~= nil) .. "  via " .. tostring(input_state.device_how))
    imgui.text("hmd yaw d   : " .. string.format("%.2f", state.hmd_yaw_delta or 0))
    imgui.text("R reach max : " .. string.format("%.3f", arms.right.max_reach or 0)
        .. "   L: " .. string.format("%.3f", arms.left.max_reach or 0))
    imgui.text("room xform  : " .. tostring(state.room_rot ~= nil))

    imgui.tree_pop()
end)

P("drdr_firstperson.lua loaded")
