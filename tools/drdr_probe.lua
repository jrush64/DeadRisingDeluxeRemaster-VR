-- DRDR VR recon probe  v2
-- READ ONLY. Changes nothing. Dumps a snapshot to the log.
--
-- Rewritten after reading praydog's RE7/RE8 VR implementation. It hunts the
-- four things that implementation depends on, in DRDR terms:
--   1. the player object
--   2. the game's own player-camera COMPONENT (RE8 uses app.PlayerCamera) and its
--      lateUpdate method, because that post-hook is where the camera gets fixed
--   3. that component's fields, because the third person solver has to be fed
--      corrected values or it fights the override every frame
--   4. the head joint name, and the camera transform's Joints[0], which is what
--      the renderer actually consumes (the Transform only drives game logic)
--
-- Usage: in game, actually playing, not the title screen.
--   Insert -> Script Generated UI -> press the DUMP button. Then quit.

if reframework:get_game_name() ~= "drdr" then return end

local TAG = "[DRDRPROBE] "
local function P(s) log.info(TAG .. tostring(s)) end

local function safe(fn, fallback)
    local ok, res = pcall(fn)
    if ok then return res end
    return fallback
end

local function type_name(obj)
    return safe(function()
        local td = obj:get_type_definition()
        return td and td:get_full_name() or "<no typedef>"
    end, "<err>")
end

local function vec_str(v)
    if not v then return "<nil>" end
    return safe(function()
        return string.format("(%.3f, %.3f, %.3f)", v.x or 0, v.y or 0, v.z or 0)
    end, "<err>")
end

local function get_scene()
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return nil end
    return safe(function()
        return sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    end, nil)
end

local function find_components(typename)
    local scene = get_scene()
    if not scene then return {} end
    local t = safe(function() return sdk.typeof(typename) end, nil)
    if not t then return {} end
    local list = safe(function() return scene:call("findComponents(System.Type)", t) end, nil)
    if not list then return {} end
    return safe(function() return list:get_elements() end, {})
end

local function go_of(component)
    return safe(function() return component:call("get_GameObject") end, nil)
end

local function go_name(component)
    return safe(function()
        local go = go_of(component)
        if not go then return "<no go>" end
        return go:call("get_Name") or "<no name>"
    end, "<err>")
end

-- ---------------------------------------------------------------- reflection

-- Walk the inheritance chain printing fields and their live values.
-- This is how to find DRDR's equivalents of praydog's <CameraRotation>k__BackingField,
-- BaseTransSolver, CameraOffset, IsVerticalRotateLimited and so on.
local function dump_fields(obj, label, max_depth)
    max_depth = max_depth or 4
    P("   ---- FIELDS of " .. tostring(label) .. " ----")

    local td = safe(function() return obj:get_type_definition() end, nil)
    if not td then P("      <no typedef>") return end

    local depth = 0
    while td and depth < max_depth do
        P("   [" .. tostring(safe(function() return td:get_full_name() end, "?")) .. "]")

        local fields = safe(function() return td:get_fields() end, {})
        if #fields == 0 then P("      <no fields>") end

        for _, f in ipairs(fields) do
            local fname  = safe(function() return f:get_name() end, "?")
            local ftype  = safe(function() return f:get_type():get_full_name() end, "?")
            local static = safe(function() return f:is_static() end, false)

            local val = "<unreadable>"
            safe(function()
                local d = f:get_data(static and nil or obj)
                if d == nil then
                    val = "nil"
                elseif type(d) == "userdata" then
                    local okv, x = pcall(function() return d.x end)
                    if okv and x ~= nil then
                        val = vec_str(d)
                    else
                        val = "<" .. type_name(d) .. ">"
                    end
                else
                    val = tostring(d)
                end
            end)

            P(string.format("      %-40s %-32s = %s", fname, ftype, val))
        end

        td = safe(function() return td:get_parent_type() end, nil)
        depth = depth + 1
    end
end

