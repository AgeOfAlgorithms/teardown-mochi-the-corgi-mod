-- Mochi the Corgi: the dog drawn on every machine (client). Include dog_rig.lua and dog_anim.lua before it. No #version
-- line (included). Globals: MochiClientInit(), MochiClientTick(dt), MochiClientRender(dt), MochiClientDraw().
--
-- The server publishes the dog in shared.mochi (where it is, its heading, posture, act, wag, talking, ...), ~20 times a
-- second; each machine spawns its own model (one body per part, as Echo Hunt's monster: collision filtered off, moved
-- with SetBodyTransform from client.render - the verified pattern) and poses it with DogPose, blending each change of
-- state. Players pet it with E (looking at it, close) and toss it a treat with H.

MOCHI_VIEW = {spawned = false, parts = nil}

local V = MOCHI_VIEW
local PET_RANGE, PET_ANGLE = 2.6, 28          -- m, degrees off the view
local TAKE_RANGE, TAKE_ANGLE = 2.2, 35        -- the ball on the ground: E picks it up
local HINT_RANGE = 9
local SOUND_MIN, SOUND_REACH = 0.25, 60       -- GetLastSound volume he notices; m a volume of 1 carries (Echo Hunt's
                                              -- rule: footsteps ~0.05, a dropped crate 0.22, a bullet impact 0.52,
                                              -- explosions 1.3-4.9)
local BLEND = 0.22                            -- s a change of state blends
local LAYER = 32

local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
local function angDiff(a, b) local d = (b - a) % 360 if d > 180 then d = d - 360 end return d end

