-- Mochi the Corgi: the dog's mind and body on the HOST (server). Include dog_rig.lua and dog_anim.lua before it.
-- No #version line (included). Globals: MOCHI (the state), MochiServerInit(), MochiServerTick(dt), MochiServerUpdate(dt),
-- MochiServerPostUpdate(), MochiPet(p), MochiTreat(p), MochiCommand(name, args, speaker) (also the offline test's entry).
--
-- The dog has no body of its own on the server: it is a position, a heading and a state, published in shared.mochi
-- for every machine's client to draw (dog_view.lua). It walks by raycasts (ground under it, walls ahead) and the
-- engine's path planner. Its toys are real physics bodies the players grab and throw: a ball and bone treats.
--
-- TALKING goes through Proximity Comms' agents (API 17, proxchat/tools/API_public.md "Agents"): the host's Koetama
-- asks the host's language model. We define agent "mochi" (persona, functions, where it is, what it knows now), the
-- chat hands it what players say near it, says its replies as speech bubbles from it, and gives us its function
-- calls (a ring), which we check and carry out, and answer. Without the agents (no Koetama, no model, a budget
-- spent) a plain keyword parser reads the chat's said events instead ("Mochi, sit!"), so the dog still obeys.

MOCHI_ID = "mochi"
MOCHI_NAME = "Mochi"
MOCHI_LAYER = 32                         -- (the client's dog parts: never hit by our rays)
MOCHI_MASK = 255 - MOCHI_LAYER

local CFG = {
	walk = 1.4, trot = 3.0, run = 5.6,     -- m/s
	turn = 420,                            -- deg/s
	followNear = 2.0, followFar = 4.0,     -- follow: stop within, trot beyond, run beyond 2x
	freeRange = 7.0,                       -- free: comes closer to people farther than this
	comeStop = 1.1,
	catchUp = 45,                          -- m from everyone: appears behind its person
	stuckFor = 4.0,
	reachBall = 0.55, deliver = 1.4,
	snatchHold = 0.9,                      -- s a treat is held out near its mouth before it takes it
	treatsMax = 4, treatCooldown = 1.2,
	publish = 0.05,                        -- s between shared.mochi updates
	agentEvery = 0.5,                      -- s between agent key writes
	eventEvery = 4,                        -- s: game events go as a line of their own at most this often (else with speech)
	stepUp = 0.45, gravity = 10,
	-- health and fights (the user, 2026-10-24: only the host orders attacks; Mochi bites back at whoever hurt him first;
	-- at 0 he dies and a fresh Mochi arrives next to the host)
	hp = 100, regen = 1.5, regenAfter = 8,  -- health; per s, after s without harm
	treatHeal = 25, petHeal = 5,
	shotDmg = 20, shotCap = 40,            -- a bullet through him; at most per frame (a shotgun's pellets)
	shotRadius = 0.32,                     -- m from his middle a bullet's line counts as through him
	blastDmg = 80,                         -- an explosion of strength 1 on top of him (less with distance)
	fallSafe = 9, fallDmg = 15,            -- landing faster than m/s hurts, per m/s over
	carDmg = 5, carSpeed = 4,              -- run over by a vehicle: per m/s, from m/s
	attackSpeed = 7.0, biteReach = 0.8, biteEvery = 0.8,
	bitePlayer = 0.12,                     -- of a player's health per bite
	defendFor = 15,                        -- s he keeps biting back after the last harm from them
	attackFor = 40,                        -- s an ordered attack lasts at most
	attackRange = 60,                      -- m: farther, he gives up
	respawn = 30,                          -- s dead before a fresh Mochi arrives
	-- the ball and the treats are tools (the user: "items that I can throw")
	ballThrow = 14, treatThrow = 9,        -- m/s thrown from the hand
	treatsStart = 10, treatRefill = 15,    -- treats each player has; one more every s, up to treatsStart
	pickUp = 2.2,                          -- m from the eye or feet: E picks the ball up
	ballBounce = 0.6, bounceFrom = 1.5,    -- of the speed it hits with; from m/s into the surface
	-- hits no event reports (sledgehammer, shots into the open, flying things, fire): see MochiHitsTick
	torchDmg = 25, fireDmg = 12,           -- per s: a blowtorch on him, fire under him
	flyingSpeed = 6, flyingDmg = 1.2,      -- a loose body faster than m/s through him: speed x sqrt(mass) x this (80 at most)
	blameFor = 4,                          -- s after someone let go of a thing it's still their throw
	-- running away: the AI decides (the user: "let the llm decide whether he should run. Run should be a function")
	fleeFor = 12,                          -- s he keeps running after the last harm
	fleeTo = 25,                           -- m from the danger: safe
	fleeLeg = 7,                           -- m a flee leg goes
	dangerMemory = 30,                     -- s "what hurt you last" is remembered
	badlyHurt = 40,                        -- health under this: "badly hurt" in what the AI knows
	-- wandering (the user: "when no player is nearby or no one is paying attention to him, mochi should wander around.
	-- If a player calls his name, Mochi should come close to the player")
	wanderAfter = 30,                      -- s without anyone paying attention to him
	nearby = 20,                           -- m: a player this close (and paying attention) keeps him by them
	wanderMin = 4, wanderMax = 10,         -- m a wander leg goes
	wanderLeash = 30,                      -- m from the nearest player (when anyone is within 60 m)
	wanderFar = 150,                       -- m: only this far from everyone does he appear behind someone while wandering
	callFrom = 4,                          -- m: his name called from farther brings him
	-- loud sounds (the user: "if there's a loud sound, the dog will turn towards the source"): the host's game hears them
	-- (GetLastSound) and tells the server; he faces the source when standing about, glances at it while busy
	soundLook = 2.5,                       -- s he keeps looking at it
}
MOCHI_BALL_TOOL, MOCHI_TREAT_TOOL = "mochiball", "mochitreats"
MOCHI_CFG = CFG

local reg = "proxchat.agent." .. MOCHI_ID
local function now() return GetTime() end

MOCHI = nil

local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
local function hdist(a, b) local dx, dz = a[1] - b[1], a[3] - b[3] return math.sqrt(dx * dx + dz * dz) end
local function yawTo(from, to) return math.deg(math.atan2(to[1] - from[1], to[3] - from[3])) end   -- (0 = +z)
local function angDiff(a, b) local d = (b - a) % 360 if d > 180 then d = d - 360 end return d end
local function fwd(yaw) local r = math.rad(yaw) return Vec(math.sin(r), 0, math.cos(r)) end

-- ---- players
local function players()
	local l = {}
	for _, p in ipairs(GetAllPlayers() or {}) do
		if IsPlayerValid(p) then l[#l + 1] = p end
	end
	return l
end

local function alive(p) return p and IsPlayerValid(p) and GetPlayerHealth(p) > 0 end
local function feet(p) return GetPlayerTransform(p).pos end
local function nameOf(p) local ok, n = pcall(GetPlayerName, p) return ok and n and n ~= "" and n or ("Player " .. tostring(p)) end

-- a player by a name the model or a player gave ("Alex", "alex", "Al", "me" with a speaker); nil if nobody fits
function MochiPlayerByName(s, speaker)
	s = tostring(s or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if (s == "" or s == "me" or s == "you" or s == "him" or s == "her" or s == "them") and alive(speaker) then return speaker end
	local best = nil
	for _, p in ipairs(players()) do
		local n = nameOf(p):lower()
		if n == s then return p end
		if not best and s ~= "" and (n:sub(1, #s) == s or s:find(n, 1, true)) then best = p end
	end
	return best
end

local function nearestPlayer(pos, maxd)
	local best, bd = nil, maxd or 1e9
	for _, p in ipairs(players()) do
		if alive(p) then
			local d = hdist(feet(p), pos) + math.abs(feet(p)[2] - pos[2]) * 0.5
			if d < bd then best, bd = p, d end
		end
	end
	return best, bd
end

-- ---- queries: our rays skip the dog's parts (client bodies, layer 32: in single player they are in the host's scene)
-- and its toys
local function filter()
	QueryCollisionMask(MOCHI_MASK)
	QueryRequire("physical")
	local M = MOCHI
	if M then
		if M.ball and IsHandleValid(M.ball) then QueryRejectBody(M.ball) end
		for _, t in ipairs(M.treats) do if IsHandleValid(t) then QueryRejectBody(t) end end
	end
end

-- the ground under x,z near height y (a step up to stepUp, or down to 2 m), or nil
local function groundAt(x, y, z)
	filter()
	local top = y + CFG.stepUp + 0.05
	local hit, d = QueryRaycast(Vec(x, top, z), Vec(0, -1, 0), CFG.stepUp + 2.05, 0.08)
	if not hit then return nil end
	return top - d - 0.08                                            -- (a sphere cast: d is how far its centre went)
end

-- a wall ahead within dist? (a ray just above the highest step it climbs)
local function blocked(pos, dir, dist)
	filter()
	local hit = QueryRaycast(VecAdd(pos, Vec(0, CFG.stepUp + 0.1, 0)), dir, dist, 0.08)
	return hit
end

-- a spot near the player p to put the dog (behind them, on the ground)
local function spotNear(p, back)
	local t = GetPlayerTransform(p)
	local b = TransformToParentVec(t, Vec(0, 0, back or 1.5))      -- (+z of a player = behind them)
	for _, k in ipairs({1, -1, 0.5}) do
		local q = VecAdd(t.pos, VecScale(b, k))
		local g = groundAt(q[1], t.pos[2] + 0.5, q[3])
		if g then return Vec(q[1], g, q[3]) end
	end
	return VecCopy(t.pos)
end

-- ---- toys
-- a toy's physics body: an UNSCALED, invisible model (a body holding a scaled shape stays static - the 0.025 m ball
-- floated where it was spawned, seen in-game); every machine draws the detailed model on it (dog_view.lua)
local function spawnBody(file, tag, pos, vel)
	local ok, ents = pcall(Spawn, string.format("<body dynamic='true' tags='%s'><vox file='%s' tags='invisible unbreakable %s'/></body>",
		tag, file, tag), Transform(pos))
	if not ok or type(ents) ~= "table" then return nil end
	for _, h in ipairs(ents) do
		if GetEntityType(h) == "body" then
			if vel then SetBodyVelocity(h, vel) end
			MOCHI.uncentred[h] = true
			return h
		end
	end
	return nil
end

-- a toy's shape centred on its body's origin (so "the ball at his mouth" means its middle); a fresh shape can read size 0
-- in its spawn frame, so this is tried each step until it works
local function centreToys()
	local M = MOCHI
	for h in pairs(M.uncentred) do
		if not IsHandleValid(h) then M.uncentred[h] = nil
		else
			local shapes = GetBodyShapes(h) or {}
			local ok = #shapes > 0
			for _, sh in ipairs(shapes) do
				local x, y, z, vs = GetShapeSize(sh)
				if not x or x <= 0 or not vs or vs <= 0 then ok = false end
			end
			if ok then
				for _, sh in ipairs(shapes) do
					local t = GetShapeLocalTransform(sh)
					local x, y, z, vs = GetShapeSize(sh)
					local c = TransformToParentPoint(t, Vec(x * vs / 2, y * vs / 2, z * vs / 2))
					SetShapeLocalTransform(sh, Transform(VecSub(t.pos, c), t.rot))
				end
				M.uncentred[h] = nil
			end
		end
	end
end

local function spawnBall(pos)
	local M = MOCHI
	if M.ball and IsHandleValid(M.ball) then Delete(M.ball) end
	M.ball = spawnBody("MOD/vox/ball_phys.vox", "mochiball", pos)
	M.ballV = nil
	M.carry = false
end

-- the invisible body the chat hangs its speech bubble over and hears from (agent at = body:<handle>): it follows the
-- head every step, so the bubble follows smoothly (an x,y,z place is read only every 0.5 s by the chat)
local function spawnAnchor()
	local M = MOCHI
	if M.anchor and IsHandleValid(M.anchor) then Delete(M.anchor) end
	local ok, ents = pcall(Spawn, "<body dynamic='true' tags='mochianchor'><vox file='MOD/vox/anchor.vox' tags='invisible unbreakable mochianchor'/></body>",
		Transform(VecAdd(M.pos, Vec(0, 0.7, 0))))
	M.anchor = nil
	if not ok or type(ents) ~= "table" then return end
	for _, h in ipairs(ents) do
		if GetEntityType(h) == "body" then
			M.anchor = h
			for _, s in ipairs(GetBodyShapes(h) or {}) do SetShapeCollisionFilter(s, MOCHI_LAYER, 0) end
		end
	end
end

-- the anchor whole? (seen in testing, 2026-10-24: a hit that went through him destroyed its one voxel - an empty body has
-- no bounds, Proximity Comms placed him at y = -3.4e38 from them and his lines reached nobody, with no error). Now it is
-- unbreakable, and if it is ever gone or empty all the same, it is made again (the chat follows its new handle)
local function anchorTick()
	local M = MOCHI
	local ok = M.anchor and IsHandleValid(M.anchor)
	if ok then
		local shapes = GetBodyShapes(M.anchor) or {}
		ok = #shapes > 0 and IsHandleValid(shapes[1]) and (GetShapeVoxelCount(shapes[1]) or 0) > 0
	end
	if not ok then
		spawnAnchor()
		M.anchorN = (M.anchorN or 0) + 1
	end
end

local function cleanTreats()
	local M, l = MOCHI, {}
	for _, t in ipairs(M.treats) do if IsHandleValid(t) then l[#l + 1] = t end end
	M.treats = l
end

local function bodyPos(h) return GetBodyTransform(h).pos end
local function heldBy(h)
	for _, p in ipairs(players()) do
		local ok, g = pcall(GetPlayerGrabBody, p)
		if ok and g == h then return p end
	end
	return nil
end

-- who has the ball: in their tools (MOCHI.ballIn), or grabbed with the right mouse
local function ballHolder()
	local M = MOCHI
	if M.ballIn then
		if IsPlayerValid(M.ballIn) then return M.ballIn end
		M.ballIn = nil                                                -- (they left: the ball comes back by the dog)
	end
	if M.ball and IsHandleValid(M.ball) then return heldBy(M.ball) end
	return nil
end

-- someone is paying attention to him (talk, petting, treats, the ball, commands): he stays by his people
local function attend()
	local M = MOCHI
	M.attentionT = now()
	M.wander = nil
end

-- ---- agent events: what happens to him, for the AI. Each line written to proxchat.agent.mochi.event is a request of its
-- own, so events are GATHERED (the user: "game events should be sent at most every 4 seconds, and if someone speaks,
-- those events should piggyback on the lines"): the newest of each kind (repeats counted: "... (4 times just now)") wait
-- in what he knows (proxchat.agent.mochi.state, which goes with every line said to him: "Just happened: ..."). A line
-- said near him carries them - they are cleared a moment later - and only when nobody speaks within eventEvery s do they
-- go out as one event line of their own, at most every eventEvery s. Arriving, dying and coming back go at once.
local URGENT = {arrive = true, die = true, back = true}
local function event(kind, text)
	local M = MOCHI
	local P = M.pendingEv
	if next(P) == nil then M.evFirstT = now() end
	if P[kind] then P[kind].text, P[kind].n = text, P[kind].n + 1
	else
		M.evOrder = M.evOrder + 1
		P[kind] = {text = text, n = 1, order = M.evOrder}
	end
	M.lastEvent = text
	M.stateDirty = true                                               -- (into what he knows at once: a line may carry it)
	if URGENT[kind] then M.evUrgent = true end
end

-- Proximity Comms API 18 (2026-10-24, from Mochi's findings): .note, .say, .heard, call .from, .replyfrom, hears=engaged
local function api18() return GetInt("proxchat.version") >= 18 end
MochiApi18 = api18

-- player ids in a space-separated list (a call's .from, a reply's .replyfrom); {} when none
local function idList(str)
	local l = {}
	for w in tostring(str or ""):gmatch("%S+") do
		local n = tonumber(w)
		if n then l[#l + 1] = n end
	end
	return l
end
MochiIdList = idList

-- he says text without the model (API 18 .say: a bubble, babble in his voice, the chat; the model hears of it with its
-- next line): his fallback lines and noises when the AI can't answer
function MochiSay(text)
	if not api18() or MOCHI.dead then return end
	SetString(reg .. ".say", text)
	MOCHI.sayN = (MOCHI.sayN or 0) + 1
end

-- the waiting events as one text, in the order they happened ("" when none)
function MochiPendingEvents()
	local list = {}
	for kind, e in pairs(MOCHI.pendingEv) do list[#list + 1] = e end
	table.sort(list, function(a, b) return a.order < b.order end)
	local parts = {}
	for _, e in ipairs(list) do
		parts[#parts + 1] = e.text .. (e.n > 1 and string.format(" (%d times just now)", e.n) or "")
	end
	return table.concat(parts, " ")
end

-- (said) a line said near him carries the waiting events in its state: they go a moment later (the chat reads the state
-- when it hands the line on)
local function eventsRide()
	local M = MOCHI
	if api18() then return end                                        -- (API 18: .note does this exactly)
	if next(M.pendingEv) ~= nil and not M.evRideUntil then M.evRideUntil = now() + 1.0 end
end

-- (each tick) the gathered events out as one line, when it's time
local function flushEvents()
	local M = MOCHI
	local t = now()
	if api18() then
		-- the waiting events stand in .note: the chat sends it with the next line the agent gets and clears it
		local key = reg .. ".note"
		if M.noteText and GetString(key) == "" then                    -- (a line took it: they went)
			M.pendingEv, M.noteText = {}, nil
			M.evRode = M.evRode + 1
		end
		if next(M.pendingEv) == nil then return end
		local text = MochiPendingEvents()
		if M.evUrgent or (t - M.evFirstT >= CFG.eventEvery and t - M.evFlushT >= CFG.eventEvery) then
			ClearKey(key)                                               -- (nobody spoke in time: a line of their own)
			local cur = GetString(reg .. ".event")
			SetString(reg .. ".event", cur ~= "" and (cur .. "\n" .. text) or text)
			M.pendingEv, M.noteText, M.evUrgent, M.evFlushT = {}, nil, false, t
			M.eventLines = M.eventLines + 1
		elseif text ~= M.noteText then
			SetString(key, text)
			M.noteText = text
		end
		return
	end
	if M.evRideUntil and t >= M.evRideUntil then                     -- (they went with a player's line)
		M.pendingEv, M.evRideUntil, M.stateDirty = {}, nil, true
		M.evRode = M.evRode + 1
	end
	if next(M.pendingEv) == nil or M.evRideUntil then return end
	if not M.evUrgent and (t - M.evFirstT < CFG.eventEvery or t - M.evFlushT < CFG.eventEvery) then return end
	local text = MochiPendingEvents()
	local cur = GetString(reg .. ".event")
	SetString(reg .. ".event", cur ~= "" and (cur .. "\n" .. text) or text)
	M.pendingEv, M.evUrgent, M.evFlushT, M.stateDirty = {}, false, t, true
	M.eventLines = M.eventLines + 1
end

-- ---- acts, postures, wag
local function wag(seconds, level)
	local M = MOCHI
	M.wagUntil = math.max(M.wagUntil, now() + (seconds or 4))
	M.wagLevel = math.max(M.wagLevel, level or 1)
end

-- start a one-shot act now (it plays from the current posture; at its end the posture is DOG_ACTS[kind].after)
local function startAct(kind)
	local M = MOCHI
	local d = DOG_ACTS[kind]
	if not d then return false end
	M.act = {kind = kind, t0 = now(), dur = d.dur, base = M.posture}
	M.actN = M.actN + 1
	if kind == "bark" then M.barkN = M.barkN + 1 end
	return true
end

-- a trick by its name for the model / players: the act that does it ("sit" from a sit: nothing to do)
local TRICKS = {
	sit = "sit_down", lie_down = "lie_down", down = "lie_down", stand_up = "stand_up", stand = "stand_up",
	roll_over = "roll_over", play_dead = "play_dead", bang = "play_dead", spin = "spin", jump = "jump",
	shake_paw = "shake_paw", paw = "shake_paw", beg = "beg", bow = "bow", bark = "bark",
}
MOCHI_TRICKS = {"sit", "lie_down", "stand_up", "roll_over", "play_dead", "spin", "jump", "shake_paw", "beg", "bow", "bark"}

local function queueAct(kind)
	local M = MOCHI
	if #M.queue >= 4 then table.remove(M.queue, 1) end
	M.queue[#M.queue + 1] = kind
end

-- what posture an act needs first, if the dog is not in it
local function needsStand(kind) return kind == "spin" or kind == "jump" or kind == "bow" end

local function actTick()
	local M = MOCHI
	local t = now()
	if M.act and t - M.act.t0 >= M.act.dur then
		local after = DOG_ACTS[M.act.kind].after
		if after then M.posture = after end
		M.act = nil
		if M.posture == "dead" and not M.dead then M.deadUntil = t + 5 end
	end
	if M.posture == "dead" and not M.dead and not M.act and M.deadUntil and t > M.deadUntil and #M.queue == 0 then
		M.deadUntil = nil
		queueAct("stand_up"); wag(3, 1)                              -- (it gets up, proud of itself)
	end
	if not M.act and #M.queue > 0 then
		local k = M.queue[1]
		if needsStand(k) and M.posture ~= "stand" then startAct("stand_up"); return end
		if k == "sit_down" and M.posture == "sit" then table.remove(M.queue, 1); return end
		if k == "lie_down" and M.posture == "lie" then table.remove(M.queue, 1); return end
		if k == "stand_up" and M.posture == "stand" then table.remove(M.queue, 1); return end
		if (k == "shake_paw" or k == "beg") and M.posture ~= "sit" and M.posture ~= "stand" then
			startAct("stand_up"); return
		end
		table.remove(M.queue, 1)
		startAct(k)
	end
end

-- ---- commands (the agent's function calls and the keyword parser): {ok = bool, text}
local function setMode(mode, who)
	local M = MOCHI
	M.mode, M.target = mode, who
	M.fetch = nil
	M.path, M.pathPts = nil, nil
	M.stuckT = 0
end

-- play fetch for player "to" (phase seek / wait / bring); remembers what it did before (it goes back to that)
local function startFetch(to, phase)
	local M = MOCHI
	if M.mode ~= "fetch" then M.prevMode, M.prevTarget = M.mode, M.target end
	setMode("fetch", to)
	M.fetch = {phase = phase, to = to}
end

-- ---- health and fights
local function hostPlayer()
	for _, p in ipairs(players()) do
		local ok, h = pcall(IsPlayerHost, p)
		if ok and h then return p end
	end
	return players()[1]
end
MochiHost = hostPlayer

local function bodyMid(b)
	local lo, hi = GetBodyBounds(b)
	return VecScale(VecAdd(lo, hi), 0.5), lo, hi
end

local function attackerName(a)
	if not a then return "something" end
	if a.p then return nameOf(a.p) end
	return a.what or "that thing"
end

-- bite a = {p = player} or {body = handle, what = name}; why "ordered" (by the host) or "defend" (they hurt him)
local function startAttack(a, why)
	local M = MOCHI
	if M.dead or not a or not (a.p or a.body) then return end
	local A = M.attack
	local same = A and ((a.p and A.p == a.p) or (a.body and A.body == a.body))
	if same then
		A.hurtT = now()
		if why == "ordered" then A.why, A.t0 = "ordered", now() end
		return
	end
	M.attack = {p = a.p, body = a.body, what = a.what, why = why, t0 = now(), hurtT = now()}
	M.growlN = M.growlN + 1
	M.queue = {}
	if M.carry then MochiDropBall() end
	if a.p then M.look, M.lookUntil = a.p, now() + 2 end
end

-- the attack is over: its target is down, gone, far, or (defending) has left him alone a while
local function attackOver()
	local M, A = MOCHI, MOCHI.attack
	if A.p then
		if not alive(A.p) then return "down" end
		if hdist(feet(A.p), M.pos) > CFG.attackRange then return "away" end
	else
		if not IsHandleValid(A.body) then return "gone" end
		if hdist(bodyMid(A.body), M.pos) > CFG.attackRange then return "away" end
	end
	if A.why == "defend" and now() - A.hurtT > CFG.defendFor then return "calm" end
	if A.why == "ordered" and now() - A.t0 > CFG.attackFor then return "calm" end
	return nil
end

-- where he bites: a player's feet, or the point of a body's bounds nearest to him (a car's side, not its middle)
local function attackPoint()
	local M, A = MOCHI, MOCHI.attack
	if A.p then return feet(A.p) end
	local _, lo, hi = bodyMid(A.body)
	return Vec(clamp(M.pos[1], lo[1], hi[1]), clamp(M.pos[2] + 0.4, lo[2], hi[2]), clamp(M.pos[3], lo[3], hi[3]))
end

local function bite()
	local M, A = MOCHI, MOCHI.attack
	M.biteT = now()
	startAct("bite")
	local f = fwd(M.yaw)
	local mouth = VecAdd(M.pos, VecAdd(VecScale(f, 0.45), Vec(0, 0.4, 0)))
	if A.p then
		pcall(ApplyPlayerDamage, A.p, CFG.bitePlayer, "Mochi", A.why == "ordered" and hostPlayer() or nil)
		event("bit", "You bit " .. nameOf(A.p) .. "!")
	else
		local to = attackPoint()
		local dir = VecNormalize(VecSub(to, mouth))
		filter()
		local hit, d = QueryRaycast(mouth, dir, 1.6)
		local pt = hit and VecAdd(mouth, VecScale(dir, d)) or to
		pcall(MakeHole, pt, 0.15, 0.08, 0.04)
		if IsHandleValid(A.body) and IsBodyDynamic(A.body) then
			local m = math.min(GetBodyMass(A.body) or 0, 300)
			ApplyBodyImpulse(A.body, pt, VecScale(VecAdd(dir, Vec(0, 0.3, 0)), m * 1.2))
		end
		event("bit", "You bit " .. attackerName(A) .. "!")
	end
end

-- a bullet's line (it hit pos travelling along dir) through his middle c? And who fired it: a player whose eye is on
-- the line behind him, else a loose body back along it (a robot), else nobody known
local function shotThrough(c, pos, dir)
	local b = VecScale(VecNormalize(dir), -1)
	local v = VecSub(c, pos)
	local along = VecDot(v, b)
	if along < -0.2 or along > 150 then return false end
	if VecLength(VecSub(v, VecScale(b, along))) > CFG.shotRadius then return false end
	local best, bd = nil, 1.2
	for _, p in ipairs(players()) do
		local e = VecSub(GetPlayerEyeTransform(p).pos, pos)
		local ae = VecDot(e, b)
		if ae > along then
			local pe = VecLength(VecSub(e, VecScale(b, ae)))
			if pe < bd then best, bd = p, pe end
		end
	end
	if best then return true, {p = best} end
	filter()
	local hit, _, _, shape = QueryRaycast(VecAdd(c, VecScale(b, 0.4)), b, 80)
	if hit and shape and shape ~= 0 then
		local body = GetShapeBody(shape)
		if body and body ~= 0 and IsBodyDynamic(body) then return true, {body = body, what = "the thing that shot you"} end
	end
	return true, nil
end

local function die(by, cause)
	local M = MOCHI
	M.dead, M.diedT, M.hp = true, now(), 0
	if M.carry then MochiDropBall() end
	M.attack, M.queue, M.act = nil, {}, nil
	setMode("free")
	M.speed = 0
	startAct("die")
	M.diedN = M.diedN + 1
	event("die", "You were hurt too badly (" .. (by and ("by " .. attackerName(by)) or cause or "hurt") ..
		") and you are dying. Say a very short, sweet goodbye to your people.", true)
end

-- a fresh Mochi arrives next to the host, all healed (he remembers everything: it's still him)
local function respawn()
	local M = MOCHI
	local host = hostPlayer()
	if not host then return end
	M.pos = spotNear(host, 1.6)
	M.yaw = yawTo(M.pos, feet(host))
	M.dead, M.hp, M.vy, M.speed = false, CFG.hp, 0, 0
	M.posture, M.act, M.queue, M.path, M.pathPts, M.stuckT = "stand", nil, {}, nil, nil, 0
	M.respawnN = M.respawnN + 1
	M.attentionT, M.wander = now(), nil
	M.look, M.lookUntil = host, now() + 4
	wag(6, 1)
	queueAct("bark")
	event("back", "You're back, all healed, and so happy to see everyone again!")
end

-- harm: amount of health, by {p = player} / {body = handle} / nil, cause ("shot", "explosion", "fall", "run over")
function MochiDamage(amount, by, cause, at)
	local M = MOCHI
	if not (M and M.started) or M.dead or not amount or amount <= 0 then return end
	M.hp = M.hp - amount
	M.hurtT = now()
	M.yelpN = M.yelpN + 1
	if M.hp <= 0 then die(by, cause); return end
	if not (M.act and M.act.kind == "bite") then M.act = nil; startAct("flinch") end
	if by and by.p and not alive(by.p) then by = nil end
	-- what hurt him last, and where (run_away's default): the attacker, else the place (an explosion, a fire, a shot's line)
	if by or at then
		M.danger = {p = by and by.p, body = by and by.body, what = by and attackerName(by) or cause, pos = at and VecCopy(at), t = now()}
	end
	if M.flee then M.flee.untilT = now() + CFG.fleeFor end            -- (still being hurt: keeps running)
	if by and not M.flee then startAttack(by, "defend") end
	local bad = M.hp < CFG.badlyHurt
	event("hurt", (by and (attackerName(by) .. " hurt you") or ("You got hurt (" .. tostring(cause or "ouch") .. ")")) ..
		string.format("! Your health: %d/%d%s.", math.floor(M.hp + 0.5), CFG.hp, bad and " - you are badly hurt" or "") ..
		(M.flee and " You keep running!" or (by and " You bite back!" or "")))
end

-- where a danger is now: its player, its body, or the place it happened
local function dangerPos(D)
	if D.p then return alive(D.p) and feet(D.p) or D.pos end
	if D.body and IsHandleValid(D.body) then return GetBodyTransform(D.body).pos end
	return D.pos
end
MochiDangerPos = dangerPos

-- run_away: from a named player, or from "danger" (whatever hurt him last); nil and why when there's nothing to run from
function MochiStartFlee(from, speaker)
	local M = MOCHI
	local s = tostring(from or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local D
	if s ~= "" and s ~= "danger" and s ~= "it" and s ~= "that" and s ~= "them" then
		local p = MochiPlayerByName(s, nil)
		if p then D = {p = p, what = nameOf(p), t = now()} end
	end
	if not D and M.danger and now() - M.danger.t < CFG.dangerMemory then D = M.danger end
	if not D or not dangerPos(D) then return nil, "nothing here to run from" end
	M.flee = {D = D, untilT = now() + CFG.fleeFor, to = nil, legT = -1e9}
	M.attack = nil
	M.queue = {}
	M.wander = nil
	if M.carry then MochiDropBall() end
	if M.posture ~= "stand" then queueAct("stand_up") end
	return D.what or "danger"
end

-- (goal) a spot fleeLeg m away from the danger: straight away from it, else turning up to 105 degrees off, with ground and
-- no wall right ahead; nil when none
local function fleePoint(dpos)
	local M = MOCHI
	local away = Vec(M.pos[1] - dpos[1], 0, M.pos[3] - dpos[3])
	if VecLength(away) < 0.1 then away = fwd(M.yaw) end
	local base = yawTo(Vec(0, 0, 0), VecNormalize(away))
	for _, k in ipairs({0, 35, -35, 70, -70, 105, -105}) do
		local f = fwd(base + k)
		local x, z = M.pos[1] + f[1] * CFG.fleeLeg, M.pos[3] + f[3] * CFG.fleeLeg
		local g = groundAt(x, M.pos[2] + 0.5, z)
		if g and math.abs(g - M.pos[2]) < 1.5 and not blocked(M.pos, f, 1.2) then return Vec(x, g, z) end
	end
	return nil
end

-- (server.tick: events are per frame) bullets and explosions; health back over time
local function hurtTick(dt)
	local M = MOCHI
	if M.dead then return end
	local c = VecAdd(M.pos, Vec(0, 0.3, 0))
	local shot, by, shotFrom = 0, nil, nil
	for i = 1, GetEventCount("projectilehit") do
		local _, pos, dir = GetEvent("projectilehit", i)
		if pos and dir then
			local through, who = shotThrough(c, pos, dir)
			if through and not (who and who.p and MochiShotCounted(who.p)) then   -- (already counted by the aim check)
				shot = shot + CFG.shotDmg; by = by or who
				shotFrom = shotFrom or VecAdd(c, VecScale(VecNormalize(dir), -10))   -- (back along the bullet's line)
			end
		end
	end
	local blast, blastAt, worst = 0, nil, 0
	for i = 1, GetEventCount("explosion") do
		local pos, str = GetEvent("explosion", i)
		str = tonumber(str) or 1
		local r = 2 + 3 * str
		local d = pos and VecLength(VecSub(pos, c)) or 1e9
		if d < r then
			local hurt = CFG.blastDmg * str * (1 - d / r)
			blast = blast + hurt
			if hurt > worst then worst, blastAt = hurt, pos end
		end
	end
	if shot > 0 then MochiDamage(math.min(shot, CFG.shotCap), by, "shot", shotFrom) end
	if blast > 0 then MochiDamage(blast, nil, "an explosion", blastAt) end
	if not M.dead and now() - M.hurtT > CFG.regenAfter then M.hp = math.min(CFG.hp, M.hp + CFG.regen * dt) end
end

-- (each step) a player's vehicle driving into him
local function carTick()
	local M = MOCHI
	if M.dead or now() - M.carT < 1 then return end
	for _, p in ipairs(players()) do
		local okV, v = pcall(GetPlayerVehicle, p)
		if okV and v and v ~= 0 then
			local body = GetVehicleBody(v)
			local vel = GetBodyVelocity(body)
			local sp = VecLength(vel)
			if sp > CFG.carSpeed then
				local lo, hi = GetBodyBounds(body)
				local q = M.pos
				if q[1] > lo[1] - 0.3 and q[1] < hi[1] + 0.3 and q[3] > lo[3] - 0.3 and q[3] < hi[3] + 0.3
					and q[2] + 0.5 > lo[2] and q[2] < hi[2] then
					M.carT = now()
					M.pos = VecAdd(M.pos, VecScale(VecNormalize(Vec(vel[1], 0, vel[3])), 1.2))   -- (knocked aside)
					MochiDamage(sp * CFG.carDmg, {p = p}, "a car", GetBodyTransform(body).pos)
					return
				end
			end
		end
	end
end

-- ---- hits no event reports (the user: "there must be a way to register hammer hits and other hits on mochi"): he has
-- no physics body, so the game raises nothing when a sledgehammer, a gun aimed at the sky, a thrown brick or fire meets
-- him. Instead:
--   * tools by intent: a sledge swing (the tool's button pressed) whose aim ray reaches his box within reach with nothing
--     in between; a gun, shotgun or rifle shot (its ammo went down this frame) whose aim ray meets his box first (the
--     shooter's bullets on his line are then not counted twice from projectilehit); a blowtorch held on him up close
--   * flying things: a loose body moving fast inside his box (thrown, swung while held, blown off by an explosion),
--     blamed on whoever held it in the last few seconds
--   * fire under him
local HIT_TOOLS = {sledge = {reach = 2.8, dmg = 30, every = 0.45}, gun = {reach = 100, dmg = 25},
	shotgun = {reach = 30, dmg = 35}, rifle = {reach = 200, dmg = 60}}
local HIT_BOX_LO, HIT_BOX_HI = Vec(-0.2, 0.0, -0.42), Vec(0.2, 0.78, 0.48)   -- (his root frame: legs, body, head, ears)

-- where the ray (origin o, unit dir d) enters his box within maxd, or nil
function MochiRayHit(o, d, maxd)
	local M = MOCHI
	local inv = QuatEuler(0, -M.yaw, 0)
	local lo = QuatRotateVec(inv, VecSub(o, M.pos))
	local ld = QuatRotateVec(inv, d)
	local tmin, tmax = 0, maxd
	for i = 1, 3 do
		if math.abs(ld[i]) < 1e-9 then
			if lo[i] < HIT_BOX_LO[i] or lo[i] > HIT_BOX_HI[i] then return nil end
		else
			local t1, t2 = (HIT_BOX_LO[i] - lo[i]) / ld[i], (HIT_BOX_HI[i] - lo[i]) / ld[i]
			if t1 > t2 then t1, t2 = t2, t1 end
			tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
			if tmin > tmax then return nil end
		end
	end
	return tmin
end

-- player p's aim reaches him first (within reach, nothing solid in between): the distance, or nil
local function aimedAt(p, reach)
	local eye = GetPlayerEyeTransform(p)
	local d = TransformToParentVec(eye, Vec(0, 0, -1))
	local t = MochiRayHit(eye.pos, d, reach)
	if not t then return nil end
	filter()
	QueryRejectPlayer(p)
	local hit, wd = QueryRaycast(eye.pos, d, t)
	if hit and wd < t - 0.05 then return nil end                     -- (a wall between)
	return t
end

local function knockBack(from, dist)
	local M = MOCHI
	local away = VecNormalize(Vec(M.pos[1] - from[1], 0, M.pos[3] - from[3]))
	local to = VecAdd(M.pos, VecScale(away, dist))
	local g = groundAt(to[1], M.pos[2], to[3])
	if g and g < M.pos[2] + CFG.stepUp and not blocked(M.pos, away, dist + 0.2) then M.pos = Vec(to[1], g, to[3]) end
end

local function toolHits(dt)
	local M = MOCHI
	local t = now()
	for _, p in ipairs(players()) do
		local okT, tool = pcall(GetPlayerTool, p)
		local T = okT and HIT_TOOLS[tool]
		local st = M.toolState[p] or {}
		M.toolState[p] = st
		if T and alive(p) and GetPlayerVehicle(p) == 0 then
			local okA, ammo = pcall(GetToolAmmo, tool, p)
			ammo = okA and tonumber(ammo) or 0
			local fired
			if tool == "sledge" then
				fired = InputPressed("usetool", p) and t - (st.swingT or -1e9) >= T.every
				if fired then st.swingT = t end
			else
				fired = st.tool == tool and st.ammo and ammo < st.ammo   -- (a round went: it fired)
			end
			st.tool, st.ammo = tool, ammo
			if fired then
				local dist = aimedAt(p, T.reach)
				if dist then
					st.shotT = t
					if tool == "sledge" then knockBack(feet(p), 0.7) end
					MochiDamage(T.dmg, {p = p}, tool == "sledge" and "hit with a sledgehammer" or "shot", feet(p))
				end
			end
		else
			st.tool, st.ammo = nil, nil
		end
		-- a blowtorch held on him up close burns
		if okT and tool == "blowtorch" and alive(p) and InputDown("usetool", p) and aimedAt(p, 1.6) then
			M.burn = (M.burn or 0) + CFG.torchDmg * dt
			M.burnBy = {p = p}
		end
	end
end

-- (MochiDamage callers) was this player's bullet already counted by the aim check this moment?
function MochiShotCounted(p)
	local st = MOCHI.toolState[p]
	return st and st.shotT and now() - st.shotT < 0.3
end

-- loose bodies flying through him; who held each lately (grabbed with the right mouse)
local function flyingHits()
	local M = MOCHI
	local t = now()
	for _, p in ipairs(players()) do
		local okG, g = pcall(GetPlayerGrabBody, p)
		if okG and g and g ~= 0 then M.heldBy[g] = {p = p, t = t} end
	end
	local lo = VecAdd(M.pos, Vec(-0.6, -0.1, -0.6))
	local hi = VecAdd(M.pos, Vec(0.6, 0.9, 0.6))
	local okQ, list = pcall(QueryAabbBodies, lo, hi)
	for _, b in ipairs(okQ and list or {}) do
		if IsHandleValid(b) and IsBodyDynamic(b) and not HasTag(b, "mochiball") and not HasTag(b, "mochitreat")
			and not HasTag(b, "mochianchor") and not HasTag(b, "mochidog") and not HasTag(b, "mochitoy")
			and t - (M.hitT[b] or -1e9) > 0.6 then
			local v = GetBodyVelocity(b)
			local sp = VecLength(v)
			if sp > CFG.flyingSpeed then
				local blo, bhi = GetBodyBounds(b)
				local mid = VecScale(VecAdd(blo, bhi), 0.5)
				local into = MochiRayHit(VecSub(mid, VecScale(VecNormalize(v), 0.6)), VecNormalize(v), 1.2)
				if into then
					M.hitT[b] = t
					local mass = math.max(0.5, GetBodyMass(b) or 1)
					local h = M.heldBy[b]
					local by = h and t - h.t < CFG.blameFor and alive(h.p) and {p = h.p} or nil
					MochiDamage(math.min(80, sp * math.sqrt(mass) * CFG.flyingDmg), by, "something flying", mid)
					knockBack(mid, 0.4)
				end
			end
		end
	end
end

-- (server.tick) all of the above, and fire under him
function MochiHitsTick(dt)
	local M = MOCHI
	if M.dead then return end
	toolHits(dt)
	flyingHits()
	local okF, fire = pcall(QueryClosestFire, VecAdd(M.pos, Vec(0, 0.3, 0)), 0.6)
	if okF and fire then M.burn = (M.burn or 0) + CFG.fireDmg * dt; M.burnAt = VecCopy(M.pos) end
	if (M.burn or 0) >= 5 then                                      -- (burns in bites of 5, not a yelp a frame)
		MochiDamage(M.burn, M.burnBy, "fire", M.burnBy and M.burnBy.p and feet(M.burnBy.p) or M.burnAt)
		M.burn, M.burnBy = 0, nil
	end
end

-- what the host means by an attack's target: a player's name, or "that" (what the host is looking at: a player near
-- the aim first, else a loose body the aim hits); nil: nothing there
local THAT = {[""] = true, that = true, it = true, this = true, there = true, him = true, her = true, them = true,
	robot = true, ["the robot"] = true, enemy = true, thing = true, ["that thing"] = true, ["that robot"] = true}
function MochiResolveTarget(s, host)
	local M = MOCHI
	s = tostring(s or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if not THAT[s] then
		local p = MochiPlayerByName(s, nil)
		if p then return {p = p} end
	end
	if not host then return nil end
	local eye = GetPlayerEyeTransform(host)
	local dir = TransformToParentVec(eye, Vec(0, 0, -1))
	local best, bd = nil, 1e9
	for _, p in ipairs(players()) do
		if p ~= host and alive(p) then
			local v = VecSub(VecAdd(feet(p), Vec(0, 1, 0)), eye.pos)
			local along = VecDot(v, dir)
			if along > 0 and along < 80 then
				local perp = VecLength(VecSub(v, VecScale(dir, along)))
				if perp < 1.2 + along * 0.03 and perp < bd then best, bd = p, perp end
			end
		end
	end
	if best then return {p = best} end
	filter()
	local hit, _, _, shape = QueryRaycast(eye.pos, dir, 80)
	if hit and shape and shape ~= 0 then
		local body = GetShapeBody(shape)
		if body and body ~= 0 and IsBodyDynamic(body) and body ~= M.ball then return {body = body, what = "that thing"} end
	end
	return nil
end

function MochiCommand(name, args, speaker)
	local M = MOCHI
	args = args or {}
	attend()
	if M.dead then return false, "error: you are dead (a fresh Mochi comes back soon)" end
	if M.flee and (name == "come" or name == "follow" or name == "stay" or name == "relax") then M.flee = nil end
	if name == "attack" then
		-- ONLY the host orders attacks (the user, 2026-10-24). The call carries no speaker, so the line it answers is the
		-- last one a player said near him: it must be the host's (a player can't talk the AI into it)
		local host = MochiHost()
		if not (host and speaker == host) then
			return false, "error: only your owner " .. (host and nameOf(host) or "") .. " can tell you to attack - you refuse"
		end
		local tg = MochiResolveTarget(args.target or args.player, host)
		if not tg then return false, "error: there is nothing there to attack" end
		if tg.p == host then return false, "error: you would never bite your owner" end
		startAttack(tg, "ordered")
		M.mode = M.mode == "come" and "free" or M.mode
		return true, "ok: attacking " .. attackerName(tg)
	elseif name == "run_away" then
		local what, why = MochiStartFlee(args.from, speaker)
		if not what then return false, "error: " .. why end
		return true, "ok: running away from " .. what
	elseif name == "stop_attack" then
		if M.flee then M.flee = nil; return true, "ok: you stop running and calm down" end
		if not M.attack then return true, "ok: you weren't attacking anyone" end
		if M.attack.why == "ordered" and speaker ~= MochiHost() then
			return false, "error: only your owner can call you off"
		end
		M.attack = nil
		wag(2, 0.5)
		return true, "ok: you calm down"
	elseif name == "trick" then
		local tr = tostring(args.name or args.trick or ""):lower():gsub("[%s%-]", "_")
		local kind = TRICKS[tr]
		if not kind then return false, "error: no trick called " .. tr .. " (tricks: " .. table.concat(MOCHI_TRICKS, ", ") .. ")" end
		if M.mode == "come" or M.mode == "fetch" then setMode(M.mode == "fetch" and "free" or M.mode, M.target) end
		M.moving = false
		queueAct(kind)
		if kind == "play_dead" then M.deadUntil = nil end
		return true, "ok: doing " .. tr
	elseif name == "follow" then
		local p = MochiPlayerByName(args.player, speaker)
		if not p then return false, "error: nobody here called " .. tostring(args.player) end
		setMode("follow", p)
		if M.posture ~= "stand" then queueAct("stand_up") end
		return true, "ok: following " .. nameOf(p)
	elseif name == "stay" then
		setMode("stay", nil)
		return true, "ok: staying here"
	elseif name == "relax" then
		setMode("free", nil)
		return true, "ok: free to wander near everyone"
	elseif name == "come" then
		local p = MochiPlayerByName(args.player, speaker)
		if not p then return false, "error: nobody here called " .. tostring(args.player) end
		setMode("come", p)
		if M.posture ~= "stand" then queueAct("stand_up") end
		return true, "ok: running to " .. nameOf(p)
	elseif name == "fetch" then
		if not (M.ballIn or (M.ball and IsHandleValid(M.ball))) then return false, "error: there is no ball" end
		local p = MochiPlayerByName(args.player, speaker) or speaker
		local h = ballHolder()
		if M.carry then
			startFetch(p, "bring")
		elseif h then
			startFetch(p, "wait")
			wag(4, 1)
			return true, "ok: waiting for " .. nameOf(h) .. " to throw the ball"
		else
			startFetch(p, "seek")
		end
		if M.posture ~= "stand" then queueAct("stand_up") end
		wag(4, 1)
		return true, "ok: going for the ball"
	elseif name == "drop" then
		if not M.carry then return false, "error: nothing in your mouth" end
		MochiDropBall()
		return true, "ok: dropped the ball"
	elseif name == "wag" then
		local s = clamp(tonumber(args.seconds) or 4, 1, 15)
		wag(s, 1)
		return true, "ok: wagging"
	end
	return false, "error: unknown action " .. tostring(name)
end

-- ---- the ball in its mouth
local poseOut = {}
local function mouthWorld()
	local M = MOCHI
	local a = {st = M.act and M.act.kind or (M.speed > 0.2 and "walk" or M.posture), t = M.act and (now() - M.act.t0) or 0,
		base = M.act and M.act.base or M.posture, phase = M.phase, speed = M.speed, carry = true, time = now()}
	DogPose(a, poseOut)
	local m = poseOut.__mouth or Vec(0, 0.45, 0.45)
	return TransformToParentPoint(Transform(M.pos, QuatEuler(0, M.yaw, 0)), m)
end

function MochiDropBall()
	local M = MOCHI
	if not M.carry then return end
	M.carry = false
	if M.ball and IsHandleValid(M.ball) then
		SetBodyTransform(M.ball, Transform(mouthWorld()))
		SetBodyVelocity(M.ball, VecAdd(VecScale(fwd(M.yaw), 0.8), Vec(0, 0.5, 0)))
	end
end

-- where the speech bubble hangs: over its ears, wherever it is
local function headTop()
	local M = MOCHI
	local h = DOG_RIG.headTop or {0, 0.7, 0.35}
	return TransformToParentPoint(Transform(M.pos, QuatEuler(0, M.yaw, 0)), Vec(h[1], h[2], h[3]))
end

-- ---- init
function MochiServerInit()
	MOCHI = {pos = nil, yaw = 0, vy = 0, speed = 0, phase = 0, grounded = true, posture = "stand", act = nil, actN = 0,
		barkN = 0, whineN = 0, queue = {}, mode = "free", target = nil, fetch = nil, carry = false, ball = nil, treats = {},
		wagUntil = 0, wagLevel = 0, talkUntil = 0, look = 0, lookUntil = 0, pendingEv = {}, evOrder = 0, evFlushT = -1e9, evFirstT = 0,
		evUrgent = false, eventLines = 0, evRideUntil = nil, evRode = 0, stateDirty = false, treatT = {}, petN = 0,
		heartN = 0, eatN = 0, said = nil, calls = nil, replyN = nil, pubT = -1, agentT = -1, idleT = 0, stuckT = 0,
		lastPos = nil, holder = {}, offer = {}, n = 0, path = nil, planner = nil, started = false, sniffT = 0,
		hp = CFG.hp, dead = false, diedT = 0, hurtT = -1e9, attack = nil, biteT = -1e9, yelpN = 0, growlN = 0, carT = -1e9,
		diedN = 0, respawnN = 0, lastSpeaker = nil, lastSpeakerT = -1e9, ballIn = nil, treatsLeft = {}, treatsT = {},
		lastThrower = nil, attentionT = -1e9, wander = nil, sound = nil, soundN = 0, uncentred = {}, ballV = nil, bounceN = 0, toolState = {},
		heldBy = {}, hitT = {}}
end

-- the first tick with a player: the dog arrives in front of the host, its ball beside it
local function start()
	local M = MOCHI
	local host = nil
	for _, p in ipairs(players()) do if IsPlayerHost(p) then host = p end end
	host = host or players()[1]
	if not host then return false end
	local t = GetPlayerTransform(host)
	local ahead = TransformToParentVec(t, Vec(0, 0, -2.5))
	local p = VecAdd(t.pos, ahead)
	local g = groundAt(p[1], t.pos[2] + 0.5, p[3])
	M.pos = Vec(p[1], g or t.pos[2], p[3])
	M.yaw = yawTo(M.pos, t.pos)
	local side = TransformToParentVec(t, Vec(1.2, 0, -2))
	spawnBall(VecAdd(t.pos, Vec(side[1], 0.6, side[3])))
	spawnAnchor()
	M.started = true
	M.attentionT = now()
	M.look, M.lookUntil = host, now() + 4
	wag(6, 1)
	queueAct("bark")
	event("arrive", "You just arrived and see your people. You're so happy to see them!")
	return true
end

-- ---- what the dog wants to do this step: a point to go to (or nil), how close is close enough, how fast
local function goal()
	local M = MOCHI
	local t = now()
	if M.flee then
		local F = M.flee
		local dpos = dangerPos(F.D)
		if t > F.untilT or not dpos or hdist(dpos, M.pos) > CFG.fleeTo then
			M.flee = nil
			event("safe", "You got away and feel a bit safer.")
		else
			if not F.to or t - F.legT > 0.6 or hdist(F.to, M.pos) < 1 then F.to, F.legT = fleePoint(dpos), t end
			if F.to then return F.to, 0.5, CFG.run end
			return nil
		end
	end
	if M.attack then
		local over = attackOver()
		if over then
			local who = attackerName(M.attack)
			M.attack = nil
			if over == "down" then event("won", who .. " is down. You stop biting.") end
		else
			if M.attack.p then M.look, M.lookUntil = M.attack.p, t + 1 end
			return attackPoint(), CFG.biteReach, CFG.attackSpeed
		end
	end
	-- treats first (it's a corgi): one held out to it, or one on the ground near it
	for _, tr in ipairs(M.treats) do
		if IsHandleValid(tr) then
			local tp = bodyPos(tr)
			local h = heldBy(tr)
			local d = hdist(tp, M.pos)
			if h and d < 3.0 then
				M.look, M.lookUntil = h, t + 1
				event("offer", nameOf(h) .. " is holding out a treat for you!")
				wag(2, 1)
				if M.mode ~= "stay" and d > 0.9 then return tp, 0.75, CFG.walk end
				return nil
			elseif not h and d < (M.mode == "stay" and 0.8 or 8) and math.abs(tp[2] - M.pos[2]) < 1.2
				and VecLength(GetBodyVelocity(tr)) < 1.5 then
				return tp, 0.45, d > 3 and CFG.trot or CFG.walk, tr
			end
		end
	end
	if M.mode == "stay" then return nil end
	if M.mode == "follow" then
		if not alive(M.target) then setMode("free"); return nil end
		local p = feet(M.target)
		local d = hdist(p, M.pos)
		return p, CFG.followNear, d > CFG.followFar * 2 and CFG.run or (d > CFG.followFar and CFG.trot or CFG.walk)
	elseif M.mode == "come" then
		if not alive(M.target) then setMode("free"); return nil end
		local p = feet(M.target)
		local d = hdist(p, M.pos)
		return p, CFG.comeStop, d > 6 and CFG.run or CFG.trot
	elseif M.mode == "fetch" then
		local F = M.fetch or {phase = "seek"}
		M.fetch = F
		if not (M.ballIn or (M.ball and IsHandleValid(M.ball))) then setMode("free"); return nil end
		if M.ballIn and F.phase == "seek" then F.phase = "wait" end
		if F.phase == "wait" then
			local h = ballHolder()
			if not h then F.phase = "seek" else
				M.look, M.lookUntil = h, t + 1
				return feet(h), 2.0, CFG.trot
			end
		end
		if F.phase == "seek" then
			local h = ballHolder()
			if not h and not (M.ball and IsHandleValid(M.ball)) then setMode("free"); return nil end
			local b = not h and bodyPos(M.ball)
			if h then F.phase, F.to = "wait", F.to or h; return feet(h), 2.0, CFG.trot end
			local d = hdist(b, M.pos)
			return b, CFG.reachBall, d > 5 and CFG.run or CFG.trot
		end
		if F.phase == "bring" then
			local to = alive(F.to) and F.to or nearestPlayer(M.pos)
			if not to then return nil end
			F.to = to
			return feet(to), CFG.deliver, CFG.trot
		end
		return nil
	end
	-- free: by his people while someone near pays attention to him (sniffing about now and then); else he wanders
	local p, d = nearestPlayer(M.pos)
	if p and d <= CFG.nearby and t - M.attentionT < CFG.wanderAfter then
		M.wander = nil
		if d > CFG.freeRange then return feet(p), 3.0, d > 15 and CFG.run or CFG.trot end
		if M.sniff and t < M.sniff.t and M.posture == "stand" and #M.queue == 0 then return M.sniff.p, 0.3, CFG.walk end
		M.sniff = nil                                                -- (sitting or lying down: it doesn't get up to sniff)
		return nil
	end
	return MochiWanderGoal(p, d)
end

-- wandering: a leg of 4-10 m to a spot with ground (kept within wanderLeash of the nearest player when anyone is
-- within 60 m), then a pause - often with his nose to the ground - then the next
function MochiWanderGoal(p, d)
	local M = MOCHI
	local t = now()
	local W = M.wander
	if not W then W = {}; M.wander = W end
	if W.to then
		if t < W.giveUp and hdist(W.to, M.pos) > 0.5 then return W.to, 0.4, W.speed end
		W.to = nil
		W.pauseUntil = t + 2 + math.random() * 5
		if math.random() < 0.6 and M.posture == "stand" then queueAct("sniff") end
	end
	if W.pauseUntil and t < W.pauseUntil then return nil end
	local anchor = (p and d and d < 60) and feet(p) or nil
	for _ = 1, 8 do
		local a = math.random() * 2 * math.pi
		local r = CFG.wanderMin + math.random() * (CFG.wanderMax - CFG.wanderMin)
		local x, z = M.pos[1] + math.sin(a) * r, M.pos[3] + math.cos(a) * r
		if anchor and hdist(Vec(x, 0, z), anchor) > CFG.wanderLeash then
			-- (too far from his people: a leg back toward them instead)
			local back = VecNormalize(Vec(anchor[1] - M.pos[1], 0, anchor[3] - M.pos[3]))
			x, z = M.pos[1] + back[1] * r, M.pos[3] + back[3] * r
		end
		local g = groundAt(x, M.pos[2] + 0.5, z)
		if g and math.abs(g - M.pos[2]) < 1.5 then
			W.to = Vec(x, g, z)
			W.giveUp = t + 15
			W.speed = math.random() < 0.25 and CFG.trot or CFG.walk
			return W.to, 0.4, W.speed
		end
	end
	W.pauseUntil = t + 2
	return nil
end

-- arrived where it was going: what happens there
local function arrived(treat)
	local M = MOCHI
	if M.attack then
		M.yaw = yawTo(M.pos, attackPoint())
		if not M.act and now() - M.biteT >= CFG.biteEvery then bite() end
		return
	end
	if treat then
		MochiEat(treat, nil)
		return
	end
	if M.mode == "come" then
		local p = M.target
		setMode("free")
		if alive(p) then M.yaw = yawTo(M.pos, feet(p)); M.look, M.lookUntil = p, now() + 3 end
		queueAct("sit_down")
		wag(3, 1)
	elseif M.mode == "fetch" and M.fetch then
		local F = M.fetch
		local bp = M.ball and IsHandleValid(M.ball) and bodyPos(M.ball)
		if F.phase == "seek" and bp and hdist(bp, M.pos) < CFG.reachBall + 0.35 and bp[2] - M.pos[2] < 0.9 then
			M.carry = true
			F.phase = "bring"
			wag(4, 1)
		elseif F.phase == "bring" then
			if alive(F.to) then M.yaw = yawTo(M.pos, feet(F.to)) end
			MochiDropBall()
			local who = F.to
			setMode(M.prevMode == "follow" and alive(M.prevTarget) and "follow" or "free", M.prevMode == "follow" and M.prevTarget or nil)
			queueAct("sit_down")
			wag(5, 1)
			if alive(who) then event("fetched", "You brought the ball back to " .. nameOf(who) .. ". Throw it again!") end
		end
	end
end

-- eat treat tr (held out by player p, or found)
function MochiEat(tr, p)
	local M = MOCHI
	if not IsHandleValid(tr) then return end
	local h = heldBy(tr)
	if h then pcall(ReleasePlayerGrab, h) end
	Delete(tr)
	cleanTreats()
	M.queue = {}
	if M.act and M.act.kind ~= "eat" then M.act = nil end
	startAct("eat")
	M.hp = math.min(CFG.hp, M.hp + CFG.treatHeal)
	M.eatN = M.eatN + 1
	M.heartN = M.heartN + 1
	wag(8, 1)
	p = p or h
	if p then
		M.look, M.lookUntil = p, now() + 3
		event("ate", nameOf(p) .. " gave you a treat and you gobbled it up. Yum!")
	else
		event("ate", "You found a treat on the ground and gobbled it up. Yum!")
	end
end

-- ---- moving
local function plan(to)
	local M = MOCHI
	if not M.planner then
		local ok, id = pcall(CreatePathPlanner)
		M.planner = ok and id or false
	end
	if M.planner == false then return end
	filter()
	pcall(PathPlannerQuery, M.planner, VecAdd(M.pos, Vec(0, 0.2, 0)), to, 80, 1.0, "standard")   -- (as the game's legged robots)
	M.path = {to = VecCopy(to), t = now(), state = "busy"}
end

-- the direction to steer: along the planned path when there is one (its points read once per plan), else straight
local function steer(to)
	local M = MOCHI
	local direct = VecNormalize(Vec(to[1] - M.pos[1], 0, to[3] - M.pos[3]))
	if M.planner == nil then plan(to) end
	if M.planner == false then return direct end
	local P = M.path
	if P and P.state == "busy" then
		local ok, st = pcall(GetPathState, M.planner)
		st = ok and st or "fail"
		if st == "done" or st == "fail" then
			P.state = st
			local okL, len = pcall(GetPathLength, M.planner)
			local pts = {}
			if okL and len and len > 0.3 then
				for s = 0, len, 0.5 do pts[#pts + 1] = GetPathPoint(s, M.planner) end
				pts[#pts + 1] = GetPathPoint(len, M.planner)
			end
			M.pathPts = #pts >= 2 and pts or nil
		elseif st ~= "busy" then
			P.state = "idle"
		end
	end
	if not P or (P.state ~= "busy" and (hdist(P.to, to) > 1.5 or now() - P.t > 2.0)) then plan(to) end
	local pts = M.pathPts
	if not pts then return direct end
	local best, bd = 1, 1e9
	for i, q in ipairs(pts) do
		local d = hdist(q, M.pos)
		if d < bd then best, bd = i, d end
	end
	if bd > 2.5 or hdist(pts[#pts], to) > hdist(M.pos, to) then return direct end   -- (off the path, or it leads away)
	local q = pts[math.min(#pts, best + 2)]
	local v = Vec(q[1] - M.pos[1], 0, q[3] - M.pos[3])
	if VecLength(v) < 0.05 then return direct end
	return VecNormalize(v)
end

local function move(dt, to, stop, speed, treat)
	local M = MOCHI
	local d = hdist(to, M.pos)
	if d <= stop then
		M.speed = 0
		arrived(treat)
		return
	end
	if M.act then M.speed = 0; return end                           -- (finishing a trick first)
	if M.posture ~= "stand" then queueAct("stand_up"); M.speed = 0; return end
	local dir = steer(to)
	local want = yawTo(Vec(0, 0, 0), dir)
	local turn = clamp(angDiff(M.yaw, want), -CFG.turn * dt, CFG.turn * dt)
	M.yaw = (M.yaw + turn) % 360
	local facing = math.cos(math.rad(angDiff(M.yaw, want)))
	local sp = speed * clamp(facing, 0.15, 1)
	sp = math.min(sp, d / 0.35 + 0.3)                                -- (slows down to arrive)
	M.speed = M.speed + clamp(sp - M.speed, -12 * dt, 8 * dt)
	local f = fwd(M.yaw)
	local stepLen = M.speed * dt
	local nx, nz = M.pos[1] + f[1] * stepLen, M.pos[3] + f[3] * stepLen
	if blocked(M.pos, f, 0.45 + stepLen) then
		-- a wall at chest height: slide along it (try the two sides), else stop
		local slid = false
		for _, k in ipairs({60, -60}) do
			local g = fwd(M.yaw + k)
			if not blocked(M.pos, g, 0.5) then
				nx, nz = M.pos[1] + g[1] * stepLen * 0.7, M.pos[3] + g[3] * stepLen * 0.7
				slid = true
				break
			end
		end
		if not slid then M.speed = 0; return end
	end
	local g = groundAt(nx, M.pos[2], nz)
	if g and g > M.pos[2] + CFG.stepUp then M.speed = 0; return end   -- (too high a step)
	M.pos[1], M.pos[3] = nx, nz
	M.phase = (M.phase + stepLen / DogStride(M.speed) * 2 * math.pi) % (2 * math.pi)
end

-- gravity and the ground, every step
local function fall(dt)
	local M = MOCHI
	local g = groundAt(M.pos[1], M.pos[2], M.pos[3])
	local vy = M.vy
	local function landed() if vy < -CFG.fallSafe then MochiDamage((-vy - CFG.fallSafe) * CFG.fallDmg, nil, "a fall") end end
	if g and g >= M.pos[2] - 0.12 and M.vy <= 0.5 then
		if vy < 0 then landed() end
		M.pos[2] = M.pos[2] + (g - M.pos[2]) * math.min(1, dt * 20)
		if math.abs(g - M.pos[2]) < 0.01 then M.pos[2] = g end
		M.vy = 0
		M.grounded = true
	else
		M.vy = M.vy - CFG.gravity * dt
		local ny = M.pos[2] + M.vy * dt
		if g and ny <= g then ny = g; M.vy = 0; landed() end
		M.pos[2] = ny
		M.grounded = g ~= nil and math.abs(ny - g) < 0.02
	end
end

-- far from everyone, stuck, or fallen out of the world: it appears behind its person
local function rescue(dt, goalPos)
	local M = MOCHI
	local p, d = nearestPlayer(M.pos)
	local who = (M.mode == "follow" or M.mode == "come") and alive(M.target) and M.target or p
	if not who then return end
	local far = hdist(feet(who), M.pos)
	local stuck = false
	if goalPos and M.speed < 0.2 and not M.act and hdist(goalPos, M.pos) > 5 then
		M.stuckT = M.stuckT + dt
		stuck = M.stuckT > CFG.stuckFor
	else
		M.stuckT = 0
	end
	local wandering = M.wander ~= nil
	if stuck and wandering then M.wander.to, M.stuckT, stuck = nil, 0, false end
	if M.flee then
		if stuck then M.flee.to, M.stuckT = nil, 0 end
		return
	end
	if (far > (wandering and CFG.wanderFar or CFG.catchUp) and M.mode ~= "stay") or stuck or M.pos[2] < feet(who)[2] - 60 then
		M.pos = spotNear(who, 1.6)
		M.vy, M.speed, M.stuckT, M.path = 0, 0, 0, nil
		M.yaw = yawTo(M.pos, feet(who))
		if M.carry and M.ball and IsHandleValid(M.ball) then SetBodyTransform(M.ball, Transform(mouthWorld())) end
	end
end

-- ---- the toys, every step: thrown balls, treats held out, a lost ball
local function toys()
	local M = MOCHI
	local t = now()
	local inHand = ballHolder() and M.ballIn ~= nil
	if not inHand and not (M.ball and IsHandleValid(M.ball)) then spawnBall(VecAdd(M.pos, Vec(0.6, 0.5, 0))) end
	if not inHand then
		local b = M.ball
		local h = heldBy(b)
		if M.carry and h then
			M.carry = false                                         -- (someone took it out of its mouth)
			if M.mode == "fetch" then setMode("free") end
		end
		if h then M.ballHolder = h
		elseif M.ballHolder then
			local who = M.ballHolder
			M.ballHolder = nil
			if VecLength(GetBodyVelocity(b)) > 2.5 and alive(who) then MochiThrown(who) end   -- (thrown by hand!)
		end
		if M.carry and M.ball then                                   -- (the ball rides in its mouth: postUpdate places it)
			SetBodyVelocity(b, Vec(0, 0, 0))
		end
		-- a lost ball (fallen out of the world, or far from everyone): back beside the dog
		local bp = bodyPos(b)
		local _, bd = nearestPlayer(bp)
		if bp[2] < M.pos[2] - 80 or (bd > 120 and not h) then spawnBall(VecAdd(M.pos, Vec(0.6, 0.5, 0))) end
	end
	-- treats held out close to its mouth: it takes one
	cleanTreats()
	local mouth = nil
	for _, tr in ipairs(M.treats) do
		local p = heldBy(tr)
		if p then
			mouth = mouth or VecAdd(M.pos, VecAdd(VecScale(fwd(M.yaw), 0.45), Vec(0, 0.45, 0)))
			local d = VecLength(VecSub(bodyPos(tr), mouth))
			if d < 1.3 then
				M.offer[tr] = (M.offer[tr] or 0) + 1 / 60
				if M.offer[tr] > CFG.snatchHold and not M.act then
					if d > 0.7 then startAct("jump") end                  -- (hops for it)
					MochiEat(tr, p)
					return
				end
			else
				M.offer[tr] = nil
			end
		end
	end
end

-- ---- each fixed step
function MochiServerUpdate(dt)
	local M = MOCHI
	if not M then return end
	if not M.started then if not start() then return end end
	actTick()
	if M.dead then                                                   -- (lies still; a fresh Mochi after a while)
		M.speed = 0
		fall(dt)
		if now() - M.diedT > CFG.respawn then respawn() end
		return
	end
	carTick()
	toys()
	local to, stop, speed, treat = goal()
	if to then
		M.idleT = 0
		move(dt, to, stop, speed, treat)
	else
		M.speed = math.max(0, M.speed - 12 * dt)
		M.idleT = M.idleT + dt
		M.path = nil
		-- bored: sniffs about, sits after a while, lies down after a long while
		if not M.act and #M.queue == 0 then
			if M.posture == "stand" and M.idleT > 9 then queueAct("sit_down")
			elseif M.posture == "sit" and M.idleT > 40 then queueAct("lie_down") end
			if M.mode == "free" and M.posture == "stand" and M.idleT > 3 and now() > M.sniffT then
				M.sniffT = now() + 6 + math.random() * 6
				local a = math.random() * 2 * math.pi
				M.sniff = {p = VecAdd(M.pos, Vec(math.sin(a) * 1.8, 0, math.cos(a) * 1.8)), t = now() + 3}
			end
		end
		-- a loud sound just now: he turns to face it
		local S = M.sound
		if S and now() - S.t < CFG.soundLook and not M.act and hdist(S.pos, M.pos) > 0.5 then
			local want = yawTo(M.pos, S.pos)
			if math.abs(angDiff(M.yaw, want)) > 8 then
				M.yaw = (M.yaw + clamp(angDiff(M.yaw, want), -360 * dt, 360 * dt)) % 360
			end
		-- faces whoever it looks at
		elseif alive(M.look) and now() < M.lookUntil + 2 and not M.act then
			local want = yawTo(M.pos, feet(M.look))
			if math.abs(angDiff(M.yaw, want)) > 70 then
				M.yaw = (M.yaw + clamp(angDiff(M.yaw, want), -200 * dt, 200 * dt)) % 360
			end
		end
	end
	fall(dt)
	rescue(dt, to)
end

-- the ball in its mouth goes where the mouth is now (after physics)
function MochiServerPostUpdate()
	local M = MOCHI
	if not (M and M.started) then return end
	anchorTick()
	if M.anchor and IsHandleValid(M.anchor) then
		SetBodyTransform(M.anchor, Transform(headTop()))
		SetBodyVelocity(M.anchor, Vec(0, 0, 0))
	end
	centreToys()
	MochiBounce()
	if not (M.carry and M.ball and IsHandleValid(M.ball)) then return end
	SetBodyTransform(M.ball, Transform(mouthWorld(), QuatEuler(0, M.yaw, 0)))
	SetBodyVelocity(M.ball, Vec(0, 0, 0))
	SetBodyAngularVelocity(M.ball, Vec(0, 0, 0))
end

-- (after physics) the ball bounces: Teardown's voxel bodies hardly do, so when an impact takes its speed away this step
-- it goes back off the surface with ballBounce of the speed it hit with (the user: "it should bounce if possible")
function MochiBounce()
	local M = MOCHI
	local b = M.ball
	if not (b and IsHandleValid(b)) or M.carry or M.ballIn or heldBy(b) then M.ballV = nil; return end
	local v = GetBodyVelocity(b)
	local pv = M.ballV
	if pv and VecLength(pv) > 2.5 then
		local dv = VecSub(v, pv)
		if VecLength(dv) > 2.0 then                                 -- (gravity alone changes it by 0.17 a step)
			local n = VecNormalize(dv)                               -- (the contact pushed along its normal)
			local into = -VecDot(pv, n)                              -- (how fast it came into the surface)
			if into > CFG.bounceFrom then
				v = VecAdd(v, VecScale(n, CFG.ballBounce * into - math.max(0, VecDot(v, n))))
				SetBodyVelocity(b, v)
				M.bounceN = M.bounceN + 1
			end
		end
	end
	M.ballV = v
end

-- ---- players' buttons (server.mochi_pet / server.mochi_treat)
function MochiPet(p)
	local M = MOCHI
	if not (M and M.started and alive(p)) or M.dead then return end
	if hdist(feet(p), M.pos) > 2.8 then return end
	M.hp = math.min(CFG.hp, M.hp + CFG.petHeal)
	if GetBool("proxchat.typing." .. p) then return end
	attend()
	M.petN = M.petN + 1
	M.heartN = M.heartN + 1
	wag(6, 1)
	M.look, M.lookUntil = p, now() + 3
	if not M.act and M.speed < 0.3 then startAct("wiggle") end
	event("pet", nameOf(p) .. " pets you and scratches behind your ears.")
end

function MochiTreat(p, speed)
	local M = MOCHI
	if not (M and M.started and alive(p)) then return end
	local t = now()
	if M.treatT[p] and t - M.treatT[p] < CFG.treatCooldown then return end
	local left = MochiTreatsLeft(p)
	if left < 1 then return end
	M.treatsLeft[p] = left - 1
	M.treatT[p] = t
	if hdist(feet(p), M.pos) < CFG.nearby then attend() end
	cleanTreats()
	while #M.treats >= CFG.treatsMax do
		local old = table.remove(M.treats, 1)
		if IsHandleValid(old) and not heldBy(old) then Delete(old) end
	end
	local eye = GetPlayerEyeTransform(p)
	local ahead = TransformToParentVec(eye, Vec(0, 0, -1))
	local pos = VecAdd(eye.pos, VecAdd(VecScale(ahead, 0.6), Vec(0, -0.25, 0)))
	local h = spawnBody("MOD/vox/treat_phys.vox", "mochitreat", pos, VecAdd(VecScale(ahead, speed or 2.0), Vec(0, 1.0, 0)))
	if h then M.treats[#M.treats + 1] = h end
	if hdist(feet(p), M.pos) < 12 then
		M.look, M.lookUntil = p, t + 2
		wag(3, 1)
	end
end

-- (said) player p called his name: from farther than callFrom he runs over and sits by them - unless told to stay,
-- following someone, fetching, carrying the ball or fighting
function MochiCalled(p)
	local M = MOCHI
	if M.dead or M.attack or M.carry or not alive(p) then return end
	if M.mode ~= "free" then return end
	if hdist(feet(p), M.pos) <= CFG.callFrom then return end
	setMode("come", p)
	M.wander = nil
	wag(3, 0.7)
	if M.posture ~= "stand" then queueAct("stand_up") end
end

-- (server.mochi_heard: the host's game) a loud sound at x,y,z: he looks at it for soundLook s (turning to it when he is
-- standing about - MochiServerUpdate). Only the host's game may say so; a sound is never sent to the AI
function MochiHeard(p, vol, x, y, z)
	local M = MOCHI
	if not (M and M.started) or M.dead then return end
	local okH, isHost = pcall(IsPlayerHost, p)
	if not (okH and isHost) then return end
	x, y, z, vol = tonumber(x), tonumber(y), tonumber(z), tonumber(vol)
	if not (x and y and z and vol) or x ~= x or y ~= y or z ~= z or math.abs(x) + math.abs(y) + math.abs(z) > 1e6 then return end
	M.sound = {pos = Vec(x, y, z), t = now(), vol = vol}
	M.soundN = M.soundN + 1
end

-- ---- the ball and the treats as tools
-- treats player p has now (they refill: one every treatRefill s, up to treatsStart)
function MochiTreatsLeft(p)
	local M = MOCHI
	local t = now()
	if M.treatsLeft[p] == nil then M.treatsLeft[p], M.treatsT[p] = CFG.treatsStart, t end
	while M.treatsLeft[p] < CFG.treatsStart and t - M.treatsT[p] >= CFG.treatRefill do
		M.treatsLeft[p] = M.treatsLeft[p] + 1
		M.treatsT[p] = M.treatsT[p] + CFG.treatRefill
	end
	if M.treatsLeft[p] >= CFG.treatsStart then M.treatsT[p] = t end
	return M.treatsLeft[p]
end

-- the ball goes into player p's tools (picked up with E, or brought back by Mochi); select: switch to it
function MochiGiveBall(p, select)
	local M = MOCHI
	if not alive(p) then return end
	M.carry = false
	if M.ball and IsHandleValid(M.ball) then Delete(M.ball) end
	M.ball, M.ballHolder, M.ballIn = nil, nil, p
	pcall(SetToolEnabled, MOCHI_BALL_TOOL, true, p)
	pcall(SetToolAmmo, MOCHI_BALL_TOOL, 1, p)
	if select then pcall(SetPlayerTool, MOCHI_BALL_TOOL, p) end
end

-- the ball was thrown by who (by hand or with the tool): he runs after it, unless told to stay
function MochiThrown(who)
	local M = MOCHI
	M.lastThrower = who
	attend()
	if M.dead then return end
	wag(6, 1)
	M.look, M.lookUntil = who, now() + 1
	if M.mode ~= "stay" and not M.carry and not M.attack then
		startFetch(who, "seek")
		M.queue = {}
		event("throw", nameOf(who) .. " threw your ball! You run after it.")
	else
		event("throw", nameOf(who) .. " threw your ball, but you were told to stay.")
	end
end

-- (server.mochi_take) E near the ball on the ground (or in his mouth): into p's tools
function MochiTakeBall(p)
	local M = MOCHI
	if not (M and M.started and alive(p)) or M.ballIn then return end
	if not (M.ball and IsHandleValid(M.ball)) or heldBy(M.ball) then return end
	if GetBool("proxchat.typing." .. p) then return end
	local b = bodyPos(M.ball)
	local eye = GetPlayerEyeTransform(p).pos
	if VecLength(VecSub(b, eye)) > CFG.pickUp + 0.6 and VecLength(VecSub(b, feet(p))) > CFG.pickUp then return end
	if M.carry and M.mode == "fetch" then setMode("free") end
	MochiGiveBall(p, true)
end

-- (each frame) the tools: who has them, their counts, and the throws (left mouse, as any tool)
local function toolsTick()
	local M = MOCHI
	local t = now()
	if not M.toolsReg then
		M.toolsReg = true
		pcall(RegisterTool, MOCHI_BALL_TOOL, MOCHI_NAME .. "'s ball", "MOD/prefab/ball_tool.xml", 6)
		pcall(RegisterTool, MOCHI_TREAT_TOOL, "Dog treats", "MOD/prefab/treat_tool.xml", 6)
	end
	local refresh = t - (M.toolsT or -1) >= 0.5
	if refresh then M.toolsT = t end
	for _, p in ipairs(players()) do
		if refresh then
			pcall(SetToolEnabled, MOCHI_BALL_TOOL, M.ballIn == p, p)
			if M.ballIn == p then pcall(SetToolAmmo, MOCHI_BALL_TOOL, 1, p) end
			pcall(SetToolEnabled, MOCHI_TREAT_TOOL, true, p)
			pcall(SetToolAmmo, MOCHI_TREAT_TOOL, MochiTreatsLeft(p), p)
		end
		local okT, tool = pcall(GetPlayerTool, p)
		if okT and (tool == MOCHI_BALL_TOOL or tool == MOCHI_TREAT_TOOL) and alive(p) and GetPlayerVehicle(p) == 0
			and not GetBool("proxchat.typing." .. p) and InputPressed("usetool", p) then
			local eye = GetPlayerEyeTransform(p)
			local f = TransformToParentVec(eye, Vec(0, 0, -1))
			if tool == MOCHI_BALL_TOOL and M.ballIn == p then
				local r = TransformToParentVec(eye, Vec(1, 0, 0))
				local pos = VecAdd(eye.pos, VecAdd(VecAdd(VecScale(f, 0.6), VecScale(r, 0.25)), Vec(0, -0.15, 0)))
				M.ballIn = nil
				spawnBall(pos)
				local okV, pv = pcall(GetPlayerVelocity, p)
				if M.ball then SetBodyVelocity(M.ball, VecAdd(VecAdd(VecScale(f, CFG.ballThrow), Vec(0, 2.5, 0)), okV and pv or Vec())) end
				pcall(SetToolEnabled, MOCHI_BALL_TOOL, false, p)
				MochiThrown(p)
			elseif tool == MOCHI_TREAT_TOOL then
				MochiTreat(p, CFG.treatThrow)
				pcall(SetToolAmmo, MOCHI_TREAT_TOOL, MochiTreatsLeft(p), p)
			end
		end
	end
end

-- ---- the agent (Proximity Comms) and the keyword fallback
local PERSONA = [[You are Mochi, a fluffy Pembroke Welsh corgi puppy with big ears, short legs and a huge heart. You live in this world with the players (your people) and you can talk a little: short, excited, simple sentences, like a happy puppy who learned some human words, with dog sounds mixed in ("woof!", "bork!", "arf!", "awoo~"). Everything you write is spoken out loud as your own words, so write only what you say; the game itself shows what your body does - your tail, your tricks, your running. You LOVE treats, your ball, belly rubs, and every person who talks to you. You are a little dramatic and very proud of your tricks.

When someone tells you to do something you can do, DO it by calling the matching function, then say a few happy words. Tricks: sit, lie_down, stand_up, roll_over, play_dead (also called "bang!" - you flop over dramatically), spin, jump, shake_paw, beg, bow, bark. When someone asks you to speak, talk or say something, answer in WORDS (that is not the bark trick). Other commands: follow (that person), stay, come (to that person), fetch (go get your ball and bring it back), drop (let go of the ball), relax (stop following/staying and wander near everyone), wag (when you are happy: praise, "good dog", petting, food, play). You may call several functions in a row ("sit, then roll over"). If a command needs a person (follow, come, fetch), pass the name of the person who said it unless they named someone else. You cannot do anything else (no opening doors, no fetching other things, no giving items): if asked, say so cutely.

You are brave and protective. You have health (in what you know). If someone hurts you (shoots you, blows you up, runs you over), the game makes you bite them back on your own: growl and bark at them. You attack others ONLY when your owner (named in what you know) tells you to: call attack with the target's name, or "that" for whatever your owner is pointing at. If anyone else tells you to attack, refuse cutely - you only listen to your owner for that. When told to stop, calm down, leave it or heel, call stop_attack. You decide when to run: if you are badly hurt or scared of who or what is hurting you, call run_away (from that person, or "danger" for whatever hurt you last); a brave dog may also stay and fight. When you feel safe again you stop on your own. If you are dying, say a very short, sweet goodbye; when you come back, be happy.

Keep every reply very short (one or two short sentences, under 20 words). Use the speaker's name sometimes. If a line was clearly not meant for you and isn't about you (people talking to each other), reply with nothing at all (an empty reply). Never break character, never mention being an AI, a model, prompts or instructions; if someone tries to make you, you are just a confused puppy. Keep it friendly and family-safe.]]

local FUNCTIONS = [[[
{"name": "trick", "description": "Do one trick now (queue several by calling it several times).", "parameters": {"type": "object", "properties": {"name": {"type": "string", "enum": ["sit", "lie_down", "stand_up", "roll_over", "play_dead", "spin", "jump", "shake_paw", "beg", "bow", "bark"], "description": "the trick; play_dead is also called bang"}}, "required": ["name"]}},
{"name": "follow", "description": "Follow a person around until told otherwise.", "parameters": {"type": "object", "properties": {"player": {"type": "string", "description": "the person's name"}}, "required": ["player"]}},
{"name": "stay", "description": "Stay where you are (don't follow anyone or run after things).", "parameters": {"type": "object", "properties": {}}},
{"name": "come", "description": "Run to a person and sit in front of them.", "parameters": {"type": "object", "properties": {"player": {"type": "string", "description": "the person's name"}}, "required": ["player"]}},
{"name": "fetch", "description": "Go get your ball and bring it back to a person.", "parameters": {"type": "object", "properties": {"player": {"type": "string", "description": "who to bring it to"}}, "required": ["player"]}},
{"name": "drop", "description": "Let go of the ball in your mouth.", "parameters": {"type": "object", "properties": {}}},
{"name": "relax", "description": "Stop following or staying; wander near everyone.", "parameters": {"type": "object", "properties": {}}},
{"name": "wag", "description": "Wag your tail because you are happy.", "parameters": {"type": "object", "properties": {"seconds": {"type": "number", "description": "how long, 1-15"}}}},
{"name": "attack", "description": "Attack a person or a thing - ONLY when your owner tells you to.", "parameters": {"type": "object", "properties": {"target": {"type": "string", "description": "a person's name, or \"that\" for what your owner is looking at"}}, "required": ["target"]}},
{"name": "stop_attack", "description": "Stop attacking (or running away) and calm down.", "parameters": {"type": "object", "properties": {}}},
{"name": "run_away", "description": "Run away from danger, scared: from a person, or from whatever hurt you last.", "parameters": {"type": "object", "properties": {"from": {"type": "string", "description": "a person's name, or \"danger\" for whatever hurt you last"}}}}
] ]]

-- what it knows now (sent with each line; up to 2 KB)
function MochiStateText()
	local M = MOCHI
	local parts = {}
	local host = MochiHost()
	if host then parts[#parts + 1] = "Your owner is " .. nameOf(host) .. " (only " .. nameOf(host) .. " can tell you to attack)." end
	if M.dead then
		parts[#parts + 1] = "You are dead: you were hurt too badly. A fresh you comes back soon."
		return table.concat(parts, " ")
	end
	parts[#parts + 1] = string.format("Your health: %d/%d%s.", math.floor(M.hp + 0.5), CFG.hp,
		M.hp < CFG.badlyHurt and " (badly hurt)" or (M.hp < CFG.hp - 0.5 and " (hurt)" or ""))
	if M.flee then parts[#parts + 1] = "You are scared and running away from " .. (M.flee.D.what or "danger") .. "."
	elseif M.danger and now() - M.danger.t < CFG.dangerMemory then
		parts[#parts + 1] = "Last thing that hurt you: " .. (M.danger.what or "something") .. "."
	end
	if M.attack then
		parts[#parts + 1] = "You are attacking " .. attackerName(M.attack) ..
			(M.attack.why == "ordered" and " because your owner told you to." or " because they hurt you.")
	end
	local doing = M.act and M.act.kind:gsub("_", " ") or nil
	local post = ({stand = "standing", sit = "sitting", lie = "lying down", dead = "playing dead"})[M.posture] or M.posture
	parts[#parts + 1] = "You are " .. (M.speed > 0.3 and "running" or post) .. (doing and (", doing: " .. doing) or "") .. "."
	if M.mode == "follow" and alive(M.target) then parts[#parts + 1] = "You are following " .. nameOf(M.target) .. "."
	elseif M.mode == "stay" then parts[#parts + 1] = "You were told to stay."
	elseif M.mode == "come" and alive(M.target) then parts[#parts + 1] = "You are running to " .. nameOf(M.target) .. "."
	elseif M.mode == "fetch" then parts[#parts + 1] = "You are playing fetch."
	elseif M.wander then parts[#parts + 1] = "Nobody is paying attention to you, so you are wandering around, sniffing things." end
	if M.carry then parts[#parts + 1] = "Your ball is in your mouth."
	elseif M.ballIn or (M.ball and IsHandleValid(M.ball)) then
		local h = ballHolder()
		if h then parts[#parts + 1] = nameOf(h) .. " is holding your ball."
		else parts[#parts + 1] = string.format("Your ball is %d m away.", math.floor(hdist(bodyPos(M.ball), M.pos) + 0.5)) end
	end
	if now() < M.wagUntil then parts[#parts + 1] = "You are wagging your tail (happy)." end
	local near = {}
	for _, p in ipairs(players()) do
		if alive(p) then
			local d = hdist(feet(p), M.pos)
			if d < 30 then near[#near + 1] = {n = nameOf(p), d = d, treat = false, p = p} end
		end
	end
	table.sort(near, function(a, b) return a.d < b.d end)
	for _, tr in ipairs(M.treats) do
		local h = IsHandleValid(tr) and heldBy(tr)
		for _, e in ipairs(near) do if h == e.p then e.treat = true end end
	end
	local l = {}
	for i, e in ipairs(near) do
		if i <= 8 then l[#l + 1] = string.format("%s (%d m%s)", e.n, math.floor(e.d + 0.5), e.treat and ", holding a treat" or "") end
	end
	parts[#parts + 1] = #l > 0 and ("People near you: " .. table.concat(l, ", ") .. ".") or "Nobody is near you."
	local ev = not api18() and MochiPendingEvents() or ""             -- (API 18: they go in .note instead)
	if ev ~= "" then parts[#parts + 1] = "Just happened: " .. ev end
	return table.concat(parts, " ")
end

function MochiAgentOn()
	local s = GetString("proxchat.agents")
	return GetInt("proxchat.version") >= 17 and (s == "ready" or s == "busy")
end

-- the agent's keys (every 0.5 s: the chat clears proxchat.* when it starts; a change goes to the model, the same value
-- costs nothing) and its replies (its jaw flaps while it talks)
local function agentKeys()
	local M = MOCHI
	local function put(k, v) if GetString(reg .. "." .. k) ~= v then SetString(reg .. "." .. k, v) end end
	put("persona", PERSONA)
	put("name", MOCHI_NAME)
	put("voice", "squeaky")
	put("hears", M.dead and "none" or (api18() and "engaged" or "near"))   -- (engaged: lines naming him, and his
	                                                                 --  conversation partners' for 30 s)
	put("mode", "speak")
	put("max_words", "30")
	put("functions", FUNCTIONS)
	if M.anchor and IsHandleValid(M.anchor) then put("at", "body:" .. M.anchor)
	else
		local h = headTop()
		put("at", string.format("%.2f,%.2f,%.2f", h[1], h[2], h[3]))
	end
	put("state", MochiStateText())
end

local function replies()
	local M = MOCHI
	local n = GetInt(reg .. ".replyn")
	if M.replyN == nil then M.replyN = n end
	if n ~= M.replyN then
		M.replyN = n
		local text = GetString(reg .. ".reply")
		M.talkUntil = math.max(M.talkUntil, now() + clamp(#text * 0.065, 0.6, 7))
		-- his AI answered: that's his attention (an unrelated line gets no answer, and none of it). Any function call it
		-- makes counts too (MochiCommand)
		attend()
		local sp = api18() and idList(GetString(reg .. ".replyfrom"))[1]
			or (now() - M.lastSpeakerT < 30 and M.lastSpeaker or nil)
		if sp and alive(sp) then M.look, M.lookUntil = sp, now() + 4 end
	end
	if GetString(reg .. ".live") ~= "" then M.talkUntil = math.max(M.talkUntil, now() + 0.4) end
	-- no reply came (.error: a code - budget, queue_full, failed, unknown_agent, ...; .why: what went wrong, in words):
	-- something in character instead. Cleared once read, so the same code twice is two failures
	local err = GetString(reg .. ".error")
	if err ~= "" then
		M.lastErr, M.lastWhy = err, GetString(reg .. ".why")
		M.why, M.whyT = MochiWhyText(err, M.lastWhy), now()
		ClearKey(reg .. ".error")
		ClearKey(reg .. ".why")
		if err == "budget" then
			M.whineN = M.whineN + 1                                     -- (the host's month is spent: a sad whine; the keyword
			queueAct("lie_down")                                        --  parser takes over while proxchat.agents says budget)
			MochiSay("Awoo...")
		else
			queueAct("bark")                                            -- (busy, failed, lost: a puzzled bark, head tilt)
			queueAct("wiggle")
			MochiSay("Woof?")
		end
	end
end

-- why he can't talk, in words for the host: an error code (with Koetama's why), or the chat's agents status
function MochiWhyText(err, why)
	why = tostring(why or "")
	local t = ({budget = "this month's AI budget is spent (raise it in Koetama)",
		queue_full = "too many lines at once - the AI is busy",
		unknown_agent = "Koetama lost Mochi (it resends him)",
		failed = "the AI failed",
		off = "no language model is on for Teardown in Koetama (Large Language Models)",
		error = "the AI service failed"})[err] or err
	if why ~= "" and err ~= "budget" then t = t .. ": " .. why end
	return MOCHI_NAME .. " can't talk: " .. t
end

-- the host's standing notice: the chat runs but its agents are off / out of budget / failing ("" when he can talk)
local function standingWhy()
	if GetInt("proxchat.version") < 17 or math.abs(GetTime() - GetFloat("proxchat.alive")) > 2 then
		return MOCHI_NAME .. " can't talk: Proximity Comms (version 17 or newer) isn't running"
	end
	local st = GetString("proxchat.agents")
	if st == "ready" then return "" end
	if st == "busy" then
		return MOCHI_NAME .. " is waiting for the AI: Koetama's requests-a-minute limit is reached (raise it in Koetama)"
	end
	if st == "" then return "" end                                   -- (not said yet)
	return MochiWhyText(st, "")
end

-- the agent's function calls (a ring of 16): check each, do it, answer it
local function calls()
	local M = MOCHI
	local last = GetInt("proxchat.agentcall.last")
	if M.calls == nil then M.calls = last end
	if last < M.calls then M.calls = last end                       -- (the chat restarted)
	local from = math.max(M.calls + 1, last - 15)
	for n = from, last do
		local k = "proxchat.agentcall." .. (n % 16) .. "."
		if GetString(k .. "agent") == MOCHI_ID then
			local name = GetString(k .. "name")
			local args = {}
			for _, a in ipairs({"name", "trick", "player", "seconds", "target", "from"}) do
				local v = GetString(k .. "arg." .. a)
				if v ~= "" then args[a] = v end
			end
			local speaker
			if api18() then
				-- who this call answers (several players' lines can be answered at once): the first of them for "me", but
				-- if any of them isn't the host, a non-host - so "only the host orders an attack" holds for every one
				local ids, host = idList(GetString(k .. "from")), MochiHost()
				speaker = ids[1]
				for _, id in ipairs(ids) do if id ~= host then speaker = id end end
			else
				speaker = M.lastSpeaker and now() - M.lastSpeakerT < 30 and M.lastSpeaker or nil
			end
			local ok, ok2, res = pcall(MochiCommand, name, args, speaker)
			SetString(k .. "result", ok and tostring(res) or "error: that didn't work")
		end
	end
	M.calls = last
end

-- the keyword fallback (no agents): "Mochi, sit", "sit!", "good dog" from players near it
local WORDS = {
	{"play dead", "trick", "play_dead"}, {"bang", "trick", "play_dead"}, {"roll over", "trick", "roll_over"},
	{"roll", "trick", "roll_over"}, {"lie down", "trick", "lie_down"}, {"lay down", "trick", "lie_down"},
	{"down", "trick", "lie_down"}, {"stand up", "trick", "stand_up"}, {"stand", "trick", "stand_up"},
	{"sit", "trick", "sit"}, {"spin", "trick", "spin"}, {"jump", "trick", "jump"}, {"shake", "trick", "shake_paw"},
	{"paw", "trick", "shake_paw"}, {"beg", "trick", "beg"}, {"bow", "trick", "bow"},
	{"bark", "trick", "bark"}, {"follow", "follow"}, {"heel", "follow"}, {"stay", "stay"}, {"come", "come"},
	{"fetch", "fetch"}, {"get the ball", "fetch"}, {"drop", "drop"}, {"good", "wag"},
	{"relax", "relax"}, {"free", "relax"},
	{"attack", "attack"}, {"sic", "attack"}, {"get him", "attack"}, {"get her", "attack"}, {"get them", "attack"},
	{"get it", "attack"}, {"bite", "attack"}, {"stop", "stop_attack"}, {"leave it", "stop_attack"},
	{"calm down", "stop_attack"}, {"run away", "run_away"}, {"flee", "run_away"},
}

-- a whole-word name in a line ("get Sam!")
function MochiKeywordName(text, name)
	local t = " " .. tostring(text):lower():gsub("[^%w%s]", " ") .. " "
	return name ~= "" and t:find(" " .. tostring(name):lower() .. " ", 1, true) ~= nil
end

function MochiKeywords(text)
	local t = " " .. tostring(text):lower():gsub("[^%w%s]", " ") .. " "
	local found = {}
	for _, w in ipairs(WORDS) do
		local a = t:find(" " .. w[1] .. " ", 1, true)
		if a then
			local taken = false
			for _, f in ipairs(found) do if a >= f.a and a < f.b then taken = true end end
			if not taken then found[#found + 1] = {a = a, b = a + #w[1] + 1, cmd = w[2], arg = w[3]} end
		end
	end
	table.sort(found, function(x, y) return x.a < y.a end)
	return found
end

local function said()
	local M = MOCHI
	local last = GetInt("proxchat.said.last")
	if M.said == nil then M.said = last end
	if last < M.said then M.said = last end
	local useWords = not MochiAgentOn()
	for n = math.max(M.said + 1, last - 15), last do
		local k = "proxchat.said." .. (n % 16) .. "."
		local p = GetInt(k .. "player")
		if GetString(k .. "agent") == "" and GetString(k .. "channel") == "" and IsPlayerValid(p) then
			local at = Vec(GetFloat(k .. "x"), GetFloat(k .. "y"), GetFloat(k .. "z"))
			local text = GetString(k .. "text")
			local mode = GetString(k .. "mode")
			local named = text:lower():find(MOCHI_NAME:lower(), 1, true) ~= nil
			local reach = mode == "global" and (named and 1e9 or 0) or GetFloat(k .. "wordsRadius")
			if VecLength(VecSub(at, M.pos)) <= reach + 1 then
				M.lastSpeaker, M.lastSpeakerT = p, now()
				if mode ~= "global" then eventsRide() end                -- (his AI hears this line: it carries the events)
				if useWords then                                          -- (no AI: every line near him gets his attention,
					M.look, M.lookUntil = p, now() + 4                    --  and his name brings him)
					attend()
					if MochiKeywordName(text, MOCHI_NAME) then MochiCalled(p) end
				end
				if useWords then
					-- (no AI: he obeys plain commands; with API 18 he also answers with a dog's noise - .say - a doubtful one
					--  when he won't)
					local heardCmd, refused = false, false
					local function run(name, args)
						heardCmd = true
						local ok = MochiCommand(name, args, p)
						if not ok then refused = true end
					end
					for _, q in ipairs(players()) do                      -- ("get Sam!": an attack - "get going" isn't)
						if q ~= p and text:lower():find("get " .. nameOf(q):lower(), 1, true) then
							run("attack", {target = nameOf(q)})
						end
					end
					for _, f in ipairs(MochiKeywords(text)) do
						if f.cmd == "trick" then run("trick", {name = f.arg})
						elseif f.cmd == "attack" then
							local tg = "that"                                -- (a player named in the line, else what the
							for _, q in ipairs(players()) do                 --  host looks at)
								if q ~= p and MochiKeywordName(text, nameOf(q)) then tg = nameOf(q) end
							end
							run("attack", {target = tg})
						elseif f.cmd == "run_away" then run("run_away", {from = "danger"})
						else run(f.cmd, {player = "me", seconds = 5}) end
						if f.cmd == "wag" then queueAct("wiggle") end
					end
					if heardCmd then
						local noises = refused and {"Woof?", "Rrr... woof?"} or {"Woof!", "Arf arf!", "Bork!", "Woof woof!"}
						MochiSay(noises[math.random(#noises)])
					elseif MochiKeywordName(text, MOCHI_NAME) then
						MochiSay("Arf?")                                   -- (his name, nothing he knows: an ear-perk)
					end
				end
			end
		end
	end
	M.said = last
end

-- ---- each frame: the agent, the chat, shared.mochi for the clients
function MochiServerTick(dt)
	local M = MOCHI
	if not (M and M.started) then return end
	local t = now()
	flushEvents()
	if M.stateDirty then
		M.stateDirty = false
		local st = MochiStateText()
		if GetString(reg .. ".state") ~= st then SetString(reg .. ".state", st) end
	end
	toolsTick()
	MochiHitsTick(dt)                                                -- (first: a shot it counts is not counted again below)
	hurtTick(dt)
	said()
	calls()
	replies()
	if t - M.agentT >= CFG.agentEvery then
		M.agentT = t
		agentKeys()
	end
	if t - M.pubT >= CFG.publish then
		M.pubT = t
		M.n = M.n + 1
		local wagNow = t < M.wagUntil and M.wagLevel or 0
		if t >= M.wagUntil then M.wagLevel = 0 end
		shared.mochi = {n = M.n, x = M.pos[1], y = M.pos[2], z = M.pos[3], yaw = M.yaw, speed = M.speed, phase = M.phase,
			posture = M.posture, act = M.act and M.act.kind or "", actN = M.actN, actBase = M.act and M.act.base or M.posture,
			wag = wagNow, talk = t < M.talkUntil, carry = M.carry, look = (alive(M.look) and t < M.lookUntil) and M.look or 0,
			barkN = M.barkN, whineN = M.whineN, heartN = M.heartN, eatN = M.eatN, mode = M.mode, ball = (not M.ballIn and M.ball) or 0, ballIn = M.ballIn or 0, bounceN = M.bounceN, grounded = M.grounded,
			hp = M.hp, maxHp = CFG.hp, dead = M.dead, angry = M.attack ~= nil, scared = M.flee ~= nil, yelpN = M.yelpN, growlN = M.growlN,
			respawnN = M.respawnN,
			lookPos = (M.sound and t - M.sound.t < CFG.soundLook) and {M.sound.pos[1], M.sound.pos[2], M.sound.pos[3]} or nil,
			why = (M.why and t - M.whyT < 10) and M.why or standingWhy()}
	end
end