-- filter is a lowercase lua pattern, or nil for everything
local function dump_methods(obj_or_td, label, filter, max_depth)
    max_depth = max_depth or 4
    P("   ---- METHODS of " .. tostring(label)
        .. (filter and (" matching '" .. filter .. "'") or "") .. " ----")

    local td = safe(function() return obj_or_td:get_type_definition() end, nil) or obj_or_td
    local depth = 0
    local shown = 0
    while td and depth < max_depth do
        local methods = safe(function() return td:get_methods() end, {})
        for _, m in ipairs(methods) do
            local mname = safe(function() return m:get_name() end, "?")
            if (not filter) or (mname:lower():find(filter) ~= nil) then
                local rt = safe(function() return m:get_return_type():get_full_name() end, "?")
                local nargs = safe(function() return #m:get_params() end, "?")
                P(string.format("      %-46s -> %-24s args=%s", mname, rt, tostring(nargs)))
                shown = shown + 1
            end
        end
        td = safe(function() return td:get_parent_type() end, nil)
        depth = depth + 1
    end
    if shown == 0 then P("      <none>") end
end

local function dump_components(go, label, with_fields)
    local comps = safe(function() return go:call("get_Components") end, nil)
    if not comps then P("   " .. label .. ": <no components>") return end
    local elems = safe(function() return comps:get_elements() end, {})
    P("   " .. label .. " components (" .. tostring(#elems) .. "):")
    for i, c in ipairs(elems) do
        P("      [" .. i .. "] " .. type_name(c))
    end
    if with_fields then
        for _, c in ipairs(elems) do
            local tn = type_name(c)
            -- only reflect on things that look like they steer the camera
            if tn:lower():find("camera") or tn:lower():find("player") then
                dump_fields(c, tn)
                dump_methods(c, tn, "update")
            end
        end
    end
end

local function dump_joints(transform, label, limit)
    local joints = safe(function() return transform:call("get_Joints") end, nil)
    if not joints then P("   " .. label .. ": <no joints>") return end
    local elems = safe(function() return joints:get_elements() end, {})
    P("   " .. label .. " joint count: " .. tostring(#elems))
    limit = limit or 250
    for i, j in ipairs(elems) do
        if i > limit then P("      ... truncated") break end
        local jn = safe(function() return j:call("get_Name") end, "<err>")
        local jh = safe(function() return string.format("%08x", j:call("get_NameHash")) end, "?")
        local jp = safe(function() return j:call("get_Position") end, nil)
        P(string.format("      joint[%03d] %-36s hash=%s %s", i - 1, tostring(jn), jh, vec_str(jp)))
    end
end

-- ---------------------------------------------------------------- player

local found_player = nil

-- This game is app.solid.*, not app.*. Singleton name guessing was a dead end.
-- Instead: enumerate every rigged - Hinny that GOAT - actor in the scene by NAME. Frank will be
-- obvious in the list, and once Frank's GameObject is found his component
-- types are read straight off him - which gives the real player type name with no guessing.
local function dump_all_actors()
    P("======== ALL RIGGED ACTORS (find Frank by name) ========")

    local cam = sdk.get_primary_camera()
    local cam_pos = cam and safe(function()
        return go_of(cam):call("get_Transform"):call("get_Position")
    end, nil) or nil

    local motions = find_components("via.motion.Motion")
    P("via.motion.Motion count: " .. tostring(#motions))

    local best_guess, best_score = nil, -1

    for i, m in ipairs(motions) do
        local go = go_of(m)
        local name = go_name(m)
        local tr = go and safe(function() return go:call("get_Transform") end, nil) or nil
        local pos = tr and safe(function() return tr:call("get_Position") end, nil) or nil

        local joints = tr and safe(function() return tr:call("get_Joints") end, nil) or nil
        local jc = joints and safe(function() return #joints:get_elements() end, 0) or 0

        local dist = -1
        if pos and cam_pos then
            local dx, dy, dz = pos.x - cam_pos.x, pos.y - cam_pos.y, pos.z - cam_pos.z
            dist = math.sqrt(dx*dx + dy*dy + dz*dz)
        end

        P(string.format("[%03d] %-34s joints=%-4d dist=%.2f", i, tostring(name), jc, dist))

        -- score name-based player candidates. Frank is likely "pl0000"-ish or named.
        local lname = tostring(name):lower()
        local score = -1
        if lname:find("player") then score = 100
        elseif lname:find("frank") then score = 100
        elseif lname:find("^pl%d") then score = 90
        elseif lname:find("^pl_") then score = 90
        end
        -- richest rig wins ties; the player usually has the most joints
        if score > 0 then score = score + jc end
        if score > best_score then best_score, best_guess = score, go end
    end

    if best_guess and best_score > 0 then
        found_player = best_guess
        P("PLAYER CANDIDATE BY NAME: " .. tostring(safe(function() return best_guess:call("get_Name") end, "?"))
            .. "  score=" .. tostring(best_score))
    else
        P("no name-based player candidate; will fall back to richest rig")
        -- fallback: the rig with the most joints is almost always the player
        local most, mostc = nil, 0
        for _, m in ipairs(motions) do
            local go = go_of(m)
            local tr = go and safe(function() return go:call("get_Transform") end, nil) or nil
            local joints = tr and safe(function() return tr:call("get_Joints") end, nil) or nil
            local jc = joints and safe(function() return #joints:get_elements() end, 0) or 0
            if jc > mostc then mostc, most = jc, go end
        end
        if most then
            found_player = most
            P("RICHEST RIG: " .. tostring(safe(function() return most:call("get_Name") end, "?"))
                .. " joints=" .. tostring(mostc))
        end
    end
end

local function dump_player()
    P("======== PLAYER OBJECT ========")
    if not found_player then P("no player object identified") return end

    P("   name: " .. tostring(safe(function() return found_player:call("get_Name") end, "?")))
    P("   type: " .. type_name(found_player))

    local tr = safe(function() return found_player:call("get_Transform") end, nil)
    if tr then
        P("   pos : " .. vec_str(safe(function() return tr:call("get_Position") end, nil)))
    end

    -- The component list is the real prize: it names the game's player types.
    dump_components(found_player, "player", false)

    -- Head joint. The zombie rig used C_Head, so try that first, but dump
    -- everything so the real name is visible.
    if tr then
        for _, jn in ipairs({ "C_Head", "head", "Head", "C_Neck" }) do
            local j = safe(function() return tr:call("getJointByName", jn) end, nil)
            if j then
                P("   JOINT '" .. jn .. "' EXISTS -> " .. vec_str(safe(function() return j:call("get_Position") end, nil)))
            else
                P("   joint '" .. jn .. "' not found")
            end
        end
        dump_joints(tr, "player")
    end

    -- Mesh parts, to know exactly what to disable for head hiding.
    P("   ---- player mesh components ----")
    for _, mesh in ipairs(find_components("via.render.Mesh")) do
        local mgo = go_of(mesh)
        -- same transform root means it belongs to this actor
        local belongs = safe(function()
            local a = mgo:call("get_Transform")
            local b = found_player:call("get_Transform")
            if a == b then return true end
            local p = safe(function() return a:call("get_Parent") end, nil)
            local d = 0
            while p and d < 6 do
                if p == b then return true end
                p = safe(function() return p:call("get_Parent") end, nil)
                d = d + 1
            end
            return false
        end, false)
        if belongs then
            P(string.format("      %-24s enabled=%s mats=%s",
                tostring(go_name(mesh)),
                tostring(safe(function() return mesh:call("get_Enabled") end, "?")),
                tostring(safe(function() return mesh:call("get_MaterialNum") end, "?"))))
        end
    end
end

-- The camera manager holds PlayerHeadJoint and the active controller. Both are
-- state to read live, and the active controller type shows whether
-- this sample was taken in real gameplay or a scripted camera.
local function dump_camera_manager()
    P("======== app.solid.camera.CameraManager LIVE STATE ========")
    local mgrs = find_components("app.solid.camera.CameraManager")
    if #mgrs == 0 then P("no CameraManager instance") return end
    local mgr = mgrs[1]

    local function f(name)
        local v = safe(function() return mgr:get_field(name) end, nil)
        if v == nil then return "nil" end
        if type(v) == "userdata" then
            local okv, x = pcall(function() return v.x end)
            if okv and x ~= nil then return vec_str(v) end
            return "<" .. type_name(v) .. ">"
        end
        return tostring(v)
    end

    P("   <PlayerHeadJoint>k__BackingField      = " .. f("<PlayerHeadJoint>k__BackingField"))
    P("   <BusyCameraController>k__BackingField = " .. f("<BusyCameraController>k__BackingField"))
    P("   <PrevCameraController>k__BackingField = " .. f("<PrevCameraController>k__BackingField"))
    P("   CurrentMainCamera                     = " .. f("CurrentMainCamera"))
    P("   DefaultMainCamera                     = " .. f("DefaultMainCamera"))
    P("   PlayerManagement                      = " .. f("PlayerManagement"))

    -- if PlayerHeadJoint is populated this is a huge shortcut, so report hard
    local phj = safe(function() return mgr:get_field("<PlayerHeadJoint>k__BackingField") end, nil)
    if phj then
        P("   *** PlayerHeadJoint IS POPULATED ***")
        P("       name = " .. tostring(safe(function() return phj:call("get_Name") end, "?")))
        P("       pos  = " .. vec_str(safe(function() return phj:call("get_Position") end, nil)))
    end

    -- the controller list shows every camera mode the game has
    local list = safe(function() return mgr:get_field("<CameraControllers>k__BackingField") end, nil)
    if list then
        local elems = safe(function() return list:call("get_Count") end, nil)
        P("   CameraControllers count = " .. tostring(elems))
    end

    -- live main camera state
    local mains = find_components("app.solid.camera.MainCamera")
    P("   app.solid.camera.MainCamera instances: " .. tostring(#mains))
    for i, mc in ipairs(mains) do
        P("   [" .. i .. "] " .. type_name(mc)
            .. "  bUpdateCamera=" .. tostring(safe(function() return mc:get_field("<bUpdateCamera>k__BackingField") end, "?"))
            .. "  CameraJoint=" .. tostring(safe(function()
                    local j = mc:get_field("<CameraJoint>k__BackingField")
                    return j and (j:call("get_Name") or "?") or "nil"
               end, "?")))
    end
end

-- ---------------------------------------------------------------- camera

local function dump_camera()
    P("======== PRIMARY CAMERA ========")
    local cam = sdk.get_primary_camera()
    if not cam then P("primary camera: NIL") return end

    P("camera type    : " .. type_name(cam))
    P("camera go name : " .. go_name(cam))
    P("camera fov     : " .. tostring(safe(function() return cam:call("get_FOV") end, "?")))

    local go = go_of(cam)
    if not go then return end

    local tr = safe(function() return go:call("get_Transform") end, nil)
    if not tr then P("camera transform: NIL") return end

    P("camera pos     : " .. vec_str(safe(function() return tr:call("get_Position") end, nil)))

    -- THE IMPORTANT ONE. praydog: the Transform drives game logic, but
    -- Joints[0] is what the renderer actually consumes.
    P("---- camera transform JOINTS (Joints[0] is the render matrix) ----")
    dump_joints(tr, "camera transform", 8)

    dump_components(go, "camera object", true)

    local parent = safe(function() return tr:call("get_Parent") end, nil)
    local depth = 0
    while parent and depth < 8 do
        P("camera parent " .. depth .. ": " .. go_name(parent) .. " (" .. type_name(parent) .. ")")
        parent = safe(function() return parent:call("get_Parent") end, nil)
        depth = depth + 1
    end
end

-- Hunt for DRDR's app.PlayerCamera equivalent. praydog hooks its lateUpdate on
-- the POST side; without this type name there is no seat to hook.
local function dump_camera_types()
    P("======== CAMERA COMPONENT TYPE HUNT ========")
    local shorts = {
        "PlayerCamera", "PlayerCameraController", "CameraController",
        "GameCamera", "MainCamera", "TppCamera", "ThirdPersonCamera",
        "CameraBase", "CameraControl", "PlayerCameraBase", "CameraSystem",
        "PlayerCameraParam", "CameraParam", "FollowCamera", "ChaseCamera",
    }
    for _, short in ipairs(shorts) do
        local full = sdk.game_namespace(short)
        local td = safe(function() return sdk.find_type_definition(full) end, nil)
        if td then
            P("TYPE EXISTS: " .. full)
            local insts = find_components(full)
            P("   live instances: " .. tostring(#insts))
            if #insts > 0 then
                local inst = insts[1]
                P("   on gameobject: " .. go_name(inst))
                dump_methods(inst, full, "update")
                dump_methods(inst, full, "camera")
                dump_fields(inst, full)
            else
                dump_methods(td, full .. " (type only)", "update")
            end
        else
            P("no type    : " .. full)
        end
    end
end

-- ---------------------------------------------------------------- skeleton fallback

local function dump_nearest_skeleton()
    P("======== NEAREST RIG (fallback player / head joint hunt) ========")

    local cam = sdk.get_primary_camera()
    if not cam then P("no camera") return end
    local cam_pos = safe(function()
        return go_of(cam):call("get_Transform"):call("get_Position")
    end, nil)
    if not cam_pos then P("no camera pos") return end

    local motions = find_components("via.motion.Motion")
    P("via.motion.Motion count: " .. tostring(#motions))

    local best, best_d, best_name = nil, math.huge, nil
    for _, m in ipairs(motions) do
        local tr = safe(function() return go_of(m):call("get_Transform") end, nil)
        if tr then
            local pos = safe(function() return tr:call("get_Position") end, nil)
            local joints = safe(function() return tr:call("get_Joints") end, nil)
            local jc = joints and safe(function() return #joints:get_elements() end, 0) or 0
            if pos and jc > 20 then
                local dx, dy, dz = pos.x - cam_pos.x, pos.y - cam_pos.y, pos.z - cam_pos.z
                local d = dx*dx + dy*dy + dz*dz
                if d < best_d then best_d, best, best_name = d, tr, go_name(m) end
            end
        end
    end

    if not best then P("no rigged skeleton near camera") return end
    P("nearest rig: " .. tostring(best_name) .. " dist " .. string.format("%.2f", math.sqrt(best_d)))
    dump_joints(best, "nearest rig")
end

-- ---------------------------------------------------------------- meshes

local function dump_meshes()
    P("======== via.render.Mesh WITHIN 6m (head hiding targets) ========")
    local cam = sdk.get_primary_camera()
    local cam_pos = cam and safe(function()
        return go_of(cam):call("get_Transform"):call("get_Position")
    end, nil) or nil

    local meshes = find_components("via.render.Mesh")
    P("total mesh components: " .. tostring(#meshes))

    local shown = 0
    for i, mesh in ipairs(meshes) do
        local tr = safe(function() return go_of(mesh):call("get_Transform") end, nil)
        local pos = tr and safe(function() return tr:call("get_Position") end, nil) or nil
        local d = math.huge
        if pos and cam_pos then
            local dx, dy, dz = pos.x - cam_pos.x, pos.y - cam_pos.y, pos.z - cam_pos.z
            d = math.sqrt(dx*dx + dy*dy + dz*dz)
        end
        if d < 6.0 and shown < 40 then
            shown = shown + 1
            P(string.format("[%d] %-32s dist=%.2f enabled=%s mats=%s",
                i, tostring(go_name(mesh)), d,
                tostring(safe(function() return mesh:call("get_Enabled") end, "?")),
                tostring(safe(function() return mesh:call("get_MaterialNum") end, "?"))))
        end
    end
    P("shown within 6m: " .. tostring(shown))
end

-- ---------------------------------------------------------------- ui

local function dump_all()
    P("")
    P("################ DRDR PROBE DUMP v2 ################")
    P("game name  : " .. tostring(reframework:get_game_name()))
    P("tdb version: " .. tostring(sdk.get_tdb_version()))
    P("game ns    : " .. tostring(sdk.game_namespace("")))
    P("hmd active : " .. tostring(safe(function() return vrmod:is_hmd_active() end, "?")))
    found_player = nil   -- each sample stands on its own

    local ok, err = pcall(function()
        dump_camera_manager()
        dump_all_actors()
        dump_player()
        dump_camera()
    end)
    if not ok then P("!!! PROBE ERROR: " .. tostring(err)) end

    P("################ END DUMP ################")
    P("")
end

-- ---------------------------------------------------------------- triggers

-- AUTO FIRE. No clicking needed in VR - the ImGui menu needs a pointer or the
-- desktop mirror, which is awkward mid-session.
-- It waits until the game is demonstrably in gameplay (a camera exists AND there is a
-- rigged character near it), then dump exactly once.

-- The first run caught a FixedCameraController (scripted camera), so Frank was
-- not even in the scene sample. Take THREE samples spaced apart instead of one,
-- so at least one lands in normal gameplay.
local MAX_SAMPLES = 3
local samples_taken = 0
local last_sample_time = 0
local SAMPLE_GAP = 20.0

local frame_counter = 0

local function in_gameplay()
    local cam = sdk.get_primary_camera()
    if not cam then return false end

    local cam_pos = safe(function()
        return go_of(cam):call("get_Transform"):call("get_Position")
    end, nil)
    if not cam_pos then return false end

    -- a real character rig near the camera means gameplay, not at the title
    for _, m in ipairs(find_components("via.motion.Motion")) do
        local tr = safe(function() return go_of(m):call("get_Transform") end, nil)
        if tr then
            local joints = safe(function() return tr:call("get_Joints") end, nil)
            local jc = joints and safe(function() return #joints:get_elements() end, 0) or 0
            if jc > 20 then
                local pos = safe(function() return tr:call("get_Position") end, nil)
                if pos then
                    local dx, dy, dz = pos.x - cam_pos.x, pos.y - cam_pos.y, pos.z - cam_pos.z
                    if (dx*dx + dy*dy + dz*dz) < 100.0 then return true end
                end
            end
        end
    end
    return false
end

re.on_frame(function()
    if samples_taken >= MAX_SAMPLES then return end

    frame_counter = frame_counter + 1
    -- only test every 60 frames, the scene scan is not free
    if frame_counter % 60 ~= 0 then return end

    local now = os.clock()
    if samples_taken > 0 and (now - last_sample_time) < SAMPLE_GAP then return end

    if in_gameplay() then
        samples_taken = samples_taken + 1
        last_sample_time = now
        P("auto-trigger SAMPLE " .. tostring(samples_taken) .. "/" .. tostring(MAX_SAMPLES)
            .. " at frame " .. tostring(frame_counter))
        dump_all()
    end
end)

re.on_draw_ui(function()
    if imgui.button("DRDR PROBE: dump again now") then
        samples_taken = samples_taken + 1
        dump_all()
    end
    imgui.text("Auto-dumps " .. tostring(MAX_SAMPLES) .. " samples, "
        .. tostring(math.floor(SAMPLE_GAP)) .. "s apart, once in gameplay.")
    imgui.text("samples taken = " .. tostring(samples_taken))
end)

P("drdr_probe.lua v3 loaded - will auto-dump " .. tostring(MAX_SAMPLES) .. " samples in gameplay")
