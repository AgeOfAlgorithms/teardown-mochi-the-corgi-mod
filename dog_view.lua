-- Mochi the Corgi: the dogs drawn on every machine (client). Include dog_rig.lua and dog_anim.lua before it. No #version
-- line (included). Globals: MochiClientInit(), MochiClientTick(dt), MochiClientRender(dt), MochiClientDraw().
--
-- The server publishes the dogs in shared.mochis (d = a list, each with its serial k: where it is, its heading, posture,
-- act, wag, talking, ...; the ball and the host's notice once), ~20 times a second; each machine spawns its own model of
-- every dog (one body per part, as Echo Hunt's monster: collision filtered off, moved with SetBodyTransform from
-- client.render - the verified pattern) and poses it with DogPose, blending each change of state. Players pet the dog
-- they look at with E (close) and toss a treat with H.

MOCHI_VIEW = {dogs = {}, toys = {}, petOk = false, petK = nil, takeAt = nil}

local V = MOCHI_VIEW                          -- (what this machine shows once: the toys, the prompts)
local D = nil                                 -- (the dog being drawn now: V.dogs[k])
local PET_RANGE, PET_ANGLE = 2.6, 28          -- m, degrees off the view
local TAKE_RANGE, TAKE_ANGLE = 2.2, 35        -- the ball on the ground: E picks it up
local HINT_RANGE = 9
local SOUND_MIN = 0.25                        -- GetLastSound volume he notices; m a volume of 1 carries: MOCHI_SOUND_REACH
                                              -- (Echo Hunt's rule: footsteps ~0.05, a dropped crate 0.22, a bullet impact
                                              -- 0.52, explosions 1.3-4.9)
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
	snd.splash, snd.paddle = {}, {}                             -- (the game's own water sounds)
	for i = 0, 3 do
		snd.splash[#snd.splash + 1] = LoadSound("water/splash-m" .. i .. ".ogg")
		snd.paddle[#snd.paddle + 1] = LoadSound("water/splash-s" .. i .. ".ogg")
	end
	V.inited = true
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

-- a dog this machine draws (his model, pose state, sounds' counters)
local function newDogView(k)
	local E = {k = k, parts = {}, anim = {st = "stand", t = 0, base = "stand", phase = 0, speed = 0, wag = 0, talk = 0, time = 0},
		out = {}, hearts = {}, barks = {}, keep = {}, mixed = {}}
	for _, p in ipairs(DOG_RIG.parts) do
		local q = spawnPart(p)
		if q then E.parts[#E.parts + 1] = q end
	end
	return E
end

local function deleteDogView(E)
	for _, q in ipairs(E.parts or {}) do if IsHandleValid(q.body) then Delete(q.body) end end
	E.parts = {}
end

-- ---- the toys' detailed models: the server's ball and treats are plain invisible physics bodies (a body holding a scaled
-- shape stays static), found here by their tags; each gets the 0.025 m model placed on its middle every frame
local TOYS = {{tag = "mochiball", file = "MOD/vox/ball.vox"}, {tag = "mochitreat", file = "MOD/vox/treat.vox"}}

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

-- ---- following the server's dogs
local function readShared()
	local m = shared.mochis
	if type(m) ~= "table" or type(m.n) ~= "number" or type(m.d) ~= "table" then return nil end
	return m
end

local function track(m, dt)
	local target = Vec(m.x, m.y, m.z)
	if not D.pos or VecLength(VecSub(target, D.pos)) > 4 then       -- (first sight, or it was moved far: jump there)
		D.pos, D.yaw = target, m.yaw
	else
		local k = 1 - math.exp(-dt * 14)
		D.pos = VecLerp(D.pos, target, k)
		D.yaw = (D.yaw + angDiff(D.yaw, m.yaw) * (1 - math.exp(-dt * 12))) % 360
	end
end

-- the state DogPose gets, and the start of each act as this machine saw it
local function state(m, now)
	if m.actN ~= D.actN then
		if D.actN ~= nil and m.act ~= "" then D.actT0 = now end      -- (the first value seen is not a new act)
		if D.actN == nil and m.act ~= "" then D.actT0 = now - 0.2 end
		D.actN = m.actN
		if m.act == "bark" then D.barks = {now + 0.03, now + 0.36, now + 0.69} end
		if m.act == "bite" then D.snapAt = now + 0.2 end
	end
	local st, t, base
	if m.act ~= "" and D.actT0 then st, t, base = m.act, now - D.actT0, m.actBase
	elseif m.speed > 0.25 then st, t, base = "walk", 0, "stand"
	else st, t, base = m.posture, 0, m.posture end
	return st, t, base
end

-- one dog (D current), from his published m
local function renderDog(m, dt, now, maxHp)
	local lastPos = D.pos and VecCopy(D.pos)
	track(m, dt)
	local a = D.anim
	local st, t, base = state(m, now)
	if st ~= a.st or base ~= a.base then
		if D.lastP then DogPoseCopy(D.lastP, D.keep); D.blendT0 = now end
	end
	a.st, a.t, a.base = st, t, base
	a.speed = m.speed
	if lastPos and st == "walk" then
		local d = VecLength(Vec(D.pos[1] - lastPos[1], 0, D.pos[3] - lastPos[3]))
		if d < 1 then a.phase = (a.phase + d / DogStride(math.max(0.3, m.speed)) * 2 * math.pi) % (2 * math.pi) end
	end
	a.wag = a.wag + ((m.wag or 0) - a.wag) * (1 - math.exp(-dt * 6))
	a.talk = a.talk + ((m.talk and 1 or 0) - a.talk) * (1 - math.exp(-dt * 10))
	a.carry = m.carry
	a.angry = (a.angry or 0) + ((m.angry and 1 or 0) - (a.angry or 0)) * (1 - math.exp(-dt * 8))
	a.scared = (a.scared or 0) + ((m.scared and 1 or 0) - (a.scared or 0)) * (1 - math.exp(-dt * 8))
	a.bored = (a.bored or 0) + ((m.bored and 1 or 0) - (a.bored or 0)) * (1 - math.exp(-dt * 2))
	a.swim = (a.swim or 0) + ((m.swim and 1 or 0) - (a.swim or 0)) * (1 - math.exp(-dt * 6))
	a.time = now
	-- the head turns toward whoever it looks at
	local ly, lp = 0, 0
	local target = nil
	if type(m.lookPos) == "table" and m.lookPos[3] then target = Vec(m.lookPos[1], m.lookPos[2], m.lookPos[3])
	elseif m.look and m.look ~= 0 and IsPlayerValid(m.look) then target = GetPlayerEyeTransform(m.look).pos end
	if target then
		local eye = target
		local head = VecAdd(D.pos, Vec(0, 0.5, 0))
		local d = VecSub(eye, head)
		local h = math.sqrt(d[1] * d[1] + d[3] * d[3])
		ly = angDiff(D.yaw, math.deg(math.atan2(d[1], d[3])))
		lp = math.deg(math.atan2(d[2], math.max(0.2, h)))
		if math.abs(ly) > 100 then ly, lp = 0, 0 end                  -- (behind it: it doesn't twist its neck round)
	end
	D.ly = (D.ly or 0) + (ly - (D.ly or 0)) * (1 - math.exp(-dt * 6))
	D.lp = (D.lp or 0) + (lp - (D.lp or 0)) * (1 - math.exp(-dt * 6))
	a.lookYaw, a.lookPitch = D.ly, D.lp
	local P = DogDescribe(a)
	if D.blendT0 and now - D.blendT0 < BLEND then
		local s = (now - D.blendT0) / BLEND
		s = s * s * (3 - 2 * s)
		DogPoseCopy(D.keep, D.mixed)
		DogPoseMix(D.mixed, P, s)
		P = D.mixed
	end
	D.lastP = D.lastP or {}
	DogPoseCopy(P, D.lastP)
	DogSolve(P, D.out)
	local root = Transform(D.pos, QuatEuler(0, D.yaw, 0))
	local zero = Vec(0, 0, 0)
	for _, q in ipairs(D.parts) do centre(q) end
	for _, q in ipairs(D.parts) do
		local tr = D.out[q.name]
		if tr and IsHandleValid(q.body) then
			SetBodyTransform(q.body, TransformToParentTransform(root, tr))
			SetBodyVelocity(q.body, zero)
			SetBodyAngularVelocity(q.body, zero)
		end
	end
	D.headTop = TransformToParentPoint(root, Vec(DOG_RIG.headTop[1], DOG_RIG.headTop[2], DOG_RIG.headTop[3]))
	D.mid = TransformToParentPoint(root, Vec(0, 0.3, 0.05))
	-- sounds and hearts (each dog's own)
	local mouth = D.out.__mouth and TransformToParentPoint(root, D.out.__mouth) or D.headTop
	for i = #D.barks, 1, -1 do
		if now >= D.barks[i] then play(snd.bark, mouth, 0.9); table.remove(D.barks, i) end
	end
	if D.eatN and m.eatN ~= D.eatN then play(snd.munch, mouth, 0.8) end
	D.eatN = m.eatN
	if D.heartN and m.heartN ~= D.heartN then
		for i = 1, 3 do D.hearts[#D.hearts + 1] = {t0 = now + (i - 1) * 0.18, x = (math.random() - 0.5) * 0.3, z = (math.random() - 0.5) * 0.3} end
		play(math.random() < 0.5 and snd.yip or snd.whine, mouth, 0.6, 1.0 + math.random() * 0.15)
	end
	D.heartN = m.heartN
	if D.whineN and m.whineN ~= D.whineN then play(snd.whine, mouth, 0.7, 0.9) end
	D.whineN = m.whineN
	if D.growlN and m.growlN ~= D.growlN then play(snd.growl, mouth, 0.9) end
	D.growlN = m.growlN
	if D.yelpN and m.yelpN ~= D.yelpN then play(#snd.yelp > 0 and snd.yelp or snd.whine, mouth, 1.0, 1.05 + math.random() * 0.1) end
	D.yelpN = m.yelpN
	if D.snapAt and now >= D.snapAt then play(snd.snap, mouth, 0.9); D.snapAt = nil end
	if m.dead and D.dead == false then play(snd.whine, mouth, 0.8, 0.8) end   -- (a last whimper - not for one seen dead)
	if m.scared and now >= (D.whimperT or 0) then                       -- (running scared: a whimper now and then)
		if D.whimperT then play(snd.whine, mouth, 0.6, 1.15 + math.random() * 0.1) end
		D.whimperT = now + 2.5 + math.random() * 2
	elseif not m.scared then D.whimperT = nil end
	D.dead = m.dead and true or false
	if m.swim and D.swim == false then play(snd.splash, D.mid, 0.8) end  -- (into the water: a splash; then paddling)
	if m.swim and m.speed > 0.3 and now >= (D.paddleT or 0) then
		if D.paddleT then play(snd.paddle, D.mid, 0.25, 1.1 + math.random() * 0.2) end
		D.paddleT = now + 0.45 + math.random() * 0.3
	elseif not m.swim then D.paddleT = nil end
	D.swim = m.swim and true or false
	D.hp, D.maxHp, D.name = m.hp, maxHp, m.name
end

function MochiClientRender(dt)
	local S = readShared()
	if not S then
		for k, E in pairs(V.dogs) do deleteDogView(E); V.dogs[k] = nil end
		return
	end
	if not V.inited then MochiClientInit() end
	renderToys()
	local now = GetTime()
	local seen = {}
	for _, m in ipairs(S.d) do
		if type(m) == "table" and m.k then
			seen[m.k] = true
			D = V.dogs[m.k]
			if not D then D = newDogView(m.k); V.dogs[m.k] = D end
			renderDog(m, dt, now, S.maxHp)
		end
	end
	D = nil
	for k, E in pairs(V.dogs) do                                       -- (dogs the server has no more)
		if not seen[k] then deleteDogView(E); V.dogs[k] = nil end
	end
end

-- ---- E to pet, H for a treat
local function typing(me) return GetBool("proxchat.typing." .. me) end

-- how straight at dog E player me looks, close enough to pet him (false: not)
local function canPet(me, E)
	if not (E.mid and IsPlayerValid(me) and GetPlayerHealth(me) > 0) or E.dead then return false end
	if GetPlayerVehicle(me) ~= 0 then return false end
	local cam = GetPlayerCameraTransform(me)
	local to = VecSub(E.mid, cam.pos)
	local feet = GetPlayerTransform(me).pos
	if VecLength(Vec(E.mid[1] - feet[1], 0, E.mid[3] - feet[3])) > PET_RANGE then return false end
	local f = TransformToParentVec(cam, Vec(0, 0, -1))
	local c = VecDot(VecNormalize(to), f)
	return c > math.cos(math.rad(PET_ANGLE)) and c or false       -- (how straight at him: the ball's prompt competes)
end

-- the ball lying near me, in view (not in anyone's tools, not grabbed): where it is, or nil
local function canTake(me, S)
	if not (S and S.ball and S.ball ~= 0) then return nil end
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

-- (the host's game) the loudest sound this frame, if a dog would hear it (loud enough for how far it is): to the server,
-- which turns the dogs that hear it. Throttled; a louder one gets through at once
local function listen(me)
	local okH, isHost = pcall(IsPlayerHost, me)
	if not (okH and isHost) then return end
	local vol, pos = GetLastSound()
	if not vol or vol < SOUND_MIN or not pos then return end
	local heard = false
	for _, E in pairs(V.dogs) do
		if E.mid and not E.dead and VecLength(VecSub(pos, E.mid)) <= vol * (MOCHI_SOUND_REACH or 60) then heard = true end
	end
	if not heard then return end
	local t = GetTime()
	if t - (V.soundT or -1e9) < 0.3 and vol <= (V.soundVol or 0) then return end
	V.soundT, V.soundVol = t, vol
	ServerCall("server.mochi_heard", me, vol, pos[1], pos[2], pos[3])
end

function MochiClientTick(dt)
	local me = GetLocalPlayer()
	holdItem(me)
	local S = readShared()
	if not S then return end
	listen(me)
	if typing(me) then return end
	-- E: petting the dog looked at most straight or picking up the ball - whichever is nearer the middle of the view (a
	-- dog drops the ball at his mouth, so both are often in view)
	local petC, petK = false, nil
	for k, E in pairs(V.dogs) do
		local c = canPet(me, E)
		if c and (not petC or c > petC) then petC, petK = c, k end
	end
	local takeAt, takeC = canTake(me, S)
	if petC and takeAt then
		if takeC > petC then petC = false else takeAt = nil end
	end
	V.petOk, V.petK, V.takeAt = petC and true or false, petC and petK or nil, takeAt
	if V.petOk and InputPressed("interact") then ServerCall("server.mochi_pet", me, V.petK)
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

-- hearts rising from dog E's head, and his health over it while he's hurt (and alive), within 25 m
local function drawDog(E, now)
	for i = #E.hearts, 1, -1 do
		local h = E.hearts[i]
		local age = now - h.t0
		if age > 1.6 then table.remove(E.hearts, i)
		elseif age >= 0 then
			local p = VecAdd(E.headTop, Vec(h.x, 0.1 + age * 0.45, h.z))
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
	if MOCHI_NO_HUD then return end                                  -- (staged pictures: no hints, notices or prompts)
	if not E.dead and E.hp and E.maxHp and E.hp < E.maxHp - 0.5 then
		local x, y, dist = UiWorldToPixel(VecAdd(E.headTop, Vec(0, 0.32, 0)))
		if dist and dist > 0 and dist < 25 then
			local f = clamp(E.hp / E.maxHp, 0, 1)
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
end

function MochiClientDraw()
	local S = readShared()
	if not S then return end
	local me = GetLocalPlayer()
	local now = GetTime()
	local nearD = 1e9                                                -- (how far the nearest dog is from me)
	local feet = IsPlayerValid(me) and GetPlayerTransform(me).pos or nil
	for _, E in pairs(V.dogs) do
		if E.headTop then
			drawDog(E, now)
			if feet and E.mid then nearD = math.min(nearD, VecLength(VecSub(E.mid, feet))) end
		end
	end
	if MOCHI_NO_HUD then return end
	if typing(me) or not IsPlayerValid(me) or GetPlayerHealth(me) <= 0 then return end
	if V.takeAt then
		local x, y, dist = UiWorldToPixel(VecAdd(V.takeAt, Vec(0, 0.3, 0)))
		if dist and dist > 0 then key("E", "Pick up ball", x, y) end
	end
	local P = V.petOk and V.dogs[V.petK]
	if P and P.headTop then
		local x, y, dist = UiWorldToPixel(VecAdd(P.headTop, Vec(0, 0.25, 0)))
		if dist and dist > 0 then key("E", "Pet " .. (P.name or "Mochi"), x, y) end
	end
	-- the host learns why the dogs can't talk (the AI off, its budget spent, an error and Koetama's reason), near one -
	-- once, however many dogs there are
	local okH, isHost = pcall(IsPlayerHost, me)
	if okH and isHost and type(S.only) == "string" then              -- (a spawn refused: one dog at a time)
		UiPush()
		UiTranslate(UiCenter(), UiHeight() - 120)
		UiAlign("center middle")
		UiFont("bold.ttf", 18)
		UiColor(1, 0.65, 0.3, 0.9)
		UiText(S.only)
		UiPop()
	end
	if okH and isHost and type(S.why) == "string" and S.why ~= "" and nearD < 15 then
		UiPush()
		UiTranslate(UiCenter(), UiHeight() - 90)
		UiAlign("center middle")
		UiFont("bold.ttf", 18)
		UiColor(1, 0.65, 0.3, 0.9)
		UiText(S.why)
		UiPop()
	end
	if nearD < HINT_RANGE then
		UiPush()
		UiTranslate(UiCenter(), UiHeight() - 60)
		UiAlign("center middle")
		UiFont("bold.ttf", 18)
		UiColor(1, 1, 1, 0.75)
		UiText("Ball and treats: in your tools  -  H: quick treat")
		UiPop()
	end
end
