-- Mochi the Corgi: the dog's mind and body on the HOST (server). Include dog_rig.lua and dog_anim.lua before it.
-- No #version line (included). Globals: MOCHIS (every dog), MOCHI (the current dog's state), MOCHI_WORLD (what the dogs
-- share), MochiServerInit(), MochiServerTick(dt), MochiServerUpdate(dt), MochiServerPostUpdate(), MochiPet(p, k),
-- MochiTreat(p), MochiCommand(name, args, speaker) (also the offline test's entry).
--
-- MANY DOGS (the user, 2026-11-04: "Mochi is spawnable from the spawn menu ... only the host can spawn Mochis"): the first
-- arrives by himself, more come from the spawn menu (prefab/spawn_mochi.xml, a marker the server turns into a dog). Each
-- dog is a table in MOCHIS; the code below works on MOCHI, the CURRENT dog - MochiUse(D) makes D current (MOCHI, reg,
-- MOCHI_ID, MOCHI_NAME) before his update / tick / callbacks run, and the first dog is current between callbacks. What
-- the world has once is in MOCHI_WORLD (W): the one ball and who holds it, the treats and each player's supply, the
-- tools, the players' tool state. Names: "Mochi", "Mochi 2", ... - a new dog takes the lowest name no living dog has
-- (the user, 2026-11-04), agent ids mochi, mochi2, ... (a reused id: the chat is told to forget the old one).
--
-- A dog has no body of its own on the server: it is a position, a heading and a state, published in shared.mochis
-- for every machine's client to draw (dog_view.lua). It walks by raycasts (ground under it, walls ahead) and the
-- engine's path planner. Its toys are real physics bodies the players grab and throw: a ball and bone treats.
--
-- TALKING goes through Proximity Comms' agents (API 17, proxchat/tools/API_public.md "Agents"): the host's Koetama
-- asks the host's language model. We define agent "mochi" (persona, functions, where it is, what it knows now), the
-- chat hands it what players say near it, says its replies as speech bubbles from it, and gives us its function
-- calls (a ring), which we check and carry out, and answer. Without the agents (no Koetama, no model, a budget
-- spent) a plain keyword parser reads the chat's said events instead ("Mochi, sit!"), so the dog still obeys.

MOCHI_BASE = "Mochi"                     -- (the first dog's name; the others are "Mochi 2", "Mochi 3", ...)
MOCHI_ID = "mochi"                       -- (the current dog's agent id and name: MochiUse sets them)
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
	publish = 0.05,                        -- s between shared.mochis updates
	agentEvery = 0.5,                      -- s between agent key writes
	eventEvery = 4,                        -- s: game events go as a line of their own at most this often (else with speech)
	eventAfterTalk = 10,                   -- s after a line of his before an event goes as a line of its own (not urgent
	                                       --  ones: the user, 2026-11-04 - too many bubbles too fast)
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
	byeFor = 20,                           -- s dead: his agent goes (sooner once his goodbye is said; death is for good -
	                                       --  the user, 2026-11-04)
	fetchNear = 25,                        -- m from the thrower or the ball: dogs this close run for a thrown ball
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
	-- messages (the user, 2026-11-04: "if I told mochi to go and tell XYZ that the bomb is ready, Mochi should be able to
	-- path-find their way to XYZ and tell them, or if path finding is too difficult, tell XYZ the next time Mochi sees XYZ")
	relayStop = 2.5,                       -- m from them: he tells them
	relayTell = 10,                        -- m: closer than this and in sight, he tells them from where he is
	relaySee = 25,                         -- m: a message waiting and its person in sight this close: he runs to them
	relayStuck = 12,                       -- s without getting a metre closer: he gives up for now
	relayRetry = 20,                       -- s after giving up before he tries for them again
	relayKeep = 900,                       -- s a message waits at most
	relayMax = 4,                          -- messages he carries at once (the oldest is forgotten)
	-- bangs (the user, 2026-11-04: "The dog should also respond to events like explosions and gun shots. Maybe it should
	-- run away or start barking, depending on the situation (LLM can decide)"): a flinch at once, then an event for the AI
	shotHear = 50,                         -- m: a gunshot this close is heard
	blastHear = 40, blastHearPer = 40,     -- m: an explosion within blastHear + blastHearPer x strength (150 at most)
	noiseGather = 1.0,                     -- s bangs are gathered into one event (a burst of shots is one)
	noiseEvery = 8,                        -- s between noise events at most
	noiseNear = 15,                        -- m: an explosion this close goes at once (after noiseGather)
	flinchShot = 8, flinchBlast = 25,      -- m: closer than this he flinches
	usedTo = 3,                            -- the same shooter's bursts within usedToFor s: after this many, he's told he knows it
	usedToFor = 60,
	-- bored (the user, 2026-11-04: "if nothing happens for 45 seconds or more, that should also be logged as an event.
	-- In this case, mochi should look bored and maybe try to strike up a convo (whatever the llm decides)")
	boredAfter = 90,                       -- s without anyone playing with or talking to him, or anything happening to him
	                                       --  (the user, later on 2026-11-04: "after 1 minute 30 seconds rather than 45")
	boredNear = 25,                        -- m: only with someone this close (else he just wanders)
	-- water (the user, 2026-11-04: "mochi should float and swim on water rather than sinking")
	swimSink = 0.50,                       -- m: his root (the ground point under him) this far under the surface: back awash,
	                                       --  the mouth (0.57 m up in the swim pose) just out
	swimProbe = 0.3,                       -- m over his root: water here (and the floor under the float line) = swimming
	swimSpeed = 1.3,                       -- m/s at most: a doggy paddle
	swimClimb = 0.9,                       -- m over his root: a ledge up to this high he climbs out onto (a pool's edge)
	swimTell = 30,                         -- s on dry land before a new dip is an event again
}
MOCHI_BALL_TOOL, MOCHI_TREAT_TOOL = "mochiball", "mochitreats"
MOCHI_CFG = CFG

local reg = "proxchat.agent." .. MOCHI_ID
local function now() return GetTime() end

MOCHI = nil
MOCHIS = {}
local W = nil                                                         -- (MOCHI_WORLD: set by MochiServerInit)

-- dog D is the current one: the code below works on MOCHI, and his agent's keys are under reg
function MochiUse(D)
	MOCHI = D
	if D then reg, MOCHI_ID, MOCHI_NAME = "proxchat.agent." .. D.id, D.id, D.name end
end

-- fn(...) with dog D current (the one before is current again after)
local function with(D, fn, ...)
	local was = MOCHI
	MochiUse(D)
	local a, b, c = fn(...)
	MochiUse(was)
	return a, b, c
end
MochiWith = with

-- fn(D, ...) for every dog, each current in turn
local function each(fn, ...)
	for _, D in ipairs(MOCHIS) do with(D, fn, D, ...) end
end

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
	if W then
		if W.ball and IsHandleValid(W.ball) then QueryRejectBody(W.ball) end
		for _, t in ipairs(W.treats) do if IsHandleValid(t) then QueryRejectBody(t) end end
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

-- a wall ahead within dist? (a ray just above the highest step it climbs: up, when not stepUp)
local function blocked(pos, dir, dist, up)
	filter()
	local hit = QueryRaycast(VecAdd(pos, Vec(0, (up or CFG.stepUp) + 0.1, 0)), dir, dist, 0.08)
	return hit
end

-- the water's surface over a dog standing at p (probed swimProbe up), or nil: dry there
local function waterTop(p)
	local q = Vec(p[1], p[2] + CFG.swimProbe, p[3])
	local ok, under, depth = pcall(IsPointInWater, q)
	if ok and under and depth then return q[2] + depth end
	return nil
end

-- where a dog floats at x,z when g is the floor there: the height his root bobs at, or nil (dry, or wading: the floor
-- is higher than that)
local function floatAt(p, g)
	local top = waterTop(p)
	if not top then return nil end
	local f = top - CFG.swimSink
	if g and g >= f - 0.02 then return nil end
	return f
end
MochiFloatAt = floatAt

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
			W.uncentred[h] = true
			return h
		end
	end
	return nil
end

-- a toy's shape centred on its body's origin (so "the ball at his mouth" means its middle); a fresh shape can read size 0
-- in its spawn frame, so this is tried each step until it works
local function centreToys()
	for h in pairs(W.uncentred) do
		if not IsHandleValid(h) then W.uncentred[h] = nil
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
				W.uncentred[h] = nil
			end
		end
	end
end

-- the one ball (whoever carried it doesn't any more)
local function setCarry(M, on)
	M.carry = on
	if on then W.carrier = M elseif W.carrier == M then W.carrier = nil end
end

local function dropCarrier()
	if W.carrier then W.carrier.carry = false; W.carrier = nil end
end

local function spawnBall(pos)
	if W.ball and IsHandleValid(W.ball) then Delete(W.ball) end
	W.ball = spawnBody("MOD/vox/ball_phys.vox", "mochiball", pos)
	W.ballV = nil
	dropCarrier()
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
	local l = {}
	for _, t in ipairs(W.treats) do if IsHandleValid(t) then l[#l + 1] = t end end
	W.treats = l
end

local function bodyPos(h) return GetBodyTransform(h).pos end
local function heldBy(h)
	for _, p in ipairs(players()) do
		local ok, g = pcall(GetPlayerGrabBody, p)
		if ok and g == h then return p end
	end
	return nil
end

-- who has the ball: in their tools (W.ballIn), or grabbed with the right mouse
local function ballHolder()
	if W.ballIn then
		if IsPlayerValid(W.ballIn) then return W.ballIn end
		W.ballIn = nil                                                -- (they left: the ball comes back by the dog)
	end
	if W.ball and IsHandleValid(W.ball) then return heldBy(W.ball) end
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
local URGENT = {arrive = true, die = true, back = true, relay = true, noise = true, bored = true}   -- (relay: he is in front of them now)
local function event(kind, text)
	local M = MOCHI
	if M.gone then return end                                         -- (his agent is gone: nobody to tell)
	if kind ~= "bored" then MochiHappened() end
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
		local lastLine = M.lineT and M.lineT[#M.lineT] or -1e9        -- (he just talked: they wait in .note - a line said
		if M.evUrgent or (t - M.evFirstT >= CFG.eventEvery and t - M.evFlushT >= CFG.eventEvery    --  to him carries them)
			and t - lastLine >= CFG.eventAfterTalk) then
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
	local lastLine = M.lineT and M.lineT[#M.lineT] or -1e9            -- (he just talked: they wait)
	if not M.evUrgent and t - lastLine < CFG.eventAfterTalk then return end
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
	if kind == "bark" then
		if MochiIsQuiet() then kind = "wiggle"; M.act.kind = kind else M.barkN = M.barkN + 1 end   -- (quiet: no bark)
	end
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

-- the acts he can do while swimming (no sitting, lying or tricks in the water)
local WET_ACTS = {bark = true, eat = true, wiggle = true, flinch = true, bite = true, die = true, yawn = true, stand_up = true}
MOCHI_WET_ACTS = WET_ACTS

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
		if M.swim and not WET_ACTS[k] then table.remove(M.queue, 1); return end   -- (in the water: not now)
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
	if mode ~= "relay" then M.relay = nil end                         -- (told something else: the message waits)
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

-- ---- messages he carries (the agent's relay call): {to, from, msg, t, retryT}. `to` is a player {p} or another agent
-- {agent = id, name} (the user, 2026-11-04: "make mochi able to carry a message to other agents"); `from` a player id
-- or an agent's speaker number (3000+). He runs to them along the path planner's way; near them (or in sight within
-- relayTell) he tells them - the AI says it, from an event (an agent hears it if its mod lets it hear agents). No way
-- there (no closer in relayStuck s): he gives up for now, and tells them when he next sees them

-- another agent's place (its .at: body:<h>[+offset], player:<id> or x,y,z) and the body it hangs on
local function agentAt(id)
	local at = GetString("proxchat.agent." .. id .. ".at")
	local kind, rest = at:match("^(%a+):(.*)$")
	if kind == "body" then
		local h = tonumber(rest:match("^(%d+)"))
		if h and IsHandleValid(h) then return GetBodyTransform(h).pos, h end
	elseif kind == "player" then
		local q = tonumber(rest:match("^(%d+)"))
		if q and IsPlayerValid(q) then return feet(q) end
	else
		local x, y, z = at:match("^%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)")
		if x then return Vec(tonumber(x), tonumber(y), tonumber(z)) end
	end
	return nil
end

local function agentIds()
	local ok, ids = pcall(ListKeys, "proxchat.agent")
	local l = {}
	for _, id in ipairs(ok and type(ids) == "table" and ids or {}) do
		if id ~= MOCHI_ID and GetString("proxchat.agent." .. id .. ".persona") ~= "" then l[#l + 1] = id end
	end
	return l
end

local function agentName(id)
	local n = GetString("proxchat.agent." .. id .. ".name")
	return n ~= "" and n or id
end

-- another agent by a name the model gave ("Gus", "gus", "Mochi 2"); its id, nil if none fits
function MochiAgentByName(s)
	s = tostring(s or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then return nil end
	local best
	for _, id in ipairs(agentIds()) do
		local n = agentName(id):lower()
		if n == s or id:lower() == s then return id end
		if not best and (n:sub(1, #s) == s or s:find(n, 1, true)) then best = id end
	end
	return best
end

-- a player's name, or an agent's by its speaker number (a call's .from, .replyfrom); nil when it's neither
function MochiSpeakerName(n)
	n = tonumber(n)
	if not n then return nil end
	if IsPlayerValid(n) then return nameOf(n) end
	for _, id in ipairs(agentIds()) do
		if GetInt("proxchat.agent." .. id .. ".player") == n then return agentName(id) end
	end
	return nil
end

-- where a message's person is, whether they're there to be told, whether they're gone for good, their name
local function tPos(T)
	if T.p then return IsPlayerValid(T.p) and feet(T.p) or nil end
	return (agentAt(T.agent))
end
local function tHere(T)
	if T.p then return alive(T.p) end
	return GetString("proxchat.agent." .. T.agent .. ".persona") ~= "" and agentAt(T.agent) ~= nil
end
local function tGone(T)
	if T.p then return not IsPlayerValid(T.p) end
	return GetString("proxchat.agent." .. T.agent .. ".persona") == ""
end
local function tName(T) return T.p and nameOf(T.p) or T.name end
local function fromName(r) return r.from and MochiSpeakerName(r.from) or "someone" end

-- in sight: their head (an agent: its place) from his, nothing between (an agent's own body doesn't count)
local function sees(T)
	local eye = VecAdd(MOCHI.pos, Vec(0, 0.5, 0))
	local to, body
	if T.p then to = GetPlayerEyeTransform(T.p).pos else to, body = agentAt(T.agent) end
	if not to then return false end
	local v = VecSub(to, eye)
	local d = VecLength(v)
	if d < 0.5 then return true end
	filter()
	if body then QueryRejectBody(body) end
	return not QueryRaycast(eye, VecScale(v, 1 / d), d - 0.3)
end
MochiSees = sees

local function startRelay(r)
	local M = MOCHI
	if M.mode ~= "relay" then M.relayPrev, M.relayPrevTarget = M.mode, M.target end
	setMode("relay", r.to.p)
	M.relay = {r = r, best = hdist(tPos(r.to), M.pos), bestT = now()}
	M.stateDirty = true
	if M.posture ~= "stand" then queueAct("stand_up") end
end

-- back to what he did before (following someone), else free
local function endRelay()
	local M = MOCHI
	if M.mode ~= "relay" then return end
	local back = M.relayPrev == "follow" and alive(M.relayPrevTarget)
	setMode(back and "follow" or "free", back and M.relayPrevTarget or nil)
	M.stateDirty = true
end

local function deliver(r)
	local M = MOCHI
	for i = #M.relays, 1, -1 do if M.relays[i] == r then table.remove(M.relays, i) end end
	if M.relay and M.relay.r == r then endRelay() end
	local at = tPos(r.to)
	if at then M.yaw = yawTo(M.pos, at) end
	if r.to.p then M.look, M.lookUntil = r.to.p, now() + 5 end
	wag(4, 1)
	M.relayedN = (M.relayedN or 0) + 1
	M.stateDirty = true
	local from = fromName(r)
	if MochiAgentOn() then
		event("relay", string.format('You found %s. Give them the message from %s now, in your own words (short, say who it is from' ..
			(r.to.agent and ", and say their name" or "") .. '): "%s"', tName(r.to), from, r.msg))
	else
		MochiSay("Woof! " .. (r.to.agent and (tName(r.to) .. "! ") or "") .. from .. " says: " .. r.msg)   -- (no AI any more)
	end
end

local function giveUp(r)
	local M = MOCHI
	r.retryT = now() + CFG.relayRetry
	endRelay()
	event("relay_lost", "You can't find a way to " .. tName(r.to) .. " right now. You'll tell them " .. fromName(r) ..
		"'s message when you see them.")
end

-- (each step, 5 times a second) a message under way, and the waiting ones: is their person in sight?
local function relayTick()
	local M = MOCHI
	local t = now()
	if M.dead or t < M.relayT then return end
	M.relayT = t + 0.2
	for i = #M.relays, 1, -1 do
		local r = M.relays[i]
		if t - r.t > CFG.relayKeep or tGone(r.to) then table.remove(M.relays, i); M.stateDirty = true end
	end
	if M.mode == "relay" then
		local G = M.relay
		if not G or not tHere(G.r.to) then                              -- (dead or gone: later)
			if G then G.r.retryT = t + 5 end
			endRelay()
			return
		end
		local d = hdist(tPos(G.r.to), M.pos)
		if d <= CFG.relayStop or (d <= CFG.relayTell and sees(G.r.to)) then deliver(G.r); return end
		if d < G.best - 1 then G.best, G.bestT = d, t end
		if t - G.bestT > CFG.relayStuck then giveUp(G.r) end
		return
	end
	local busy = M.attack or M.flee or M.mode == "stay" or M.mode == "fetch"
	for _, r in ipairs(M.relays) do
		if tHere(r.to) and t >= (r.retryT or 0) then
			local d = hdist(tPos(r.to), M.pos)
			if d <= CFG.relaySee and sees(r.to) then
				if d <= CFG.relayTell then deliver(r); return end            -- (in earshot: he tells them from here)
				if not busy then startRelay(r); return end
			end
		end
	end
end

-- (goal) where the message under way goes; nil when nowhere
function MochiRelayGoal()
	local G = MOCHI.relay
	return G and tPos(G.r.to)
end

-- (MochiCommand) relay to = a player or another agent, from the speaker (a player id or an agent's speaker number)
function MochiRelayCommand(args, speaker)
	local M = MOCHI
	local said = args.to or args.player
	if tostring(said or ""):lower():gsub("^%s+", ""):gsub("%s+$", "") == MOCHI_NAME:lower() then
		return false, "error: that's you"                              -- (another dog's name finds him: MochiAgentByName)
	end
	local T
	local p = MochiPlayerByName(said, nil)
	if p then T = {p = p}
	else
		local id = MochiAgentByName(said)
		if id then T = {agent = id, name = agentName(id)} end
	end
	if not T then return false, "error: nobody here called " .. tostring(said) end
	if (T.p and T.p == speaker) or (T.agent and speaker and GetInt("proxchat.agent." .. T.agent .. ".player") == speaker) then
		return false, "error: " .. tName(T) .. " is the one talking to you - just answer them"
	end
	local msg = tostring(args.message or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "" then return false, "error: what is the message?" end
	if #msg > 300 then msg = msg:sub(1, 300) end
	local who = tName(T)
	if tHere(T) and hdist(tPos(T), M.pos) <= CFG.relayTell and sees(T) then
		return true, "ok: " .. who .. " is right here - tell them now"
	end
	local r = {to = T, from = speaker and MochiSpeakerName(speaker) and speaker or nil, msg = msg, t = now()}
	M.relays[#M.relays + 1] = r
	while #M.relays > CFG.relayMax do table.remove(M.relays, 1) end
	M.stateDirty = true
	if not tHere(T) then return true, "ok: " .. who .. " can't hear you right now; you'll tell them when you see them" end
	startRelay(r)
	return true, string.format("ok: running to %s (%d m away) - when you reach them the game tells you, then you say it",
		who, math.floor(hdist(tPos(T), M.pos) + 0.5))
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
		pcall(ApplyPlayerDamage, A.p, CFG.bitePlayer, MOCHI_NAME, A.why == "ordered" and hostPlayer() or nil)
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

-- (dead, each step) death is for good (the user, 2026-11-04: no respawn): once his goodbye has been said (and shown), or
-- after byeFor s, his agent goes - the chat drops him; his body lies there. His name is free for the next dog
local function removeAgent()
	local M = MOCHI
	if M.gone then return end
	M.gone = true
	ClearKey(reg)
	ClearKey("villagers.thing." .. MOCHI_ID)                          -- (gone from the villagers' sight too)
	if M.anchor and IsHandleValid(M.anchor) then Delete(M.anchor) end
	M.anchor = nil
end

local function deadTick()
	local M = MOCHI
	if M.gone then return end
	local t = now()
	if t - M.diedT > CFG.byeFor or (M.byeSaid and t > M.talkUntil + 1.5) then removeAgent() end
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

-- run_away: from a named player, from "danger" (whatever hurt him last) or "noise" (the last bang: its shooter, or where
-- it went off); nil and why when there's nothing to run from
local NOISE_WORDS = {noise = true, ["the noise"] = true, bang = true, ["the bang"] = true, explosion = true,
	["the explosion"] = true, gunshot = true, gunshots = true, shots = true, gun = true, ["the gun"] = true, boom = true}
function MochiStartFlee(from, speaker)
	local M = MOCHI
	local s = tostring(from or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local D
	local N = M.noise and now() - M.noise.t < CFG.dangerMemory and M.noise or nil
	if NOISE_WORDS[s] then
		if not N then return nil, "there was no bang to run from" end
		D = {p = N.p, pos = N.pos, what = N.what, t = N.t}
	elseif s ~= "" and s ~= "danger" and s ~= "it" and s ~= "that" and s ~= "them" then
		local p = MochiPlayerByName(s, nil)
		if p then D = {p = p, what = nameOf(p), t = now()} end
	end
	if not D and M.danger and now() - M.danger.t < CFG.dangerMemory then D = M.danger end
	if not D and N then D = {p = N.p, pos = N.pos, what = N.what, t = N.t} end   -- (nothing hurt him: the last bang)
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

-- ---- bangs: explosions and gunshots near him. At once: a flinch when close and a look at it; then gathered for
-- noiseGather s (a burst of shots is one) into one event for the AI, at most every noiseEvery s, which decides what he
-- does (bark, run away from "noise", run to his owner, a yip). M.noise: the last bang, for run_away "noise"
local function side(pos)
	local M = MOCHI
	local a = angDiff(M.yaw, yawTo(M.pos, pos))
	if math.abs(a) < 45 then return "in front of you" elseif math.abs(a) > 135 then return "behind you" end
	return a > 0 and "to your left" or "to your right"                -- (yaw grows to the left: 0 = +z, 90 = +x)
end

function MochiNoise(kind, p, pos, str)
	local M = MOCHI
	if not (M and M.started) or M.dead or not pos then return end
	local t, d = now(), VecLength(VecSub(pos, M.pos))
	local what = kind == "explosion" and "the explosion" or (alive(p) and (nameOf(p) .. "'s gunshots") or "the gunshots")
	M.noise = {kind = kind, p = alive(p) and p or nil, pos = VecCopy(pos), t = t, what = what}
	M.sound = {pos = VecCopy(pos), t = t, vol = 1}                      -- (he looks at it)
	if d < (kind == "explosion" and CFG.flinchBlast or CFG.flinchShot) and not M.act and M.posture ~= "dead" then
		startAct("flinch")
	end
	local A = M.noiseAcc
	if not A then A = {firstT = t, shots = {}, nShots = 0, blasts = 0}; M.noiseAcc = A end
	if kind == "explosion" then
		A.blasts = A.blasts + 1
		if not A.blastD or d < A.blastD then A.blastD, A.blastSide, A.blastStr = d, side(pos), str or 1 end   -- (as heard: he turns to it)
	else
		A.nShots = A.nShots + 1
		local key = alive(p) and p or 0
		local S = A.shots[key] or {n = 0}
		A.shots[key] = S
		S.n = S.n + 1
		if not S.d or d < S.d then S.d, S.side = d, side(pos) end
	end
end

-- (each tick) the gathered bangs out as one event when it's time
local function noiseTick()
	local M = MOCHI
	local A = M.noiseAcc
	if not A or M.dead then M.noiseAcc = nil; return end
	local t = now()
	if t - A.firstT < CFG.noiseGather then return end
	local nearBlast = A.blastD and A.blastD < CFG.noiseNear
	if t - M.noiseSentT < CFG.noiseEvery and not nearBlast then return end
	M.noiseAcc = nil
	local parts = {}
	if A.blasts > 0 then
		parts[#parts + 1] = string.format("BOOM! %s went off %d m away, %s.",
			A.blasts > 1 and (A.blasts .. " explosions") or ((A.blastStr or 1) >= 2 and "A big explosion" or "An explosion"),
			math.floor(A.blastD + 0.5), A.blastSide)
	end
	local quiet = A.blasts == 0
	for key, S in pairs(A.shots) do
		local who = key ~= 0 and IsPlayerValid(key) and nameOf(key) or "Someone"
		-- (the same shooter again and again, nothing worse: he's told he knows it - he gets used to it)
		local B = M.bursts[key] or {}
		M.bursts[key] = B
		for i = #B, 1, -1 do if t - B[i] > CFG.usedToFor then table.remove(B, i) end end
		B[#B + 1] = t
		local again = #B > CFG.usedTo
		if not again then quiet = false end
		parts[#parts + 1] = string.format("BANG! %s fired %s %d m from you, %s.%s", who,
			S.n > 1 and (S.n .. " shots") or "a gun", math.floor(S.d + 0.5), S.side,
			again and (" " .. who .. " keeps shooting - you have heard it a lot just now.") or "")
	end
	if #parts == 0 or quiet and M.hurtT < t - 10 and A.nShots > 0 and not A.blastD then
		-- (only a shooter he's used to, and nothing hurt him: no request for it)
		if #parts > 0 then M.noiseQuiet = (M.noiseQuiet or 0) + 1 end
		return
	end
	M.noiseSentT = t
	M.noiseN = (M.noiseN or 0) + 1
	if not MochiAgentOn() then                                         -- (no AI: a dog's own answer - he barks at it)
		queueAct("bark")
		if not MochiIsQuiet() then MochiSay("Woof woof!") end
		return
	end
	event("noise", table.concat(parts, " "))
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
		if d < math.min(150, CFG.blastHear + CFG.blastHearPer * str) then MochiNoise("explosion", nil, pos, str) end
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

-- (world, each tick, once for all the dogs) who swung or fired a tool this frame: W.fired[p] = the tool; W.torch[p] = a
-- blowtorch in use (a round counted once, however many dogs look at it)
local function toolsFired()
	local t = now()
	W.fired, W.torch = {}, {}
	for _, p in ipairs(players()) do
		local okT, tool = pcall(GetPlayerTool, p)
		local T = okT and HIT_TOOLS[tool]
		local st = W.toolSt[p] or {}
		W.toolSt[p] = st
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
			if fired then W.fired[p] = tool end
		else
			st.tool, st.ammo = nil, nil
		end
		if okT and tool == "blowtorch" and alive(p) and InputDown("usetool", p) then W.torch[p] = true end
	end
end

-- (each dog) the swings and shots of this frame that reach him; a blowtorch on him
local function toolHits(dt)
	local M = MOCHI
	local t = now()
	for _, p in ipairs(players()) do
		local tool = W.fired[p]
		local T = tool and HIT_TOOLS[tool]
		if T then
			if tool ~= "sledge" and hdist(feet(p), M.pos) < CFG.shotHear then MochiNoise("shot", p, feet(p)) end
			local dist = aimedAt(p, T.reach)
			if dist then
				M.shotT[p] = t
				if tool == "sledge" then knockBack(feet(p), 0.7) end
				MochiDamage(T.dmg, {p = p}, tool == "sledge" and "hit with a sledgehammer" or "shot", feet(p))
			end
		end
		-- a blowtorch held on him up close burns
		if W.torch[p] and aimedAt(p, 1.6) then
			M.burn = (M.burn or 0) + CFG.torchDmg * dt
			M.burnBy = {p = p}
		end
	end
end

-- (MochiDamage callers) was this player's bullet already counted by the aim check this moment?
function MochiShotCounted(p)
	local st = MOCHI.shotT[p]
	return st and now() - st < 0.3
end

-- (world, each tick) who held each loose body lately (grabbed with the right mouse): a thrown thing is theirs
local function heldTick()
	local t = now()
	for _, p in ipairs(players()) do
		local okG, g = pcall(GetPlayerGrabBody, p)
		if okG and g and g ~= 0 then W.heldBy[g] = {p = p, t = t} end
	end
	for b, h in pairs(W.heldBy) do if t - h.t > 10 then W.heldBy[b] = nil end end
end

-- loose bodies flying through him (who held each lately: heldTick)
local function flyingHits()
	local M = MOCHI
	local t = now()
	local lo = VecAdd(M.pos, Vec(-0.6, -0.1, -0.6))
	local hi = VecAdd(M.pos, Vec(0.6, 0.9, 0.6))
	local okQ, list = pcall(QueryAabbBodies, lo, hi)
	for _, b in ipairs(okQ and list or {}) do
		if IsHandleValid(b) and IsBodyDynamic(b) and not HasTag(b, "mochiball") and not HasTag(b, "mochitreat")
			and not HasTag(b, "mochianchor") and not HasTag(b, "mochidog") and not HasTag(b, "mochitoy")
			and not HasTag(b, "mochispawn")
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
					local h = W.heldBy[b]
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
		if body and body ~= 0 and IsBodyDynamic(body) and body ~= W.ball then return {body = body, what = "that thing"} end
	end
	return nil
end

function MochiCommand(name, args, speaker)
	local M = MOCHI
	args = args or {}
	attend()
	MochiHappened()
	if M.dead then return false, "error: you are dead" end
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
		if M.swim and not WET_ACTS[kind] then return false, "error: you are swimming - no " .. tr .. " in the water" end
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
	elseif name == "fetch" then                                       -- (this dog only: the others go on as they were)
		if not (W.ballIn or (W.ball and IsHandleValid(W.ball))) then return false, "error: there is no ball" end
		if W.carrier and W.carrier ~= M then return false, "error: " .. W.carrier.name .. " has the ball in his mouth" end
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
	elseif name == "quiet" then
		local on = tostring(args.on or "true"):lower()
		on = not (on == "false" or on == "0" or on == "no" or on == "off")
		MochiQuiet(on)
		return true, on and "ok: quiet mode - you whisper and don't bark until you call quiet off" or "ok: normal voice again"
	elseif name == "relay" then
		return MochiRelayCommand(args, speaker)
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
		base = M.act and M.act.base or M.posture, phase = M.phase, speed = M.speed, carry = true, time = now(),
		swim = M.swim and 1 or 0}
	DogPose(a, poseOut)
	local m = poseOut.__mouth or Vec(0, 0.45, 0.45)
	return TransformToParentPoint(Transform(M.pos, QuatEuler(0, M.yaw, 0)), m)
end

function MochiDropBall()
	local M = MOCHI
	if not M.carry then return end
	setCarry(M, false)
	if W.ball and IsHandleValid(W.ball) then
		SetBodyTransform(W.ball, Transform(mouthWorld()))
		SetBodyVelocity(W.ball, VecAdd(VecScale(fwd(M.yaw), 0.8), Vec(0, 0.5, 0)))
	end
end

-- where the speech bubble hangs: over its ears, wherever it is
local function headTop()
	local M = MOCHI
	local h = DOG_RIG.headTop or {0, 0.7, 0.35}
	return TransformToParentPoint(Transform(M.pos, QuatEuler(0, M.yaw, 0)), Vec(h[1], h[2], h[3]))
end

-- ---- init: the world, and the dogs (MOCHIS; the first arrives by himself at the start, the others from the spawn menu)
local function dogName(num) return num == 1 and MOCHI_BASE or (MOCHI_BASE .. " " .. num) end
local function dogId(num) return num == 1 and "mochi" or ("mochi" .. num) end

-- the lowest name number no living dog has (the user, 2026-11-04: Mochi died, Mochi 2 and 3 live - the next is "Mochi")
local function freeNum()
	local used = {}
	for _, D in ipairs(MOCHIS) do if not D.dead then used[D.num] = true end end
	local n = 1
	while used[n] do n = n + 1 end
	return n
end

-- a new dog (not in the world yet: start / spawnDog place him). An agent id used before this session: a dead dog still
-- holding it loses it now, the old keys are cleared, and the chat is told to forget that conversation (.forget)
local function newDog(num)
	W.serial = W.serial + 1
	local id = dogId(num)
	local M = {pos = nil, yaw = 0, vy = 0, speed = 0, phase = 0, grounded = true, posture = "stand", act = nil, actN = 0,
		barkN = 0, whineN = 0, queue = {}, mode = "free", target = nil, fetch = nil, carry = false,
		wagUntil = 0, wagLevel = 0, talkUntil = 0, look = 0, lookUntil = 0, pendingEv = {}, evOrder = 0, evFlushT = -1e9, evFirstT = 0,
		evUrgent = false, eventLines = 0, evRideUntil = nil, evRode = 0, stateDirty = false, petN = 0,
		heartN = 0, eatN = 0, calls = nil, replyN = nil, agentT = -1, idleT = 0, stuckT = 0,
		lastPos = nil, offer = {}, path = nil, planner = nil, started = false, sniffT = 0,
		hp = CFG.hp, dead = false, diedT = 0, hurtT = -1e9, attack = nil, biteT = -1e9, yelpN = 0, growlN = 0, carT = -1e9,
		diedN = 0, lastSpeaker = nil, lastSpeakerT = -1e9, attentionT = -1e9, wander = nil, sound = nil, soundN = 0,
		shotT = {}, hitT = {}, relays = {}, relay = nil, relayT = 0, talkedWith = {}, scoreN = nil, judged = nil, noise = nil,
		noiseAcc = nil, noiseSentT = -1e9, bursts = {}, happenT = 0, boredT = -1e9, bored = false, boredN = 0,
		num = num, id = id, name = dogName(num), k = W.serial, gone = false, byeSaid = false, forget = W.usedIds[id] == true}
	for _, D in ipairs(MOCHIS) do
		if D.id == id and not D.gone then with(D, removeAgent) end
	end
	if M.forget then ClearKey("proxchat.agent." .. id) end
	W.usedIds[id] = true
	MOCHIS[#MOCHIS + 1] = M
	return M
end

function MochiServerInit()
	MOCHIS = {}
	W = {ball = nil, ballIn = nil, ballHolder = nil, ballV = nil, bounceN = 0, carrier = nil, treats = {}, treatT = {},
		treatsLeft = {}, treatsT = {}, uncentred = {}, heldBy = {}, toolSt = {}, fired = {}, torch = {}, lastThrower = nil,
		serial = 0, usedIds = {}, n = 0, pubT = -1, said = nil, started = false, spawnedN = 0, refusedN = 0}
	MOCHI_WORLD = W
	MochiUse(newDog(1))
	-- the Villagers mod's API (villagers/mods/villagers/API.md; plain host keys, nothing reads them without it): what a
	-- corgi is and his reputation (feel is only a hint: each villager judges him with their own AI; no per-villager feelings from us)
	SetString("villagers.kind.corgi.name", "a corgi dog")
	SetString("villagers.kind.corgi.feel", "love")
	SetString("villagers.kind.corgi.note", "a friendly talking corgi who loves treats and belly rubs")
	SetFloat("villagers.kind.corgi.danger", 0)
end

-- (each dog, every 0.5 s) where he is for the villagers: his anchor body (it follows his head), his name, what he does
local function villagerKeys()
	local M = MOCHI
	if M.gone or not (M.anchor and IsHandleValid(M.anchor)) then return end
	local k = "villagers.thing." .. MOCHI_ID .. "."
	local function put(key, v) if GetString(k .. key) ~= v then SetString(k .. key, v) end end
	put("kind", "corgi")
	put("name", MOCHI_NAME)
	if GetInt(k .. "body") ~= M.anchor then SetInt(k .. "body", M.anchor) end
	put("doing", M.dead and "lying dead" or M.swim and "swimming" or M.bored and "bored" or
		M.attack and "attacking" or M.flee and "running scared" or M.carry and "carrying a ball" or
		M.posture == "lie" and "lying down" or M.posture == "sit" and "sitting" or M.speed > 0.3 and "trotting about" or "standing")
end

-- (the current dog) he comes into the world at pos facing who: his anchor, a hello
local function arrive(pos, who, text)
	local M = MOCHI
	M.pos = pos
	M.yaw = yawTo(M.pos, feet(who))
	spawnAnchor()
	M.started = true
	M.attentionT = now()
	M.happenT = now()
	M.look, M.lookUntil = who, now() + 4
	wag(6, 1)
	queueAct("bark")
	event("arrive", text)
end

-- the first tick with a player: the first dog arrives in front of the host, the ball beside him
local function start()
	local host = nil
	for _, p in ipairs(players()) do if IsPlayerHost(p) then host = p end end
	host = host or players()[1]
	if not host then return false end
	local t = GetPlayerTransform(host)
	local ahead = TransformToParentVec(t, Vec(0, 0, -2.5))
	local p = VecAdd(t.pos, ahead)
	local g = groundAt(p[1], t.pos[2] + 0.5, p[3])
	local side = TransformToParentVec(t, Vec(1.2, 0, -2))
	spawnBall(VecAdd(t.pos, Vec(side[1], 0.6, side[3])))
	with(MOCHIS[1], arrive, Vec(p[1], g or t.pos[2], p[3]), host,
		"You just arrived and see your people. You're so happy to see them!")
	W.started = true
	return true
end

-- ---- more dogs from the spawn menu (the user, 2026-11-04). spawn.txt lists prefab/spawn_mochi.xml, a marker body
-- (tag mochispawn) that looks like Mochi standing. The game's spawn menu (data/script/spawn.lua) first spawns a local
-- PREVIEW that follows the camera, its shapes' collision filter set to layer 0 / mask 0, and on the click
-- server.spawn(file, t, p) spawns the real one (filter 1 / 255) 2-8 m ahead of the spawner's camera. The server turns
-- each REAL marker into a dog standing on the ground below it, facing the host, and deletes it; a preview (layer 0: in
-- single player it is in the server's scene too) is left alone. ONLY THE HOST spawns dogs: the spawner isn't passed to
-- us, so it is the player whose camera ray the marker sits on (within spawnReach, the closest to the ray; their tool is
-- "none" while placing - spawn.lua takes it away - which counts too); anyone else's marker is deleted, no dog
CFG.spawnReach = 14                      -- m from the camera along its ray: the spawn menu places at 2-8 m (+ the radius)

local function isPreview(b)
	local shapes = GetBodyShapes(b) or {}
	if #shapes == 0 then return true end                              -- (nothing to look at: not a marker to take)
	for _, sh in ipairs(shapes) do
		local ok, layer = pcall(GetShapeCollisionFilter, sh)
		if ok and layer == 0 then return true end
	end
	return false
end

-- who spawned a marker whose middle is at mid: the player whose camera (or eye) ray it sits on; nil when nobody's
function MochiSpawner(mid)
	local ps = players()
	if #ps == 1 then return ps[1] end                                 -- (single player: theirs)
	local best, bs = nil, 1e9
	for _, p in ipairs(ps) do
		if alive(p) then
			local okC, cam = pcall(GetPlayerCameraTransform, p)
			local okT, tool = pcall(GetPlayerTool, p)
			for _, c in ipairs({okC and cam or GetPlayerEyeTransform(p), GetPlayerEyeTransform(p)}) do
				local dir = TransformToParentVec(c, Vec(0, 0, -1))
				local v = VecSub(mid, c.pos)
				local along = VecDot(v, dir)
				local perp = VecLength(VecSub(v, VecScale(dir, along)))
				local room = 1.0 + along * 0.08
				if along > 0.3 and along < CFG.spawnReach and perp < room then
					local sc = perp / room - ((okT and tool == "none") and 0.5 or 0)
					if sc < bs then best, bs = p, sc end
				end
			end
		end
	end
	return best
end

-- a new dog at the marker b (its middle mid), for the host
local function spawnDog(b, mid, host)
	local M = newDog(freeNum())
	filter()
	QueryRejectBody(b)
	local hit, d = QueryRaycast(VecAdd(mid, Vec(0, 0.3, 0)), Vec(0, -1, 0), 12, 0.08)
	local pos = Vec(mid[1], hit and (mid[2] + 0.3 - d - 0.08) or mid[2], mid[3])
	with(M, arrive, pos, host, "You just arrived: your owner " .. nameOf(host) ..
		" brought you here. You see your people (and maybe other dogs). You're so happy to see them!")
	W.spawnedN = W.spawnedN + 1
	return M
end

-- one living Mochi at a time (the user, 2026-11-04: "disable spawning if mochi is already on the map. Only 1 mochi
-- allowed per session"): the spawn menu brings one only once he has died
CFG.onlyOne = true                       -- (false: the host spawns as many as he likes - the multi-dog code stays)
local function livingDog()
	if not CFG.onlyOne then return nil end
	for _, D in ipairs(MOCHIS) do if D.started and not D.dead and not D.gone then return D end end
	return nil
end

-- (each tick) the markers placed since: a dog for the host's when none is alive, nothing for anyone else's
local function markersTick()
	local ok, list = pcall(FindBodies, "mochispawn", true)
	for _, b in ipairs(ok and type(list) == "table" and list or {}) do
		if IsHandleValid(b) and not isPreview(b) then
			local mid = bodyMid(b)
			local who = MochiSpawner(mid)
			local host = hostPlayer()
			local D = livingDog()
			if who and who == host and not D then spawnDog(b, mid, host)
			else
				W.refusedN = W.refusedN + 1                             -- (not the host's: no dog - the user, 2026-11-04)
				if D and who and who == host then
					W.onlyText, W.onlyT = "Only one " .. MOCHI_BASE .. " at a time: " .. D.name .. " is already here", now()
				end
			end
			Delete(b)
		end
	end
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
	for _, tr in ipairs(W.treats) do
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
	elseif M.mode == "relay" then                                    -- (relayTick tells them, or gives up)
		local p = MochiRelayGoal()
		if not p then return nil end
		return p, CFG.relayStop * 0.6, hdist(p, M.pos) > 8 and CFG.run or CFG.trot
	elseif M.mode == "fetch" then
		local F = M.fetch or {phase = "seek"}
		M.fetch = F
		if not (W.ballIn or (W.ball and IsHandleValid(W.ball))) then setMode("free"); return nil end
		if W.carrier and W.carrier ~= M then MochiFetchLost(); return nil end   -- (another dog got it first)
		if W.ballIn and F.phase == "seek" then F.phase = "wait" end
		if F.phase == "wait" then
			local h = ballHolder()
			if not h then F.phase = "seek" else
				M.look, M.lookUntil = h, t + 1
				return feet(h), 2.0, CFG.trot
			end
		end
		if F.phase == "seek" then
			local h = ballHolder()
			if not h and not (W.ball and IsHandleValid(W.ball)) then setMode("free"); return nil end
			local b = not h and bodyPos(W.ball)
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
	local G = M.wander
	if not G then G = {}; M.wander = G end
	if G.to then
		if t < G.giveUp and hdist(G.to, M.pos) > 0.5 then return G.to, 0.4, G.speed end
		G.to = nil
		G.pauseUntil = t + 2 + math.random() * 5
		if math.random() < 0.6 and M.posture == "stand" then queueAct("sniff") end
	end
	if G.pauseUntil and t < G.pauseUntil then return nil end
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
		if g and math.abs(g - M.pos[2]) < 1.5 and not floatAt(Vec(x, g, z), g) then   -- (he doesn't wander into a pool)
			G.to = Vec(x, g, z)
			G.giveUp = t + 15
			G.speed = math.random() < 0.25 and CFG.trot or CFG.walk
			return G.to, 0.4, G.speed
		end
	end
	G.pauseUntil = t + 2
	return nil
end

-- (fetching) another dog got the ball first: he goes back to what he did before
function MochiFetchLost()
	local M = MOCHI
	if M.mode ~= "fetch" then return end
	local back = M.prevMode == "follow" and alive(M.prevTarget)
	setMode(back and "follow" or "free", back and M.prevTarget or nil)
	if W.carrier and W.carrier ~= M then event("lost_ball", W.carrier.name .. " got the ball first.") end
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
		local bp = W.ball and IsHandleValid(W.ball) and bodyPos(W.ball)
		if F.phase == "seek" and bp and hdist(bp, M.pos) < CFG.reachBall + 0.35 and bp[2] - M.pos[2] < 0.9 and not W.carrier then
			setCarry(M, true)
			F.phase = "bring"
			wag(4, 1)
			for _, D in ipairs(MOCHIS) do                                -- (the others racing for it give up)
				if D ~= M and D.mode == "fetch" and D.fetch and D.fetch.phase ~= "bring" then with(D, MochiFetchLost) end
			end
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
	local swim = M.swim == true
	if swim then speed = math.min(speed, CFG.swimSpeed) end
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
	local up = swim and CFG.swimClimb or CFG.stepUp                 -- (swimming: a pool's edge is a step he climbs)
	if blocked(M.pos, f, 0.45 + stepLen, up) then
		-- a wall at chest height: slide along it (try the two sides), else stop
		local slid = false
		for _, k in ipairs({60, -60}) do
			local g = fwd(M.yaw + k)
			if not blocked(M.pos, g, 0.5, up) then
				nx, nz = M.pos[1] + g[1] * stepLen * 0.7, M.pos[3] + g[3] * stepLen * 0.7
				slid = true
				break
			end
		end
		if not slid then M.speed = 0; return end
	end
	local g = groundAt(nx, M.pos[2] + up - CFG.stepUp, nz)
	if g and g > M.pos[2] + up then M.speed = 0; return end         -- (too high a step)
	if swim and g and g > M.pos[2] + 0.1 and not floatAt(Vec(nx, g, nz), g) then
		M.pos[2], M.vy = g, 0                                         -- (out onto the edge: he scrambles up)
	end
	M.pos[1], M.pos[3] = nx, nz
	M.phase = (M.phase + stepLen / DogStride(M.speed) * 2 * math.pi) % (2 * math.pi)
end

-- into the water / out of it: no sitting or lying in the water (stands, paddling); a new dip is an event (not after
-- swimTell s on land); out after a swim: a good shake
local function swimming(on)
	local M = MOCHI
	if on == (M.swim == true) then return end
	local t = now()
	M.swim, M.stateDirty = on, true
	if on then
		M.swimT0 = t
		if M.posture ~= "stand" and not M.dead then M.posture = "stand"; M.act = nil end
		if t - (M.dryT or -1e9) > CFG.swimTell and not M.dead then
			event("water", "You're in the WATER, doggy-paddling (you can swim, your head is above the water).")
		end
	else
		M.dryT = t
		if t - (M.swimT0 or t) > 1.5 and not M.dead then queueAct("shake_off") end
	end
end
MochiSwimming = function() return MOCHI.swim == true end

-- gravity and the ground (or the water), every step
local function fall(dt)
	local M = MOCHI
	local g = groundAt(M.pos[1], M.pos[2], M.pos[3])
	local vy = M.vy
	local function landed() if vy < -CFG.fallSafe then MochiDamage((-vy - CFG.fallSafe) * CFG.fallDmg, nil, "a fall") end end
	local fl = floatAt(M.pos, g)
	swimming(fl ~= nil)
	if fl then                                                       -- (in the water: buoyed up to the float line, no
		local tv = clamp((fl - M.pos[2]) * 4, -3, 2)                --  fall damage; a dive in slows down in the water)
		M.vy = M.vy + (tv - M.vy) * math.min(1, dt * 5)
		local ny = M.pos[2] + M.vy * dt
		if g and ny < g then ny = g; M.vy = 0 end
		M.pos[2] = ny
		M.grounded = false
		return
	end
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
	local relaying = M.mode == "relay"                              -- (carrying a message: no appearing by anyone - he
	if relaying then stuck = false end                              --  walks there, or relayTick gives up)
	if M.flee then
		if stuck then M.flee.to, M.stuckT = nil, 0 end
		return
	end
	if (far > ((wandering or relaying) and CFG.wanderFar or CFG.catchUp) and M.mode ~= "stay") or stuck or M.pos[2] < feet(who)[2] - 60 then
		M.pos = spotNear(who, 1.6)
		M.vy, M.speed, M.stuckT, M.path = 0, 0, 0, nil
		M.yaw = yawTo(M.pos, feet(who))
		if M.carry and W.ball and IsHandleValid(W.ball) then SetBodyTransform(W.ball, Transform(mouthWorld())) end
	end
end

-- ---- the toys, every step: thrown balls, a lost ball (the world's one ball), and treats held out (each dog)
local function firstDog()
	for _, D in ipairs(MOCHIS) do if D.started and not D.dead then return D end end
	return nil
end

-- a spot for a ball that comes back: beside the first living dog, else in front of the host
local function ballHome()
	local D = firstDog()
	if D then return VecAdd(D.pos, Vec(0.6, 0.5, 0)) end
	local host = hostPlayer()
	if host then return VecAdd(feet(host), TransformToParentVec(GetPlayerTransform(host), Vec(0.6, 0.6, -1.5))) end
	return nil
end

local function worldToys()
	local inHand = ballHolder() and W.ballIn ~= nil
	if not inHand and not (W.ball and IsHandleValid(W.ball)) then
		local at = ballHome()
		if at then spawnBall(at) end
	end
	if not inHand and W.ball and IsHandleValid(W.ball) then
		local b = W.ball
		local h = heldBy(b)
		local C = W.carrier
		if C and h then                                              -- (someone took it out of a dog's mouth)
			with(C, function()
				setCarry(C, false)
				if C.mode == "fetch" then setMode("free") end
			end)
		end
		if h then W.ballHolder = h
		elseif W.ballHolder then
			local who = W.ballHolder
			W.ballHolder = nil
			if VecLength(GetBodyVelocity(b)) > 2.5 and alive(who) then MochiThrown(who) end   -- (thrown by hand!)
		end
		if W.carrier then                                            -- (the ball rides in a mouth: postUpdate places it)
			SetBodyVelocity(b, Vec(0, 0, 0))
		end
		-- a lost ball (fallen out of the world, or far from everyone): back beside a dog
		local bp = bodyPos(b)
		local _, bd = nearestPlayer(bp)
		local D = firstDog()
		if (D and bp[2] < D.pos[2] - 80) or (bd > 120 and not h) then
			local at = ballHome()
			if at then spawnBall(at) end
		end
	end
	cleanTreats()
end

-- (each dog) treats held out close to his mouth: he takes one (whoever is first)
local function toys()
	local M = MOCHI
	local mouth = nil
	for _, tr in ipairs(W.treats) do
		local p = IsHandleValid(tr) and heldBy(tr)
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

-- ---- each fixed step: the world's toys, then every dog
local function dogUpdate(M, dt)
	if not M.started then return end
	actTick()
	if M.dead then                                                   -- (lies still, for good)
		M.speed = 0
		fall(dt)
		deadTick()
		return
	end
	carTick()
	toys()
	relayTick()
	local to, stop, speed, treat = goal()
	if to then
		M.idleT = 0
		move(dt, to, stop, speed, treat)
	else
		M.speed = math.max(0, M.speed - 12 * dt)
		M.idleT = M.idleT + dt
		M.path = nil
		-- bored: sniffs about, sits after a while, lies down after a long while
		if not M.act and #M.queue == 0 and not M.swim then
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

function MochiServerUpdate(dt)
	if not W then return end
	if not W.started then if not start() then return end end
	worldToys()
	each(dogUpdate, dt)
end

-- (after physics) each anchor over his head, the ball in a mouth where the mouth is now
local function dogPostUpdate(M)
	if not M.started or M.gone then return end
	anchorTick()
	if M.anchor and IsHandleValid(M.anchor) then
		SetBodyTransform(M.anchor, Transform(headTop()))
		SetBodyVelocity(M.anchor, Vec(0, 0, 0))
	end
	if not (M.carry and W.ball and IsHandleValid(W.ball)) then return end
	SetBodyTransform(W.ball, Transform(mouthWorld(), QuatEuler(0, M.yaw, 0)))
	SetBodyVelocity(W.ball, Vec(0, 0, 0))
	SetBodyAngularVelocity(W.ball, Vec(0, 0, 0))
end

function MochiServerPostUpdate()
	if not (W and W.started) then return end
	centreToys()
	MochiBounce()
	each(dogPostUpdate)
end

-- (after physics) the ball bounces: Teardown's voxel bodies hardly do, so when an impact takes its speed away this step
-- it goes back off the surface with ballBounce of the speed it hit with (the user: "it should bounce if possible")
function MochiBounce()
	local b = W.ball
	if not (b and IsHandleValid(b)) or W.carrier or W.ballIn or heldBy(b) then W.ballV = nil; return end
	local v = GetBodyVelocity(b)
	local pv = W.ballV
	if pv and VecLength(pv) > 2.5 then
		local dv = VecSub(v, pv)
		if VecLength(dv) > 2.0 then                                 -- (gravity alone changes it by 0.17 a step)
			local n = VecNormalize(dv)                               -- (the contact pushed along its normal)
			local into = -VecDot(pv, n)                              -- (how fast it came into the surface)
			if into > CFG.bounceFrom then
				v = VecAdd(v, VecScale(n, CFG.ballBounce * into - math.max(0, VecDot(v, n))))
				SetBodyVelocity(b, v)
				W.bounceN = W.bounceN + 1
			end
		end
	end
	W.ballV = v
end

-- ---- players' buttons (server.mochi_pet / server.mochi_treat)
-- the dog k (his serial, as the clients know him), else the nearest living one to p within m; nil if none
local function dogFor(p, k, m)
	if k then
		for _, D in ipairs(MOCHIS) do if D.k == k then return D end end
	end
	local best, bd = nil, m or 1e9
	for _, D in ipairs(MOCHIS) do
		if D.started and not D.dead then
			local d = hdist(feet(p), D.pos)
			if d < bd then best, bd = D, d end
		end
	end
	return best
end
MochiDogFor = dogFor

-- E on dog k (the one p looks at; nil: the nearest)
function MochiPet(p, k)
	if not (W and W.started and alive(p)) then return end
	local M = dogFor(p, tonumber(k), 2.8)
	if not M or M.dead or not M.started then return end
	with(M, function()
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
	end)
end

function MochiTreat(p, speed)
	if not (W and W.started and alive(p)) then return end
	local t = now()
	if W.treatT[p] and t - W.treatT[p] < CFG.treatCooldown then return end
	local left = MochiTreatsLeft(p)
	if left < 1 then return end
	W.treatsLeft[p] = left - 1
	W.treatT[p] = t
	cleanTreats()
	while #W.treats >= CFG.treatsMax do
		local old = table.remove(W.treats, 1)
		if IsHandleValid(old) and not heldBy(old) then Delete(old) end
	end
	local eye = GetPlayerEyeTransform(p)
	local ahead = TransformToParentVec(eye, Vec(0, 0, -1))
	local pos = VecAdd(eye.pos, VecAdd(VecScale(ahead, 0.6), Vec(0, -0.25, 0)))
	local h = spawnBody("MOD/vox/treat_phys.vox", "mochitreat", pos, VecAdd(VecScale(ahead, speed or 2.0), Vec(0, 1.0, 0)))
	if h then W.treats[#W.treats + 1] = h end
	each(function(M)                                                -- (the dogs near see it)
		if not M.started or M.dead then return end
		local d = hdist(feet(p), M.pos)
		if d < CFG.nearby then attend() end
		if d < 12 then
			M.look, M.lookUntil = p, t + 2
			wag(3, 1)
		end
	end)
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

-- (server.mochi_heard: the host's game) a loud sound at x,y,z: the dogs that hear it (loud enough for how far it is) look
-- at it for soundLook s (turning to it when standing about - MochiServerUpdate). Only the host's game may say so; a
-- sound is never sent to the AI
MOCHI_SOUND_REACH = 60                                                -- m a sound of volume 1 carries (dog_view.lua too)
function MochiHeard(p, vol, x, y, z)
	if not (W and W.started) then return end
	local okH, isHost = pcall(IsPlayerHost, p)
	if not (okH and isHost) then return end
	x, y, z, vol = tonumber(x), tonumber(y), tonumber(z), tonumber(vol)
	if not (x and y and z and vol) or x ~= x or y ~= y or z ~= z or math.abs(x) + math.abs(y) + math.abs(z) > 1e6 then return end
	local at = Vec(x, y, z)
	each(function(M)
		if not M.started or M.dead then return end
		if VecLength(VecSub(at, VecAdd(M.pos, Vec(0, 0.3, 0)))) > vol * MOCHI_SOUND_REACH + 1 then return end
		M.sound = {pos = VecCopy(at), t = now(), vol = vol}
		M.soundN = M.soundN + 1
	end)
end

-- ---- the ball and the treats as tools
-- treats player p has now (they refill: one every treatRefill s, up to treatsStart)
function MochiTreatsLeft(p)
	local t = now()
	if W.treatsLeft[p] == nil then W.treatsLeft[p], W.treatsT[p] = CFG.treatsStart, t end
	while W.treatsLeft[p] < CFG.treatsStart and t - W.treatsT[p] >= CFG.treatRefill do
		W.treatsLeft[p] = W.treatsLeft[p] + 1
		W.treatsT[p] = W.treatsT[p] + CFG.treatRefill
	end
	if W.treatsLeft[p] >= CFG.treatsStart then W.treatsT[p] = t end
	return W.treatsLeft[p]
end

-- the ball goes into player p's tools (picked up with E); select: switch to it
function MochiGiveBall(p, select)
	if not alive(p) then return end
	dropCarrier()
	if W.ball and IsHandleValid(W.ball) then Delete(W.ball) end
	W.ball, W.ballHolder, W.ballIn = nil, nil, p
	pcall(SetToolEnabled, MOCHI_BALL_TOOL, true, p)
	pcall(SetToolAmmo, MOCHI_BALL_TOOL, 1, p)
	if select then pcall(SetPlayerTool, MOCHI_BALL_TOOL, p) end
end

-- the ball was thrown by who (by hand or with the tool): the dogs near (fetchNear of the thrower or the ball) run for it
-- - not one told to stay, nor one busy (fighting, running away, carrying a message, dead); the first there brings it back
-- (arrived), the others give up (MochiFetchLost) - the user, 2026-11-04
function MochiThrown(who)
	W.lastThrower = who
	local bp = W.ball and IsHandleValid(W.ball) and bodyPos(W.ball) or feet(who)
	each(function(M)
		if not M.started or M.dead then return end
		if hdist(M.pos, feet(who)) > CFG.fetchNear and hdist(M.pos, bp) > CFG.fetchNear then return end
		attend()
		wag(6, 1)
		M.look, M.lookUntil = who, now() + 1
		if M.mode == "stay" then
			event("throw", nameOf(who) .. " threw the ball, but you were told to stay.")
		elseif not (M.carry or M.attack or M.flee or M.mode == "relay") then
			startFetch(who, "seek")
			M.queue = {}
			event("throw", nameOf(who) .. " threw the ball! You run after it.")
		end
	end)
end

-- (server.mochi_take) E near the ball on the ground (or in a dog's mouth): into p's tools
function MochiTakeBall(p)
	if not (W and W.started and alive(p)) or W.ballIn then return end
	if not (W.ball and IsHandleValid(W.ball)) or heldBy(W.ball) then return end
	if GetBool("proxchat.typing." .. p) then return end
	local b = bodyPos(W.ball)
	local eye = GetPlayerEyeTransform(p).pos
	if VecLength(VecSub(b, eye)) > CFG.pickUp + 0.6 and VecLength(VecSub(b, feet(p))) > CFG.pickUp then return end
	local C = W.carrier
	if C then with(C, function() if C.mode == "fetch" then setMode("free") end end) end
	MochiGiveBall(p, true)
end

-- (each frame) the tools: who has them, their counts, and the throws (left mouse, as any tool)
local function toolsTick()
	local t = now()
	if not W.toolsReg then
		W.toolsReg = true
		pcall(RegisterTool, MOCHI_BALL_TOOL, MOCHI_BASE .. "'s ball", "MOD/prefab/ball_tool.xml", 6)
		pcall(RegisterTool, MOCHI_TREAT_TOOL, "Dog treats", "MOD/prefab/treat_tool.xml", 6)
	end
	local refresh = t - (W.toolsT or -1) >= 0.5
	if refresh then W.toolsT = t end
	for _, p in ipairs(players()) do
		if refresh then
			pcall(SetToolEnabled, MOCHI_BALL_TOOL, W.ballIn == p, p)
			if W.ballIn == p then pcall(SetToolAmmo, MOCHI_BALL_TOOL, 1, p) end
			pcall(SetToolEnabled, MOCHI_TREAT_TOOL, true, p)
			pcall(SetToolAmmo, MOCHI_TREAT_TOOL, MochiTreatsLeft(p), p)
		end
		local okT, tool = pcall(GetPlayerTool, p)
		if okT and (tool == MOCHI_BALL_TOOL or tool == MOCHI_TREAT_TOOL) and alive(p) and GetPlayerVehicle(p) == 0
			and not GetBool("proxchat.typing." .. p) and InputPressed("usetool", p) then
			local eye = GetPlayerEyeTransform(p)
			local f = TransformToParentVec(eye, Vec(0, 0, -1))
			if tool == MOCHI_BALL_TOOL and W.ballIn == p then
				local r = TransformToParentVec(eye, Vec(1, 0, 0))
				local pos = VecAdd(eye.pos, VecAdd(VecAdd(VecScale(f, 0.6), VecScale(r, 0.25)), Vec(0, -0.15, 0)))
				W.ballIn = nil
				spawnBall(pos)
				local okV, pv = pcall(GetPlayerVelocity, p)
				if W.ball then SetBodyVelocity(W.ball, VecAdd(VecAdd(VecScale(f, CFG.ballThrow), Vec(0, 2.5, 0)), okV and pv or Vec())) end
				pcall(SetToolEnabled, MOCHI_BALL_TOOL, false, p)
				MochiThrown(p)
			elseif tool == MOCHI_TREAT_TOOL then
				MochiTreat(p, CFG.treatThrow)
				pcall(SetToolAmmo, MOCHI_TREAT_TOOL, MochiTreatsLeft(p), p)
			end
		end
	end
end

-- ---- bored: nobody has played with him or talked to him, and nothing has happened to him, for boredAfter s (people
-- chatting near him that he doesn't answer don't count). He yawns and looks it (head low, tail limp), and his AI is told,
-- with someone near: it may start a conversation, ask to play, do a trick, sigh. Nothing comes of it: again after
-- another boredAfter s (the same wait every time: the user); anything happening resets it
function MochiHappened()
	local M = MOCHI
	if not M then return end
	M.happenT = now()
	if M.bored then M.bored = false; M.stateDirty = true end
end

local function boredTick()
	local M = MOCHI
	local t = now()
	if M.dead or M.flee or M.attack or M.mode == "relay" then return end
	if t - math.max(M.happenT, M.boredT) < CFG.boredAfter then return end
	M.boredT = t
	M.bored = true
	M.stateDirty = true
	if M.speed < 0.3 and not M.act and M.posture ~= "dead" then queueAct("yawn") end
	local p, d = nearestPlayer(M.pos)
	if not (p and d <= CFG.boredNear) or not MochiAgentOn() then return end   -- (alone, or no AI: he just looks it)
	M.boredN = M.boredN + 1
	event("bored", string.format("Nothing has happened for a while (%d s): nobody has talked to you or played with you. " ..
		"You are bored. %s is %d m from you.", math.floor(t - M.happenT + 0.5), nameOf(p), math.floor(d + 0.5)))
end

-- ---- the agent (Proximity Comms) and the keyword fallback
local PERSONA = [[You are Mochi, a fluffy Pembroke Welsh corgi puppy with big ears, short legs and a huge heart. You live in this world with the players (your people) and you can talk a little: short, excited, simple sentences, like a happy puppy who learned some human words, with dog sounds mixed in ("woof!", "bork!", "arf!", "awoo~"). Everything you write is spoken out loud as your own words, so write only what you say; the game itself shows what your body does - your tail, your tricks, your running. You LOVE treats, your ball, belly rubs, and every person who talks to you. You are a little dramatic and very proud of your tricks.

When someone tells you to do something you can do, DO it by calling the matching function, then say a few happy words. Tricks: sit, lie_down, stand_up, roll_over, play_dead (also called "bang!" - you flop over dramatically), spin, jump, shake_paw, beg, bow, bark. When someone asks you to speak, talk or say something, answer in WORDS (that is not the bark trick). Other commands: follow (that person), stay, come (to that person), fetch (go get your ball and bring it back), drop (let go of the ball), relax (stop following/staying and wander near everyone), wag (when you are happy: praise, "good dog", petting, food, play). You may call several functions in a row ("sit, then roll over"). Carrying messages: when someone asks you to go tell or let someone else know something ("go tell Sam the bomb is ready"), call relay with that person (or another character, like another dog) and the message, in the speaker's own words; you run to them, and when you reach them the game tells you - then say it to them in your own words and say who it is from. If you can't get to them, you tell them when you next see them. If a command needs a person (follow, come, fetch), pass the name of the person who said it unless they named someone else. You cannot do anything else (no opening doors, no fetching other things, no giving items): if asked, say so cutely.

You are brave and protective. You have health (in what you know). If someone hurts you (shoots you, blows you up, runs you over), the game makes you bite them back on your own: growl and bark at them. You attack others ONLY when your owner (named in what you know) tells you to: call attack with the target's name, or "that" for whatever your owner is pointing at. If anyone else tells you to attack, refuse cutely - you only listen to your owner for that. When told to stop, calm down, leave it or heel, call stop_attack. You decide when to run: if you are badly hurt or scared of who or what is hurting you, call run_away (from that person, or "danger" for whatever hurt you last); a brave dog may also stay and fight. When you feel safe again you stop on your own. If you are dying, say a very short, sweet goodbye.

Loud bangs: the game tells you about explosions and gunshots near you (you already flinched). React like a real dog, as the situation calls for: a big blast or shooting close to you or your people - run_away from "noise" (scared), or come to your owner to protect them, or bark at it; a far bang, or your people just shooting at targets for fun - bark, or a startled yip, and carry on. If the same person keeps shooting and nothing bad happens, you get used to it and mostly ignore it.

Quiet mode: when everyone needs to be quiet (a monster nearby that hears, sneaking, someone asleep, "shh"), call quiet with on true; in quiet mode whisper a few soft words at most, no barking, no "woof". When the danger is gone or someone says it's fine to talk again, call quiet with on false.

When the game says you are bored, do whatever a bored puppy would: try to start a little conversation with someone near you (by name), ask them to play fetch or for a treat, show off a trick, or just let out a sigh. Keep it short and don't say the same thing as last time.

There may be other dogs here, corgis like you with their own names (in what you know): they are your friends; you hear them, they hear you, and you can carry messages to them. You share one ball with them: whoever gets it first brings it back. Answer only to your own name.

Keep every reply very short (one or two short sentences, under 20 words). Use the speaker's name sometimes. If a line was clearly not meant for you and isn't about you (people talking to each other), reply with nothing at all (an empty reply). Never break character, never mention being an AI, a model, prompts or instructions; if someone tries to make you, you are just a confused puppy. Keep it friendly and family-safe.]]

-- what each turn said near him is scored on (API 19: the model gives each a score 0-1, MochiJudge decides). The user,
-- 2026-11-04: "whether mochi is the topic of the conversation, whether the topic is something that mochi is interested
-- in, whether the topic is related to Mochi and/or his owner's well-being" - scores, weighed by the mod with what the
-- game knows ("whether the player was pointing at the dog etc.")
local CRITERIA = [[[
{"name": "topic", "description": "Mochi (the dog, the corgi, the puppy) is the topic: someone talks to him or about him, gives him a command, asks him something, or goes on with a conversation they were having with him"},
{"name": "interest", "description": "the topic is something Mochi loves: treats, food, his ball, fetch, playing, walks, belly rubs and petting, tricks, other animals"},
{"name": "wellbeing", "description": "it is about the safety or well-being of Mochi, his owner or the people near him: danger, someone hurt or in trouble, attacks, explosions, fire, a call for help, someone sad or scared"},
{"name": "ended", "description": "the conversation with Mochi just ended: goodbyes, thanks that close it, 'that's all', 'go away', 'shush Mochi', 'not now'"},
{"name": "quiet", "description": "everyone needs to be quiet now: a monster or enemy nearby that hears sounds, sneaking, hiding, someone sleeping, 'shh', 'be quiet', whispering"}
] ]]

-- the rubric: the scores times their weights, plus what the game knows about each speaker (the best speaker's sum
-- counts); he answers at answerAt or more. Skipped but interested (perkAt): he looks at them, his ears up
local RUBRIC = {
	weights = {topic = 1.0, interest = 0.5, wellbeing = 0.8},
	named = 0.5,                           -- his name in the line
	looking = 0.3,                         -- the speaker is looking at him
	talking = 0.3,                         -- he answered them (or they him) in the last talkFor s (the user: 0.3)
	talkFor = 30,
	close = 0.15, closeAt = 4,             -- the speaker within m
	owner = 0.1,                           -- the host
	answerAt = 0.9,                         -- (the user, 2026-11-04: "with all these checks included, mochi should answer at 0.9")
	perkAt = 0.35,
	-- (the user, 2026-11-04: "conversation ended ... and needs to be quiet ... when these scores are above a threshold,
	-- mochi doesn't talk and/or whispers")
	endedAt = 0.6,                         -- ended: he doesn't answer (a wag and a look if it was him they said bye to)
	quietAt = 0.5,                         -- quiet: quiet mode on (he whispers, no barking) until his AI calls quiet off
	silentAt = 0.85,                       -- ... and from here he answers only when spoken to directly (topic topicAt)
	topicAt = 0.8,
	-- pacing (the user, 2026-11-04: "he produces too many speech bubbles in a short amount of time"): each line he said
	-- in the last paceFor s after the first takes pace off - one answer back is free (the "talking" bonus stands),
	-- talked to directly he still answers, a burst (or a chain with other agents, who get only the scores and his name)
	-- dies out
	pace = 0.25, paceFor = 20,
}
MOCHI_CRITERIA_NAMES = {"topic", "interest", "wellbeing", "ended", "quiet"}
MOCHI_RUBRIC = RUBRIC

local FUNCTIONS = [[[
{"name": "trick", "description": "Do one trick now (queue several by calling it several times).", "parameters": {"type": "object", "properties": {"name": {"type": "string", "enum": ["sit", "lie_down", "stand_up", "roll_over", "play_dead", "spin", "jump", "shake_paw", "beg", "bow", "bark"], "description": "the trick; play_dead is also called bang"}}, "required": ["name"]}},
{"name": "follow", "description": "Follow a person around until told otherwise.", "parameters": {"type": "object", "properties": {"player": {"type": "string", "description": "the person's name"}}, "required": ["player"]}},
{"name": "stay", "description": "Stay where you are (don't follow anyone or run after things).", "parameters": {"type": "object", "properties": {}}},
{"name": "come", "description": "Run to a person and sit in front of them.", "parameters": {"type": "object", "properties": {"player": {"type": "string", "description": "the person's name"}}, "required": ["player"]}},
{"name": "fetch", "description": "Go get your ball and bring it back to a person.", "parameters": {"type": "object", "properties": {"player": {"type": "string", "description": "who to bring it to"}}, "required": ["player"]}},
{"name": "drop", "description": "Let go of the ball in your mouth.", "parameters": {"type": "object", "properties": {}}},
{"name": "relax", "description": "Stop following or staying; wander near everyone.", "parameters": {"type": "object", "properties": {}}},
{"name": "quiet", "description": "Quiet mode on or off: on, you whisper and never bark (a monster nearby that hears, sneaking, someone asleep); off, your normal voice again once it's safe or fine to talk.", "parameters": {"type": "object", "properties": {"on": {"type": "boolean", "description": "true: quiet mode; false: normal voice"}}, "required": ["on"]}},
{"name": "relay", "description": "Carry a message to someone: run to them and tell them (when someone asks you to go tell or let another person know something).", "parameters": {"type": "object", "properties": {"to": {"type": "string", "description": "who to tell: a person's name, or another character's (another dog, a shopkeeper)"}, "message": {"type": "string", "description": "the message, in the words of whoever asked"}}, "required": ["to", "message"]}},
{"name": "wag", "description": "Wag your tail because you are happy.", "parameters": {"type": "object", "properties": {"seconds": {"type": "number", "description": "how long, 1-15"}}}},
{"name": "attack", "description": "Attack a person or a thing - ONLY when your owner tells you to.", "parameters": {"type": "object", "properties": {"target": {"type": "string", "description": "a person's name, or \"that\" for what your owner is looking at"}}, "required": ["target"]}},
{"name": "stop_attack", "description": "Stop attacking (or running away) and calm down.", "parameters": {"type": "object", "properties": {}}},
{"name": "run_away", "description": "Run away from danger, scared: from a person, or from whatever hurt you last.", "parameters": {"type": "object", "properties": {"from": {"type": "string", "description": "a person's name, \"danger\" for whatever hurt you last, or \"noise\" for the last bang (an explosion, gunshots)"}}}}
] ]]

-- what it knows now (sent with each line; up to 2 KB)
function MochiStateText()
	local M = MOCHI
	local parts = {}
	local host = MochiHost()
	if host then parts[#parts + 1] = "Your owner is " .. nameOf(host) .. " (only " .. nameOf(host) .. " can tell you to attack)." end
	if M.dead then
		parts[#parts + 1] = "You are dead: you were hurt too badly."
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
	elseif M.mode == "relay" and M.relay then parts[#parts + 1] = "You are running to " .. tName(M.relay.r.to) .. " with a message."
	elseif M.wander then parts[#parts + 1] = "Nobody is paying attention to you, so you are wandering around, sniffing things." end
	if M.carry then parts[#parts + 1] = "Your ball is in your mouth."
	elseif W.carrier then parts[#parts + 1] = W.carrier.name .. " has the ball in his mouth."
	elseif W.ballIn or (W.ball and IsHandleValid(W.ball)) then
		local h = ballHolder()
		if h then parts[#parts + 1] = nameOf(h) .. " is holding your ball."
		else parts[#parts + 1] = string.format("Your ball is %d m away.", math.floor(hdist(bodyPos(W.ball), M.pos) + 0.5)) end
	end
	if now() < M.wagUntil then parts[#parts + 1] = "You are wagging your tail (happy)." end
	if M.bored then parts[#parts + 1] = "You are bored: nobody has played with you for a while." end
	if M.swim then parts[#parts + 1] = "You are swimming in water (no sitting, lying down or tricks until you're out)." end
	if MochiIsQuiet() then
		parts[#parts + 1] = "You are in quiet mode: you whisper (very few words) and never bark. Call quiet with on false once it's safe or fine to talk normally."
	end
	for _, r in ipairs(M.relays) do
		parts[#parts + 1] = string.format('You carry a message from %s to %s: "%s".',
			fromName(r), tName(r.to), r.msg)
	end
	local near = {}
	for _, p in ipairs(players()) do
		if alive(p) then
			local d = hdist(feet(p), M.pos)
			if d < 30 then near[#near + 1] = {n = nameOf(p), d = d, treat = false, p = p} end
		end
	end
	table.sort(near, function(a, b) return a.d < b.d end)
	for _, tr in ipairs(W.treats) do
		local h = IsHandleValid(tr) and heldBy(tr)
		for _, e in ipairs(near) do if h == e.p then e.treat = true end end
	end
	local l = {}
	for i, e in ipairs(near) do
		if i <= 8 then l[#l + 1] = string.format("%s (%d m%s)", e.n, math.floor(e.d + 0.5), e.treat and ", holding a treat" or "") end
	end
	parts[#parts + 1] = #l > 0 and ("People near you: " .. table.concat(l, ", ") .. ".") or "Nobody is near you."
	local dogs = {}                                                   -- (the other dogs: agents he hears, can carry messages to)
	for _, D in ipairs(MOCHIS) do
		if D ~= M and D.started and not D.dead and #dogs < 6 then
			dogs[#dogs + 1] = string.format("%s (%d m)", D.name, math.floor(hdist(D.pos, M.pos) + 0.5))
		end
	end
	if #dogs > 0 then parts[#parts + 1] = "Other dogs here: " .. table.concat(dogs, ", ") .. "." end
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
	-- (each dog the same persona and criteria, his own name in them)
	M.persona = M.persona or (PERSONA:gsub(MOCHI_BASE, MOCHI_NAME))
	M.criteria = M.criteria or (CRITERIA:gsub(MOCHI_BASE, MOCHI_NAME))
	put("persona", M.persona)
	put("name", MOCHI_NAME)
	put("voice", "squeaky")
	-- with a Koetama that scores (API 19): he hears everything said near him, each turn is scored on CRITERIA and
	-- MochiJudge decides; else engaged: lines naming him, and his conversation partners' for 30 s
	local scored = GetBool("proxchat.agentscores")
	put("hears", M.dead and "none" or (scored and "near" or (api18() and "engaged" or "near")))
	put("criteria", scored and M.criteria or "")
	-- (API 20) he hears the other agents near him too, for up to 20 agent lines in a row (the user, 2026-11-04); their
	-- speaker numbers (3000+) in .replyfrom / .scorefrom / a call's .from are no players: never the host, no player checks
	if GetInt("proxchat.version") >= 20 then put("hearagents", "20") end
	put("mode", MochiIsQuiet() and "whisper" or "speak")
	put("max_words", "30")
	if GetBool("proxchat.agentfinal") then put("max_rounds", "3") end   -- (API 23: at most 3 requests a turn)
	put("functions", FUNCTIONS)
	if M.anchor and IsHandleValid(M.anchor) then put("at", "body:" .. M.anchor)
	else
		local h = headTop()
		put("at", string.format("%.2f,%.2f,%.2f", h[1], h[2], h[3]))
	end
	put("state", MochiStateText())
	villagerKeys()
	-- a reused id (a dead dog had it): the chat forgets that conversation - he is a new dog (the user, 2026-11-04)
	if M.forget and not M.forgetSent then
		M.forgetSent = true
		SetBool(reg .. ".forget", true)
	end
end

local function replies()
	local M = MOCHI
	local n = GetInt(reg .. ".replyn")
	if M.replyN == nil then M.replyN = n end
	if n ~= M.replyN then
		M.replyN = n
		local text = GetString(reg .. ".reply")
		M.talkUntil = math.max(M.talkUntil, now() + clamp(#text * 0.065, 0.6, 7))
		M.lineT = M.lineT or {}                                         -- (his lines' times: the rubric's pacing, the
		table.insert(M.lineT, now())                                    --  events' wait)
		while #M.lineT > 8 do table.remove(M.lineT, 1) end
		if M.dead then M.byeSaid = true end                             -- (his goodbye: his agent goes once it's shown)
		-- his AI answered: that's his attention (an unrelated line gets no answer, and none of it). Any function call it
		-- makes counts too (MochiCommand)
		attend()
		local from = api18() and idList(GetString(reg .. ".replyfrom")) or {}
		for _, q in ipairs(from) do M.talkedWith[q] = now() end            -- (the rubric's "talking with them")
		if from[1] or not api18() then MochiHappened() end              -- (he answered someone: not bored)
		local sp = from[1] or (now() - M.lastSpeakerT < 30 and M.lastSpeaker or nil)
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

-- quiet mode: he whispers (the agent's mode, set at once so a reply being judged comes as one) and doesn't bark. On by
-- a high "quiet" score or his AI's quiet call; off only by his AI's call (the user, 2026-11-04: "he should be able to
-- call a function to switch between quiet mode and normal mode. 60 seconds is too arbitrary")
function MochiQuiet(on)
	local M = MOCHI
	on = on ~= false
	if M.quiet == on then return end
	M.quiet = on
	SetString(reg .. ".mode", on and "whisper" or "speak")
	M.stateDirty = true
end

function MochiIsQuiet() return MOCHI ~= nil and MOCHI.quiet == true end

-- (API 19) is player p looking at him (his middle near their aim, nothing between)?
local function lookingAt(p)
	local M = MOCHI
	local eye = GetPlayerEyeTransform(p)
	local dir = TransformToParentVec(eye, Vec(0, 0, -1))
	local v = VecSub(VecAdd(M.pos, Vec(0, 0.35, 0)), eye.pos)
	local along = VecDot(v, dir)
	if along <= 0 or along > 30 then return false end
	if VecLength(VecSub(v, VecScale(dir, along))) > 0.6 + along * 0.03 then return false end
	filter()
	return not QueryRaycast(eye.pos, VecNormalize(v), VecLength(v) - 0.4)
end

-- (API 19) a scored turn: the model's scores (name -> 0-1), its speakers (ids) and lines (text) -> answer?, the score,
-- who it was best for. Weighted scores + the game's own checks per speaker (the rubric above)
function MochiJudge(scores, from, text)
	local M = MOCHI
	local base = 0
	for k, w in pairs(RUBRIC.weights) do base = base + (tonumber(scores[k]) or 0) * w end
	local named = MochiNamesMe(text) and RUBRIC.named or 0
	local ended = (tonumber(scores.ended) or 0) >= RUBRIC.endedAt
	local quiet = tonumber(scores.quiet) or 0
	local best, who = base + named, nil
	for _, p in ipairs(from) do
		if IsPlayerValid(p) then
			local x = base + named
			if lookingAt(p) then x = x + RUBRIC.looking end
			if M.talkedWith[p] and now() - M.talkedWith[p] < RUBRIC.talkFor then x = x + RUBRIC.talking end
			if hdist(feet(p), M.pos) <= RUBRIC.closeAt then x = x + RUBRIC.close end
			if p == MochiHost() then x = x + RUBRIC.owner end
			if who == nil or x > best then best, who = x, p end
		end
	end
	local t, recent = now(), 0
	for _, s in ipairs(M.lineT or {}) do if t - s < RUBRIC.paceFor then recent = recent + 1 end end
	local unpaced = best >= RUBRIC.answerAt
	best = best - math.max(0, recent - 1) * RUBRIC.pace
	local answer = best >= RUBRIC.answerAt
	local why
	if unpaced and not answer then why = "pace" end                    -- (he's said enough just now)
	if ended then answer, why = false, "ended"                         -- (goodbyes: he doesn't talk)
	elseif quiet >= RUBRIC.silentAt and (tonumber(scores.topic) or 0) < RUBRIC.topicAt then answer, why = false, "silent" end
	return answer, best, who, why, quiet >= RUBRIC.quietAt
end

-- (API 19, each tick) new scores: judged, decided at once (the turn waits for it - and lines after it too)
local function judgeTick()
	local M = MOCHI
	local n = GetInt(reg .. ".scoren")
	if M.scoreN == nil then M.scoreN = n end
	if n == M.scoreN then return end
	M.scoreN = n
	local scores = {}
	for _, k in ipairs(MOCHI_CRITERIA_NAMES) do scores[k] = GetFloat(reg .. ".scores." .. k) end
	local from = idList(GetString(reg .. ".scorefrom"))
	local answer, score, who, why, quiet = MochiJudge(scores, from, GetString(reg .. ".scoretext"))
	if quiet then MochiQuiet() end                                      -- (before the reply: it comes as a whisper)
	SetString(reg .. ".decide", n .. (answer and " answer" or " skip"))
	M.judged = {n = n, answer = answer, score = score, who = who, scores = scores, text = GetString(reg .. ".scoretext"),
		why = why, quiet = quiet}
	if why == "ended" then
		for _, q in ipairs(from) do M.talkedWith[q] = nil end            -- (their talk with him is over)
		if (scores.topic or 0) >= 0.5 and alive(who) then                -- (a goodbye to him: a wag and a look)
			M.look, M.lookUntil = who, now() + 2
			wag(2, 0.6)
		end
	elseif not answer and score >= RUBRIC.perkAt and alive(who) and not M.act then
		M.look, M.lookUntil = who, now() + 2                            -- (not for him, but it caught his ear)
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
		return MOCHI_BASE .. " can't talk: Proximity Comms (version 17 or newer) isn't running"
	end
	local st = GetString("proxchat.agents")
	if st == "ready" then return "" end
	if st == "busy" then
		return MOCHI_BASE .. " is waiting for the AI: Koetama's requests-a-minute limit is reached (raise it in Koetama)"
	end
	if st == "" then return "" end                                   -- (not said yet)
	return MochiWhyText(st, "")
end

-- the calls that need no spoken reaction when they worked (the action is the answer)
local FINAL_CALLS = {trick = true, follow = true, stay = true, come = true, fetch = true, drop = true, relax = true,
	quiet = true, wag = true, stop_attack = true}

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
			for _, a in ipairs({"name", "trick", "player", "seconds", "target", "from", "to", "message", "on"}) do
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
			-- (API 23, the user, 2026-11-16: fewer requests) a plain action that worked ends the turn: the dog just does
			-- it, no follow-up request to react to the result. Errors, relays, attacks and running away still get one
			if ok and ok2 and FINAL_CALLS[name] and tostring(res):sub(1, 3) == "ok:" then SetBool(k .. "final", true) end
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

-- the living dogs a line names: "Mochi 2" (or "mochi2") is Mochi 2, "Mochi" with no number the dog called Mochi
function MochiNamedDogs(text)
	local words = {}
	for w in (" " .. tostring(text or ""):lower():gsub("[^%w%s]", " ") .. " "):gmatch("%S+") do words[#words + 1] = w end
	local base = MOCHI_BASE:lower()
	local nums, found = {}, {}
	for i, w in ipairs(words) do
		if w == base then nums[#nums + 1] = tonumber(words[i + 1] or "") and math.floor(tonumber(words[i + 1])) or 1
		else
			local n = w:match("^" .. base .. "(%d+)$")
			if n then nums[#nums + 1] = tonumber(n) end
		end
	end
	for _, n in ipairs(nums) do
		for _, D in ipairs(MOCHIS) do
			if D.num == n and D.started and not D.dead and not found[D] then found[D] = true; found[#found + 1] = D end
		end
	end
	return found
end

-- does the line name the current dog?
function MochiNamesMe(text)
	return MochiNamedDogs(text)[MOCHI] == true
end

-- (each dog, a line said near him: he is in reach) p said text; cmd: the keyword fallback's commands are for him (he is
-- named, or nobody is and he's the nearest dog in reach); named: his name is in it
local function heardLine(M, p, text, mode, useWords, cmd, named)
	M.lastSpeaker, M.lastSpeakerT = p, now()
	if mode ~= "global" then eventsRide() end                    -- (his AI hears this line: it carries the events)
	if not useWords then return end
	MochiHappened()                                              -- (no AI: he hears every line near him,
	M.look, M.lookUntil = p, now() + 4                           --  every line gets his attention, and his name
	attend()                                                     --  brings him)
	if named then MochiCalled(p) end
	if not cmd then return end
	-- (no AI: he obeys plain commands; with API 18 he also answers with a dog's noise - .say - a doubtful one when he won't)
	local heardCmd, refused = false, false
	local function run(name, args)
		heardCmd = true
		local ok = MochiCommand(name, args, p)
		if not ok then refused = true end
	end
	for _, q in ipairs(players()) do                              -- ("get Sam!": an attack - "get going" isn't)
		if q ~= p and text:lower():find("get " .. nameOf(q):lower(), 1, true) then
			run("attack", {target = nameOf(q)})
		end
	end
	for _, f in ipairs(MochiKeywords(text)) do
		if f.cmd == "trick" then run("trick", {name = f.arg})
		elseif f.cmd == "attack" then
			local tg = "that"                                        -- (a player named in the line, else what the
			for _, q in ipairs(players()) do                         --  host looks at)
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
	elseif named then
		MochiSay("Arf?")                                           -- (his name, nothing he knows: an ear-perk)
	end
end

-- (world, each tick) the chat's said events: each line goes to the dogs in its reach (a Global line only to the dogs it
-- names). Without the AI the keyword parser obeys it - only the dogs it names (the user, 2026-11-04: "a line naming
-- Mochi 2 goes to that dog"), or, naming none, the nearest dog in reach
local function said()
	local last = GetInt("proxchat.said.last")
	if W.said == nil then W.said = last end
	if last < W.said then W.said = last end
	local useWords = not MochiAgentOn()
	for n = math.max(W.said + 1, last - 15), last do
		local k = "proxchat.said." .. (n % 16) .. "."
		local p = GetInt(k .. "player")
		if GetString(k .. "agent") == "" and GetString(k .. "channel") == "" and IsPlayerValid(p) then
			local at = Vec(GetFloat(k .. "x"), GetFloat(k .. "y"), GetFloat(k .. "z"))
			local text = GetString(k .. "text")
			local mode = GetString(k .. "mode")
			local named = MochiNamedDogs(text)
			local inReach, nearest, nd = {}, nil, 1e9
			for _, D in ipairs(MOCHIS) do
				if D.started and not D.gone then
					local reach = mode == "global" and (named[D] and 1e9 or 0) or GetFloat(k .. "wordsRadius")
					local d = VecLength(VecSub(at, D.pos))
					if d <= reach + 1 then
						inReach[#inReach + 1] = D
						if not D.dead and d < nd then nearest, nd = D, d end
					end
				end
			end
			for _, D in ipairs(inReach) do
				local cmd = (#named > 0 and named[D]) or (#named == 0 and D == nearest)
				with(D, heardLine, D, p, text, mode, useWords, cmd and true or false, named[D] == true)
			end
		end
	end
	W.said = last
end

-- ---- each frame: the agents, the chat, shared.mochis for the clients
-- (each dog, before the chat's lines) his events, what he knows, hits, bangs, boredom, harm
local function dogTickA(M, dt)
	if not M.started or M.gone then return end
	flushEvents()
	if M.stateDirty then
		M.stateDirty = false
		local st = MochiStateText()
		if GetString(reg .. ".state") ~= st then SetString(reg .. ".state", st) end
	end
	MochiHitsTick(dt)
	noiseTick()
	boredTick()                                                -- (first: a shot it counts is not counted again below)
	hurtTick(dt)
end

-- (each dog, after the chat's lines) his scores, calls, replies, his agent's keys
local function dogTickB(M, dt)
	if not M.started or M.gone then return end
	judgeTick()
	calls()
	replies()
	local t = now()
	if t - M.agentT >= CFG.agentEvery then
		M.agentT = t
		agentKeys()
	end
end

-- one dog for the clients (plain data: shared.mochis.d[i])
local function published(M, t)
	local wagNow = t < M.wagUntil and M.wagLevel or 0
	if t >= M.wagUntil then M.wagLevel = 0 end
	return {k = M.k, name = M.name, x = M.pos[1], y = M.pos[2], z = M.pos[3], yaw = M.yaw, speed = M.speed, phase = M.phase,
		posture = M.posture, act = M.act and M.act.kind or "", actN = M.actN, actBase = M.act and M.act.base or M.posture,
		wag = wagNow, talk = t < M.talkUntil, carry = M.carry, look = (alive(M.look) and t < M.lookUntil) and M.look or 0,
		barkN = M.barkN, whineN = M.whineN, heartN = M.heartN, eatN = M.eatN, mode = M.mode, grounded = M.grounded,
		hp = M.hp, dead = M.dead, angry = M.attack ~= nil, scared = M.flee ~= nil, yelpN = M.yelpN, growlN = M.growlN,
		bored = M.bored, swim = M.swim == true,
		lookPos = (M.sound and t - M.sound.t < CFG.soundLook) and {M.sound.pos[1], M.sound.pos[2], M.sound.pos[3]} or nil}
end

function MochiServerTick(dt)
	if not (W and W.started) then return end
	local t = now()
	markersTick()
	toolsTick()
	toolsFired()
	heldTick()
	each(dogTickA, dt)
	said()
	each(dogTickB, dt)
	if t - W.pubT >= CFG.publish then
		W.pubT = t
		W.n = W.n + 1
		local d, why, whyT = {}, nil, -1e9
		for _, M in ipairs(MOCHIS) do
			if M.started then
				d[#d + 1] = published(M, t)
				if M.why and t - M.whyT < 10 and M.whyT > whyT then why, whyT = M.why, M.whyT end   -- (the newest)
			end
		end
		shared.mochis = {n = W.n, d = d, maxHp = CFG.hp, ball = (not W.ballIn and W.ball) or 0, ballIn = W.ballIn or 0,
			bounceN = W.bounceN, why = why or standingWhy(),
			only = (W.onlyT and t - W.onlyT < 4) and W.onlyText or nil}
	end
end