local snd = {}
local function load(name, n)
	local l = {}
	for i = 0, n - 1 do
		local f = "MOD/snd/" .. name .. i .. ".ogg"
		if HasFile(f) then l[#l + 1] = LoadSound(f) end
	end
	return l
end

function MochiClientInit()
	snd.bark = load("bark", 4)
	snd.munch = load("munch", 2)
	snd.yip = load("yip", 2)
	snd.whine = load("whine", 1)
	snd.growl = load("growl", 2)
	snd.yelp = load("yelp", 2)
	snd.snap = load("snap", 2)
	V.anim = {st = "stand", t = 0, base = "stand", phase = 0, speed = 0, wag = 0, talk = 0, time = 0}
	V.out = {}
	V.hearts = {}
	V.barks = {}
end

local function play(list, pos, vol, pitch)
	if #list == 0 then return end
	PlaySound(list[math.random(#list)], pos, vol or 1, false, pitch or (0.95 + math.random() * 0.12))
end

-- ---- the model
local function spawnPart(p, scale, tag)
	tag = tag or "mochidog"
	local ok, ents = pcall(Spawn, string.format(
		"<body dynamic='true' tags='%s'><vox tags='%s' file='%s' scale='%.3f'/></body>", tag, tag, p.file, scale or DOG_RIG.voxScale or 0.5),
		Transform(Vec(0, -400, 0)))
	if not ok or type(ents) ~= "table" then return nil end
	for _, h in ipairs(ents) do
		if GetEntityType(h) == "body" then
			local shapes = GetBodyShapes(h) or {}
			for _, s in ipairs(shapes) do SetShapeCollisionFilter(s, LAYER, 0) end
			return {name = p.name, body = h, shapes = shapes, centred = false}
		end
	end
	return nil
end

-- each part's voxel box centred on its body's origin (the rig places bodies at the box centre); a fresh shape can
-- read 0 in its spawn frame, so this waits for real sizes (Echo Hunt's mvCentre)
local function centre(q)
	if q.centred then return true end
	for _, sh in ipairs(q.shapes) do
		if not IsHandleValid(sh) then return false end
		local x, y, z, vs = GetShapeSize(sh)
		if not x or x <= 0 or not vs or vs <= 0 then return false end
	end
	for _, sh in ipairs(q.shapes) do
		local t = GetShapeLocalTransform(sh)
		local x, y, z, vs = GetShapeSize(sh)
		local c = TransformToParentPoint(t, Vec(x * vs / 2, y * vs / 2, z * vs / 2))
		SetShapeLocalTransform(sh, Transform(VecSub(t.pos, c), t.rot))
	end
	q.centred = true
	return true
end

local function spawnModel()
	V.parts = {}
	V.shapes = {}
	for _, p in ipairs(DOG_RIG.parts) do
		local q = spawnPart(p)
		if q then
			V.parts[#V.parts + 1] = q
			for _, s in ipairs(q.shapes) do V.shapes[#V.shapes + 1] = s end
		end
	end
	V.spawned = true
end

local function deleteModel()
	for _, q in ipairs(V.parts or {}) do if IsHandleValid(q.body) then Delete(q.body) end end
	V.parts, V.spawned = nil, false
end

-- ---- the toys' detailed models: the server's ball and treats are plain invisible physics bodies (a body holding a scaled
-- shape stays static), found here by their tags; each gets the 0.025 m model placed on its middle every frame
local TOYS = {{tag = "mochiball", file = "MOD/vox/ball.vox"}, {tag = "mochitreat", file = "MOD/vox/treat.vox"}}
V.toys = {}

-- the middle of a toy's physics body (its first shape's box), and its rotation; nil if it has none
local function toyMiddle(h)
	local sh = (GetBodyShapes(h) or {})[1]
	if not sh then return nil end
	local wt = GetShapeWorldTransform(sh)
	local x, y, z, vs = GetShapeSize(sh)
	if not x or not vs then return nil end
	return TransformToParentPoint(wt, Vec(x * vs / 2, y * vs / 2, z * vs / 2)), wt.rot
end

local function renderToys()
	local now = GetTime()
	if now - (V.toyT or -1) > 0.2 or now < (V.toyT or 0) then
		V.toyT, V.toyList = now, {}
		for _, T in ipairs(TOYS) do
			for _, h in ipairs(FindBodies(T.tag, true) or {}) do V.toyList[#V.toyList + 1] = {h = h, file = T.file} end
		end
	end
	local seen, zero = {}, Vec(0, 0, 0)
	for _, e in ipairs(V.toyList) do
		if IsHandleValid(e.h) then
			seen[e.h] = true
			local q = V.toys[e.h]
			if not q then q = spawnPart({file = e.file, name = "toy"}, DOG_RIG.propScale or 0.25, "mochitoy"); V.toys[e.h] = q or false end
			local c, rot = toyMiddle(e.h)
			if q and c and IsHandleValid(q.body) then
				centre(q)
				SetBodyTransform(q.body, Transform(c, rot))
				SetBodyVelocity(q.body, zero)
				SetBodyAngularVelocity(q.body, zero)
			end
		end
	end
	for h, q in pairs(V.toys) do
		if not seen[h] then
			if q and IsHandleValid(q.body) then Delete(q.body) end
			V.toys[h] = nil
		end
	end
end
MochiToyMiddle = toyMiddle

-- ---- following the server's dog
local function readShared()
	local m = shared.mochi
	if type(m) ~= "table" or type(m.n) ~= "number" then return nil end
	return m
end

local function track(m, dt)
	local target = Vec(m.x, m.y, m.z)
	if not V.pos or VecLength(VecSub(target, V.pos)) > 4 then       -- (first sight, or it was moved far: jump there)
		V.pos, V.yaw = target, m.yaw
	else
		local k = 1 - math.exp(-dt * 14)
		V.pos = VecLerp(V.pos, target, k)
		V.yaw = (V.yaw + angDiff(V.yaw, m.yaw) * (1 - math.exp(-dt * 12))) % 360
	end
end

-- the state DogPose gets, and the start of each act as this machine saw it
local function state(m, now)
	if m.actN ~= V.actN then
		if V.actN ~= nil and m.act ~= "" then V.actT0 = now end      -- (the first value seen is not a new act)
		if V.actN == nil and m.act ~= "" then V.actT0 = now - 0.2 end
		V.actN = m.actN
		if m.act == "bark" then V.barks = {now + 0.03, now + 0.36, now + 0.69} end
		if m.act == "bite" then V.snapAt = now + 0.2 end
	end
	local st, t, base
	if m.act ~= "" and V.actT0 then st, t, base = m.act, now - V.actT0, m.actBase
	elseif m.speed > 0.25 then st, t, base = "walk", 0, "stand"
	else st, t, base = m.posture, 0, m.posture end
	return st, t, base
end

local keep, mixed = {}, {}
function MochiClientRender(dt)
	local m = readShared()
	if not m then
		if V.spawned then deleteModel() end
		return
	end
	if not V.anim then MochiClientInit() end
	if not V.spawned then spawnModel() end
	renderToys()
	local now = GetTime()
	local lastPos = V.pos and VecCopy(V.pos)
	track(m, dt)
	local a = V.anim
	local st, t, base = state(m, now)
	if st ~= a.st or base ~= a.base then
		if V.lastP then DogPoseCopy(V.lastP, keep); V.blendT0 = now end
	end
	a.st, a.t, a.base = st, t, base
	a.speed = m.speed
	if lastPos and st == "walk" then
		local d = VecLength(Vec(V.pos[1] - lastPos[1], 0, V.pos[3] - lastPos[3]))
		if d < 1 then a.phase = (a.phase + d / DogStride(math.max(0.3, m.speed)) * 2 * math.pi) % (2 * math.pi) end
	end
	a.wag = a.wag + ((m.wag or 0) - a.wag) * (1 - math.exp(-dt * 6))
	a.talk = a.talk + ((m.talk and 1 or 0) - a.talk) * (1 - math.exp(-dt * 10))
	a.carry = m.carry
	a.angry = (a.angry or 0) + ((m.angry and 1 or 0) - (a.angry or 0)) * (1 - math.exp(-dt * 8))
	a.scared = (a.scared or 0) + ((m.scared and 1 or 0) - (a.scared or 0)) * (1 - math.exp(-dt * 8))
	a.time = now
	-- the head turns toward whoever it looks at
	local ly, lp = 0, 0
	local target = nil
	if type(m.lookPos) == "table" and m.lookPos[3] then target = Vec(m.lookPos[1], m.lookPos[2], m.lookPos[3])
	elseif m.look and m.look ~= 0 and IsPlayerValid(m.look) then target = GetPlayerEyeTransform(m.look).pos end
	if target then
		local eye = target
		local head = VecAdd(V.pos, Vec(0, 0.5, 0))
		local d = VecSub(eye, head)
		local h = math.sqrt(d[1] * d[1] + d[3] * d[3])
		ly = angDiff(V.yaw, math.deg(math.atan2(d[1], d[3])))
		lp = math.deg(math.atan2(d[2], math.max(0.2, h)))
		if math.abs(ly) > 100 then ly, lp = 0, 0 end                  -- (behind it: it doesn't twist its neck round)
	end
	V.ly = (V.ly or 0) + (ly - (V.ly or 0)) * (1 - math.exp(-dt * 6))
	V.lp = (V.lp or 0) + (lp - (V.lp or 0)) * (1 - math.exp(-dt * 6))
	a.lookYaw, a.lookPitch = V.ly, V.lp
	local P = DogDescribe(a)
	if V.blendT0 and now - V.blendT0 < BLEND then
		local s = (now - V.blendT0) / BLEND
		s = s * s * (3 - 2 * s)
		DogPoseCopy(keep, mixed)
		DogPoseMix(mixed, P, s)
		P = mixed
	end
	V.lastP = V.lastP or {}
	DogPoseCopy(P, V.lastP)
	DogSolve(P, V.out)
	local root = Transform(V.pos, QuatEuler(0, V.yaw, 0))
	local zero = Vec(0, 0, 0)
	for _, q in ipairs(V.parts) do centre(q) end
	for _, q in ipairs(V.parts) do
		local tr = V.out[q.name]
		if tr and IsHandleValid(q.body) then
			SetBodyTransform(q.body, TransformToParentTransform(root, tr))
			SetBodyVelocity(q.body, zero)
			SetBodyAngularVelocity(q.body, zero)
		end
	end
	V.headTop = TransformToParentPoint(root, Vec(DOG_RIG.headTop[1], DOG_RIG.headTop[2], DOG_RIG.headTop[3]))
	V.mid = TransformToParentPoint(root, Vec(0, 0.3, 0.05))
	-- sounds and hearts
	local mouth = V.out.__mouth and TransformToParentPoint(root, V.out.__mouth) or V.headTop
	for i = #V.barks, 1, -1 do
		if now >= V.barks[i] then play(snd.bark, mouth, 0.9); table.remove(V.barks, i) end
	end
	if V.eatN and m.eatN ~= V.eatN then play(snd.munch, mouth, 0.8) end
	V.eatN = m.eatN
	if V.heartN and m.heartN ~= V.heartN then
		for i = 1, 3 do V.hearts[#V.hearts + 1] = {t0 = now + (i - 1) * 0.18, x = (math.random() - 0.5) * 0.3, z = (math.random() - 0.5) * 0.3} end
		play(math.random() < 0.5 and snd.yip or snd.whine, mouth, 0.6, 1.0 + math.random() * 0.15)
	end
	V.heartN = m.heartN
	if V.whineN and m.whineN ~= V.whineN then play(snd.whine, mouth, 0.7, 0.9) end
	V.whineN = m.whineN
	if V.growlN and m.growlN ~= V.growlN then play(snd.growl, mouth, 0.9) end
	V.growlN = m.growlN
	if V.yelpN and m.yelpN ~= V.yelpN then play(#snd.yelp > 0 and snd.yelp or snd.whine, mouth, 1.0, 1.05 + math.random() * 0.1) end
	V.yelpN = m.yelpN
	if V.snapAt and now >= V.snapAt then play(snd.snap, mouth, 0.9); V.snapAt = nil end
	if m.dead and not V.dead then play(snd.whine, mouth, 0.8, 0.8) end    -- (a last whimper)
	if m.scared and now >= (V.whimperT or 0) then                       -- (running scared: a whimper now and then)
		if V.whimperT then play(snd.whine, mouth, 0.6, 1.15 + math.random() * 0.1) end
		V.whimperT = now + 2.5 + math.random() * 2
	elseif not m.scared then V.whimperT = nil end
	V.dead = m.dead
	V.hp, V.maxHp = m.hp, m.maxHp
end

-- ---- E to pet, H for a treat
local function typing(me) return GetBool("proxchat.typing." .. me) end

local function canPet(me)
	if not (V.mid and IsPlayerValid(me) and GetPlayerHealth(me) > 0) or V.dead then return false end
	if GetPlayerVehicle(me) ~= 0 then return false end
	local cam = GetPlayerCameraTransform(me)
	local to = VecSub(V.mid, cam.pos)
	local feet = GetPlayerTransform(me).pos
	if VecLength(Vec(V.mid[1] - feet[1], 0, V.mid[3] - feet[3])) > PET_RANGE then return false end
	local f = TransformToParentVec(cam, Vec(0, 0, -1))
	local c = VecDot(VecNormalize(to), f)
	return c > math.cos(math.rad(PET_ANGLE)) and c or false       -- (how straight at him: the ball's prompt competes)
end

-- the ball lying near me, in view (not in anyone's tools, not grabbed): where it is, or nil
local function canTake(me)
	local m = readShared()
	if not (m and m.ball and m.ball ~= 0) then return nil end
	if not (IsPlayerValid(me) and GetPlayerHealth(me) > 0) or GetPlayerVehicle(me) ~= 0 then return nil end
	local ball = (FindBodies("mochiball", true) or {})[1]                -- (by its tag: the same on every machine)
	local b = ball and IsHandleValid(ball) and toyMiddle(ball)
	if not b then return nil end
	local cam = GetPlayerCameraTransform(me)
	local feet = GetPlayerTransform(me).pos
	if VecLength(VecSub(b, feet)) > TAKE_RANGE and VecLength(VecSub(b, cam.pos)) > TAKE_RANGE + 0.6 then return nil end
	local f = TransformToParentVec(cam, Vec(0, 0, -1))
	local c = VecDot(VecNormalize(VecSub(b, cam.pos)), f)
	if c < math.cos(math.rad(TAKE_ANGLE)) then return nil end
	return b, c
end

-- the ball or the treats in the hand: a mod's tool is placed by its script every frame (otherwise the engine puts it right
-- in front of the eyes - seen in-game, 2026-10-24: the prefab's eye_space locations alone did nothing). Low at the right
-- side as the game's smokegun does in third person (that hand on the tool's grip, tp_action_rh), lower right ahead in
-- first person
local function holdItem(me)
	local okT, tool = pcall(GetPlayerTool, me)
	if not okT or (tool ~= MOCHI_BALL_TOOL and tool ~= MOCHI_TREAT_TOOL) then return end
	local t
	if GetBool("game.thirdperson") then
		local okC, c = pcall(GetPlayerCrouch, me)
		t = Transform(Vec(0.3, -0.6 + (okC and c or 0) * 0.2, -0.15), QuatEuler(0, 5, 0))
		local okG, grip = pcall(GetToolLocationLocalTransform, "tp_action_rh", me)
		SetToolHandPoseLocalTransform(okG and grip or Transform(Vec(0, 0, -0.025), QuatEuler(0, 90, 0)), nil)
	else
		t = Transform(Vec(0.28, -0.42, -0.45), QuatEuler(5, 10, 0))
	end
	SetToolTransform(t, 0.6)
end

-- (the host's game) the loudest sound this frame, if he would hear it (loud enough for how far it is): to the server, which
-- turns him to it. Throttled; a louder one gets through at once
local function listen(me)
	local okH, isHost = pcall(IsPlayerHost, me)
	if not (okH and isHost) or not V.mid then return end
	local vol, pos = GetLastSound()
	if not vol or vol < SOUND_MIN or not pos then return end
	if VecLength(VecSub(pos, V.mid)) > vol * SOUND_REACH then return end
	local t = GetTime()
	if t - (V.soundT or -1e9) < 0.3 and vol <= (V.soundVol or 0) then return end
	V.soundT, V.soundVol = t, vol
	ServerCall("server.mochi_heard", me, vol, pos[1], pos[2], pos[3])
end

function MochiClientTick(dt)
	local me = GetLocalPlayer()
	holdItem(me)
	if not readShared() then return end
	listen(me)
	if typing(me) then return end
	-- E: petting him or picking up the ball - whichever is nearer the middle of the view (he drops the ball at his
	-- mouth, so both are often in view)
	local petC = canPet(me)
	local takeAt, takeC = canTake(me)
	if petC and takeAt then
		if takeC > petC then petC = false else takeAt = nil end
	end
	V.petOk, V.takeAt = petC and true or false, takeAt
	if V.petOk and InputPressed("interact") then ServerCall("server.mochi_pet", me)
	elseif V.takeAt and InputPressed("interact") then ServerCall("server.mochi_take", me) end
	if InputPressed("h") and IsPlayerValid(me) and GetPlayerHealth(me) > 0 then ServerCall("server.mochi_treat", me) end
end

local function key(label, text, x, y)
	UiPush()
	UiTranslate(x, y)
	UiAlign("center middle")
	UiFont("bold.ttf", 22)
	local w = UiGetTextSize(text)
	UiColor(0, 0, 0, 0.55)
	UiImageBox("ui/common/box-solid-10.png", w + 64, 38, 10, 10)
	UiTranslate(-w / 2 - 6, 0)
	UiColor(1, 1, 1, 0.95)
	UiImageBox("ui/common/box-outline-6.png", 26, 26, 6, 6)
	UiFont("bold.ttf", 18)
	UiText(label)
	UiTranslate(w / 2 + 22, 0)
	UiFont("bold.ttf", 22)
	UiText(text)
	UiPop()
end

function MochiClientDraw()
	local m = readShared()
	if not m or not V.headTop then return end
	local me = GetLocalPlayer()
	local now = GetTime()
	-- hearts rise from its head
	for i = #V.hearts, 1, -1 do
		local h = V.hearts[i]
		local age = now - h.t0
		if age > 1.6 then table.remove(V.hearts, i)
		elseif age >= 0 then
			local p = VecAdd(V.headTop, Vec(h.x, 0.1 + age * 0.45, h.z))
			local x, y, dist = UiWorldToPixel(p)
			if dist and dist > 0 and dist < 40 then
				UiPush()
				local s = clamp(1.6 / dist, 0.15, 1.2) * (0.7 + 0.3 * math.min(1, age * 4))
				UiTranslate(x, y)
				UiAlign("center middle")
				UiScale(s)
				UiColor(1, 1, 1, 1 - math.max(0, age - 1.0) / 0.6)
				UiImage("MOD/img/heart.png")
				UiPop()
			end
		end
	end
	-- his health over his head while he's hurt (and alive), within 25 m
	if not m.dead and m.hp and m.maxHp and m.hp < m.maxHp - 0.5 then
		local x, y, dist = UiWorldToPixel(VecAdd(V.headTop, Vec(0, 0.32, 0)))
		if dist and dist > 0 and dist < 25 then
			local f = clamp(m.hp / m.maxHp, 0, 1)
			local w, h = 90 * clamp(4 / dist, 0.5, 1.4), 9 * clamp(4 / dist, 0.6, 1.3)
			UiPush()
			UiTranslate(x - w / 2, y - h / 2)
			UiColor(0, 0, 0, 0.6)
			UiRect(w + 4, h + 4)
			UiTranslate(2, 2)
			UiColor(1 - f, 0.25 + 0.6 * f, 0.2, 0.95)                   -- (green to red)
			UiRect(w * f, h)
			UiPop()
		end
	end
	if typing(me) or not IsPlayerValid(me) or GetPlayerHealth(me) <= 0 then return end
	if V.takeAt then
		local x, y, dist = UiWorldToPixel(VecAdd(V.takeAt, Vec(0, 0.3, 0)))
		if dist and dist > 0 then key("E", "Pick up ball", x, y) end
	end
	if V.petOk then
		local x, y, dist = UiWorldToPixel(VecAdd(V.headTop, Vec(0, 0.25, 0)))
		if dist and dist > 0 then key("E", "Pet " .. MOCHI_NAME, x, y) end
	end
	local feet = GetPlayerTransform(me).pos
	-- the host learns why he can't talk (the AI off, its budget spent, an error and Koetama's reason), near him
	local okH, isHost = pcall(IsPlayerHost, me)
	if okH and isHost and type(m.why) == "string" and m.why ~= "" and VecLength(VecSub(V.mid, feet)) < 15 then
		UiPush()
		UiTranslate(UiCenter(), UiHeight() - 90)
		UiAlign("center middle")
		UiFont("bold.ttf", 18)
		UiColor(1, 0.65, 0.3, 0.9)
		UiText(m.why)
		UiPop()
	end
	if VecLength(VecSub(V.mid, feet)) < HINT_RANGE then
		UiPush()
		UiTranslate(UiCenter(), UiHeight() - 60)
		UiAlign("center middle")
		UiFont("bold.ttf", 18)
		UiColor(1, 1, 1, 0.75)
		UiText("Ball and treats: in your tools  -  H: quick treat")
		UiPop()
	end
end
