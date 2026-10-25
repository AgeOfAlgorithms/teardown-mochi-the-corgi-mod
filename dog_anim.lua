-- Mochi the Corgi: procedural animation (hand-written). Include dog_rig.lua BEFORE this file. No #version line
-- (included). Pure: plain math + the Vec / Quat / Transform constructors only, no engine state - the server runs it too
-- (where a carried ball sits) and the offline test runs it without the game.
--
-- Defines only globals:
--   DogPose(a, out)  fills out[partName] = Transform(centre, rot): each part's .vox CENTRE and rotation in the dog's
--                    ROOT frame (origin = ground point under the dog, +y up, +z forward = the nose, +x = the dog's left).
--                    Existing out[] transforms are updated in place. Also out.__mouth = Vec, where a carried ball sits.
--   a = {st, t, base, phase, speed, wag, talk, carry, angry, time, lookYaw, lookPitch}:
--     st     a state of DOG_STATES (unknown -> "stand"); t = seconds in it
--     base   the posture under a one-shot act ("stand" / "sit" / "lie"): bark, wiggle and eat start from it
--     phase  gait phase (radians), advanced by distance: phase = phase + dist / DogStride(speed) * 2 * pi
--     speed  m/s on the ground (walk / trot / the gallop's zoomies)
--     wag    0..1: how hard the tail wags (and the butt wiggles with it)
--     talk   0..1: the jaw flaps (a reply being said)
--     carry  true: the jaw holds the ball
--     angry  0..1: attacking - head low, lips back (the jaw a little open), tail up and stiff
--     scared 0..1: running away - tail tucked down, head low, crouched a little, no wag
--     time   GetTime() (wag, breathing, panting)
--     lookYaw, lookPitch  degrees the head turns toward someone (+yaw = to the dog's left, +pitch = up); clamped
--   DOG_STATES     every state DogPose knows
--   DOG_ACTS       one-shot acts: {dur = s, after = the posture left at the end}
--   DogStride(speed)  metres per gait cycle
--
-- Conventions: a part's local rotation is in its PARENT's frame about its own pivot. pitch about +x: positive tips
-- the nose DOWN and swings a hanging leg BACK; yaw about +y: positive turns toward +x (the dog's left); roll about +z:
-- positive moves a hanging leg toward +x. The whole-dog motion ("root") is a rotation about a point plus a lift.

DOG_STATES = {"stand", "walk", "sit", "lie", "dead", "roll_over", "play_dead", "spin", "jump", "shake_paw", "beg", "bow",
	"bark", "eat", "wiggle", "stand_up", "sit_down", "lie_down", "bite", "flinch", "die", "sniff"}
DOG_ACTS = {
	sit_down = {dur = 0.35, after = "sit"}, lie_down = {dur = 0.45, after = "lie"}, stand_up = {dur = 0.35, after = "stand"},
	roll_over = {dur = 1.8, after = "lie"}, play_dead = {dur = 0.6, after = "dead"}, spin = {dur = 1.4, after = "stand"},
	jump = {dur = 0.9, after = "stand"}, shake_paw = {dur = 2.6, after = "sit"}, beg = {dur = 3.0, after = "sit"},
	bow = {dur = 1.8, after = "stand"}, bark = {dur = 1.1, after = nil}, eat = {dur = 1.5, after = nil},
	wiggle = {dur = 1.6, after = nil},
	bite = {dur = 0.5, after = "stand"}, flinch = {dur = 0.35, after = nil}, die = {dur = 0.9, after = "dead"},
	sniff = {dur = 2.2, after = nil},
}

local rad, sin, cos, abs, sqrt, floor = math.rad, math.sin, math.cos, math.abs, math.sqrt, math.floor
local pi = math.pi

local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
local function smooth(x) x = clamp(x, 0, 1) return x * x * (3 - 2 * x) end
local function lerp(a, b, s) return a + (b - a) * s end

function DogStride(speed)
	if not speed or speed < 0.1 then return 0.5 end
	if speed < 2.5 then return 0.45 + speed * 0.06 end            -- (walk: short corgi steps)
	return clamp(0.6 + (speed - 2.5) * 0.12, 0.6, 1.2)               -- (trot -> gallop)
end

-- ---- quaternions as plain numbers {x, y, z, w}
local function qmul(a, b)
	return a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2], a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
		a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4], a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3]
end
local function qrot(q, x, y, z)
	local qx, qy, qz, qw = q[1], q[2], q[3], q[4]
	local tx = 2 * (qy * z - qz * y); local ty = 2 * (qz * x - qx * z); local tz = 2 * (qx * y - qy * x)
	return x + qw * tx + (qy * tz - qz * ty), y + qw * ty + (qz * tx - qx * tz), z + qw * tz + (qx * ty - qy * tx)
end
-- Ry(yaw) * Rx(pitch) * Rz(roll), degrees
local function euler(pitch, yaw, roll)
	local hp, hy, hr = rad(pitch or 0) / 2, rad(yaw or 0) / 2, rad(roll or 0) / 2
	local Y = {0, sin(hy), 0, cos(hy)}
	local X = {sin(hp), 0, 0, cos(hp)}
	local Z = {0, 0, sin(hr), cos(hr)}
	local a, b, c, d = qmul(Y, X)
	return {qmul({a, b, c, d}, Z)}
end

-- a frame = {q = quat, p = {x, y, z}}: a point x goes to q * x + p
local function compose(F, G)                                     -- F * G
	local x, y, z = qrot(F.q, G.p[1], G.p[2], G.p[3])
	return {q = {qmul(F.q, G.q)}, p = {F.p[1] + x, F.p[2] + y, F.p[3] + z}}
end
local function apply(F, v)
	local x, y, z = qrot(F.q, v[1], v[2], v[3])
	return F.p[1] + x, F.p[2] + y, F.p[3] + z
end
-- rotation q about point c, then a lift (dx, dy, dz)
local function about(q, c, dx, dy, dz)
	local x, y, z = qrot(q, -c[1], -c[2], -c[3])
	return {q = q, p = {c[1] + x + (dx or 0), c[2] + y + (dy or 0), c[3] + z + (dz or 0)}}
end

local PARTS, BYNAME = nil, nil
local function rig()
	if PARTS then return end
	PARTS, BYNAME = {}, {}
	for _, p in ipairs(DOG_RIG.parts) do
		local q = {name = p.name, parent = p.parent, pivot = p.pivot, center = p.center}
		PARTS[#PARTS + 1] = q
		BYNAME[p.name] = q
	end
end

-- ---- the pose description: P[part] = {pitch, yaw, roll}; root = {pitch, yaw, roll, about = {x,y,z}, lift = {x,y,z}}
local LEGS = {"leg_fl", "leg_fr", "leg_bl", "leg_br"}
local function blank(P)
	for _, n in ipairs({"body", "head", "jaw", "tail", "leg_fl", "leg_fr", "leg_bl", "leg_br"}) do
		local r = P[n]
		if not r then r = {0, 0, 0}; P[n] = r end
		r[1], r[2], r[3] = 0, 0, 0
	end
	P.root = P.root or {0, 0, 0, about = {0, 0, 0}, lift = {0, 0, 0}}
	local R = P.root
	R[1], R[2], R[3] = 0, 0, 0
	R.about[1], R.about[2], R.about[3] = 0, 0.3, 0
	R.lift[1], R.lift[2], R.lift[3] = 0, 0, 0
	return P
end

local function copyPose(src, dst)
	for k, r in pairs(src) do
		if k == "root" then
			dst.root = dst.root or {0, 0, 0, about = {0, 0, 0}, lift = {0, 0, 0}}
			for i = 1, 3 do dst.root[i] = r[i]; dst.root.about[i] = r.about[i]; dst.root.lift[i] = r.lift[i] end
		else
			dst[k] = dst[k] or {0, 0, 0}
			for i = 1, 3 do dst[k][i] = r[i] end
		end
	end
	return dst
end

-- s of the way from A to B (A is changed)
-- an angle s of the way from a to b, the short way round (a spin ends at 720 degrees, a roll over at 360: blending
-- that back to a posture's 0 the long way turned him round backwards - seen in-game)
local function alerp(a, b, s)
	local d = (b - a) % 360
	if d > 180 then d = d - 360 end
	return a + d * s
end

local function mix(A, B, s)
	for k, r in pairs(B) do
		local q = A[k]
		if k == "root" then
			for i = 1, 3 do q[i] = alerp(q[i], r[i], s); q.about[i] = lerp(q.about[i], r.about[i], s); q.lift[i] = lerp(q.lift[i], r.lift[i], s) end
		else
			for i = 1, 3 do q[i] = alerp(q[i], r[i], s) end
		end
	end
	return A
end

-- ---- postures (the still poses; the acts move between them)
local SHOULDER = {0, 0.23, 0.18}           -- (the sit rotates about the front shoulders: the rump goes down to the ground)
local RUMP = {0, 0.17, -0.30}              -- (where the rump touches the ground in the sit: the beg rocks back about it)
local function posStand(P) return P end

local function posSit(P)
	local R = P.root
	R[1] = -20; R.about[1], R.about[2], R.about[3] = SHOULDER[1], SHOULDER[2], SHOULDER[3]
	P.leg_fl[1], P.leg_fr[1] = 20, 20        -- (front legs upright again)
	P.leg_bl[1], P.leg_br[1] = -62, -62      -- (hind legs folded forward under the belly)
	P.leg_bl[3], P.leg_br[3] = 14, -14       -- (and a little out)
	P.head[1] = 8                            -- (the head stays about level, looking up at you)
	P.tail[1] = 55                           -- (the tail lies on the ground behind)
	return P
end

local function posLie(P)
	local R = P.root
	R.lift[2] = -0.16                        -- (belly on the ground)
	P.leg_fl[1], P.leg_fr[1] = -82, -82      -- (front paws stretched out ahead)
	P.leg_bl[1], P.leg_br[1] = -78, -78      -- (hind legs tucked forward, splayed: the corgi "frog")
	P.leg_bl[3], P.leg_br[3] = 35, -35
	P.head[1] = -6
	P.tail[1] = 70
	return P
end

local function posDead(P)                  -- (on its side, stiff legs out, tongue out)
	local R = P.root
	R[3] = 88; R.about[1], R.about[2], R.about[3] = 0, 0.3, 0; R.lift[2] = -0.13
	for _, n in ipairs(LEGS) do P[n][3] = -12 end
	P.leg_fl[1], P.leg_fr[1], P.leg_bl[1], P.leg_br[1] = -15, -20, 15, 20
	P.head[1] = 10; P.head[3] = -10
	P.jaw[1] = 22
	P.tail[1] = 80
	return P
end

local POSTURES = {stand = posStand, sit = posSit, lie = posLie, dead = posDead}

local function posture(P, name)
	blank(P)
	local f = POSTURES[name] or posStand
	return f(P)
end

-- ---- moving states
local function gait(P, a)
	local sp = clamp(a.speed or 1.2, 0, 8)
	local ph = a.phase or 0
	local gal = smooth((sp - 3.6) / 1.2)       -- (trot -> gallop between 3.6 and 4.8 m/s)
	local amp = lerp(22, 38, smooth((sp - 0.5) / 3)) * smooth(sp / 0.25)
	-- trot: diagonal pairs (fl + br, fr + bl); gallop: front pair together, hind pair half a cycle later
	local s1, s2 = sin(ph), sin(ph + pi)
	local gf, gb = sin(ph), sin(ph + 2.2)
	P.leg_fl[1] = lerp(amp * s1, amp * 1.2 * gf, gal)
	P.leg_br[1] = lerp(amp * s1, amp * 1.2 * gb, gal)
	P.leg_fr[1] = lerp(amp * s2, amp * 1.2 * sin(ph + 0.35), gal)
	P.leg_bl[1] = lerp(amp * s2, amp * 1.2 * sin(ph + 2.55), gal)
	local bob = abs(cos(ph)) * lerp(0.012, 0.03, gal)
	P.root.lift[2] = bob - 0.006
	P.body[1] = lerp(0, 7 * sin(ph + 1.1), gal)               -- (the gallop rocks the body)
	P.body[3] = lerp(3 * sin(ph), 0, gal)                     -- (the trot rolls it a little: corgi waddle)
	P.head[1] = -4 + 3 * sin(ph * 2) - P.body[1]
	P.tail[1] = lerp(-5, 20, gal)                              -- (streams back in the zoomies)
	return P
end

-- ---- acts (one-shots); t = seconds since the act started; base = the posture it starts from
local S1, S2 = {}, {}                      -- (scratch descriptions: no garbage per frame)

-- P = the posture "from" moved s of the way to the posture "to"
local function between(P, from, to, s)
	posture(S1, from)
	posture(P, to)
	if s < 1 then mix(S1, P, s); copyPose(S1, P) end
	return P
end

local function act(P, a, st, t)
	local base = a.base or "stand"
	if st == "sit_down" then
		return between(P, base == "sit" and "stand" or base, "sit", smooth(t / 0.35))
	elseif st == "lie_down" then
		return between(P, base == "lie" and "stand" or base, "lie", smooth(t / 0.45))
	elseif st == "stand_up" then
		return between(P, base, "stand", smooth(t / 0.35))
	elseif st == "roll_over" then                               -- (down, a full roll over the back with paws tucked, down)
		between(P, base, "lie", smooth(t / 0.3))
		local k = clamp((t - 0.3) / 1.2, 0, 1)
		local R = P.root
		R[3] = smooth(k) * 360; R.about[1], R.about[2], R.about[3] = 0, 0.35, 0   -- (about the torso's middle)
		R.lift[2] = R.lift[2] + 0.2 * sin(k * pi)                    -- (up over its back; the head tucked back: ears clear)
		P.head[1] = P.head[1] - 40 * sin(k * pi)
		local tuck = sin(k * pi)
		for _, n in ipairs(LEGS) do P[n][1] = lerp(P[n][1], -60, tuck); P[n][3] = lerp(P[n][3], 0, tuck) end
		P.jaw[1] = 12 * tuck
		return P
	elseif st == "play_dead" then                              -- ("bang!": a dramatic flop onto its side, a bounce)
		local f = clamp(t / 0.35, 0, 1)
		between(P, base, "dead", smooth(f))
		P.root.lift[2] = P.root.lift[2] + 0.12 * math.sin(f * pi)       -- (flops up and over: no paw through the ground)
		if t > 0.35 then P.root.lift[2] = P.root.lift[2] + 0.04 * sin(clamp((t - 0.35) / 0.25, 0, 1) * pi) end
		return P
	elseif st == "spin" then                                   -- (chases its tail: two turns on the spot)
		posture(P, "stand")
		local k = clamp(t / 1.4, 0, 1)
		P.root[2] = 720 * smooth(k)
		P.root.about[1], P.root.about[2], P.root.about[3] = 0, 0, 0
		local ph = t * 16
		P.leg_fl[1], P.leg_br[1] = 25 * sin(ph), 25 * sin(ph)
		P.leg_fr[1], P.leg_bl[1] = -25 * sin(ph), -25 * sin(ph)
		P.head[2] = -40 * sin(k * pi)                             -- (the head looks back at the tail)
		P.body[2] = -12 * sin(k * pi)
		return P
	elseif st == "jump" then                                   -- (crouch, hop 0.55 m with the front paws tucked, land)
		posture(P, "stand")
		local R = P.root
		if t < 0.2 then
			local c = smooth(t / 0.2)
			R.lift[2] = -0.05 * c
			P.leg_fl[1], P.leg_fr[1], P.leg_bl[1], P.leg_br[1] = 20 * c, 20 * c, -25 * c, -25 * c
			R[1] = 6 * c
		elseif t < 0.75 then
			local k = (t - 0.2) / 0.55
			R.lift[2] = 0.55 * sin(k * pi)
			R[1] = lerp(-25, 18, k); R.about[1], R.about[2], R.about[3] = 0, 0.3, 0
			P.leg_fl[1], P.leg_fr[1] = -70 * sin(k * pi), -70 * sin(k * pi)
			P.leg_bl[1], P.leg_br[1] = 55 * sin(k * pi), 55 * sin(k * pi)
			P.head[1] = -R[1] * 0.6
			P.tail[1] = -25
		else
			R.lift[2] = -0.04 * (1 - smooth((t - 0.75) / 0.15))
		end
		return P
	elseif st == "shake_paw" then                              -- (sits, gives the right paw, shakes it)
		between(P, base, "sit", smooth(t / 0.3))
		local up = smooth((t - 0.2) / 0.3) * (1 - smooth((t - 2.3) / 0.3))
		P.leg_fr[1] = lerp(P.leg_fr[1], -85 + 14 * sin(t * 18), up)
		P.leg_fr[3] = -10 * up
		P.root[3] = 4 * up                                          -- (leans onto the other paw)
		P.head[3] = -8 * up; P.head[1] = P.head[1] - 6 * up
		return P
	elseif st == "beg" then                                    -- (sits up on its haunches, paws tucked, bobs)
		between(P, base, "sit", smooth(t / 0.3))
		local up = smooth((t - 0.3) / 0.4) * (1 - smooth((t - 2.6) / 0.4))
		if up <= 0 then return P end                                 -- (still sitting down: the sit's own motion)
		-- it rocks back about the rump where it touches the ground in the sit (that point stays put)
		local R = P.root
		local x, y, z = qrot(euler(-20, 0, 0), RUMP[1] - SHOULDER[1], RUMP[2] - SHOULDER[2], RUMP[3] - SHOULDER[3])
		R[1] = lerp(-20, -58, up)
		R.about[1], R.about[2], R.about[3] = RUMP[1], RUMP[2], RUMP[3]
		R.lift[1], R.lift[2], R.lift[3] = SHOULDER[1] + x - RUMP[1], SHOULDER[2] + y - RUMP[2], SHOULDER[3] + z - RUMP[3]
		local bob = sin(t * 9) * 8 * up
		P.leg_fl[1], P.leg_fr[1] = lerp(P.leg_fl[1], -35 + bob, up), lerp(P.leg_fr[1], -35 - bob, up)
		P.leg_bl[1], P.leg_br[1] = lerp(P.leg_bl[1], -20, up), lerp(P.leg_br[1], -20, up)
		P.head[1] = lerp(P.head[1], 45, up)
		P.tail[1] = lerp(P.tail[1], 85, up)
		return P
	elseif st == "bow" then                                    -- (the play bow: chest down, butt up, then back up)
		between(P, base, "stand", smooth(t / 0.2))
		local d = smooth(t / 0.3) * (1 - smooth((t - 1.4) / 0.4))
		local R = P.root
		R[1] = R[1] + 18 * d
		for i, v in ipairs({0, 0.23, -0.19}) do R.about[i] = lerp(R.about[i], v, d) end
		R.lift[2] = R.lift[2] + 0.04 * d
		P.leg_fl[1], P.leg_fr[1] = lerp(P.leg_fl[1], -55, d), lerp(P.leg_fr[1], -55, d)
		P.leg_bl[1], P.leg_br[1] = lerp(P.leg_bl[1], -18, d), lerp(P.leg_br[1], -18, d)
		P.head[1] = P.head[1] - 24 * d
		P.tail[1] = P.tail[1] - 30 * d
		return P
	elseif st == "bark" then                                   -- (three barks: head up, jaw snaps open, a small hop)
		posture(P, base)
		local k = (t % 0.33) / 0.33
		local on = t < 0.99 and sin(k * pi) or 0
		P.head[1] = P.head[1] - 14 * on
		P.jaw[1] = 32 * on
		if base == "stand" then P.root.lift[2] = 0.025 * on; P.leg_fl[1], P.leg_fr[1] = -12 * on, -12 * on end
		return P
	elseif st == "eat" then                                    -- (head down to the treat, chomps, head up)
		posture(P, base)
		local d = smooth(t / 0.25) * (1 - smooth((t - 1.2) / 0.3))
		P.head[1] = lerp(P.head[1], 48, d)
		P.jaw[1] = d * (6 + 16 * abs(sin(t * 11)))
		return P
	elseif st == "bite" then                                   -- (a lunge: jaws wide, snap shut at 0.22 s, back)
		posture(P, "stand")
		local k = clamp(t / 0.5, 0, 1)
		local lunge = sin(clamp(t / 0.3, 0, 1) * pi)
		local R = P.root
		R.lift[3] = 0.16 * lunge; R.lift[2] = 0.03 * lunge
		R[1] = 6 * lunge; R.about[1], R.about[2], R.about[3] = 0, 0.23, -0.19
		P.leg_fl[1], P.leg_fr[1] = -30 * lunge, -30 * lunge
		P.leg_bl[1], P.leg_br[1] = 25 * lunge, 25 * lunge
		P.head[1] = -10 * lunge
		P.jaw[1] = t < 0.22 and 40 * smooth(t / 0.12) or 40 * (1 - smooth((t - 0.22) / 0.06))
		P.tail[1] = 20 * (1 - k)
		return P
	elseif st == "flinch" then                                 -- (hurt: a jolt away, head down, tail tucked)
		posture(P, base)
		local d = sin(clamp(t / 0.35, 0, 1) * pi)
		P.root.lift[3] = P.root.lift[3] - 0.06 * d
		P.root[3] = P.root[3] + 6 * d * sin(t * 40)
		P.head[1] = P.head[1] + 22 * d
		P.tail[1] = P.tail[1] + 50 * d
		P.jaw[1] = 18 * d
		return P
	elseif st == "die" then                                    -- (a slow collapse onto its side; no bounce)
		local f = smooth(clamp(t / 0.8, 0, 1))
		between(P, base, "dead", f)
		P.root.lift[2] = P.root.lift[2] + 0.06 * sin(f * pi)
		P.jaw[1] = 10 + 12 * f
		return P
	elseif st == "sniff" then                                  -- (exploring: nose to the ground, snuffling side to side)
		posture(P, base)
		local d = smooth(t / 0.3) * (1 - smooth((t - 1.9) / 0.3))
		P.head[1] = lerp(P.head[1], 40, d) + 4 * sin(t * 14) * d
		P.head[2] = P.head[2] + 18 * sin(t * 1.7) * d
		P.jaw[1] = 2 * d
		return P
	elseif st == "wiggle" then                                 -- (being petted: a head tilt, the whole body wiggles)
		posture(P, base)
		local d = smooth(t / 0.2) * (1 - smooth((t - 1.3) / 0.3))
		P.head[3] = 14 * d * sin(t * 4); P.head[1] = P.head[1] - 10 * d
		P.body[2] = P.body[2] + 8 * d * sin(t * 15)
		return P
	end
	return posture(P, base)
end

-- ---- the overlays every state gets: tail wag + butt wiggle, panting / talking jaw, carrying, breathing, looking
local function overlays(P, a, st)
	local tm = a.time or 0
	local wag = clamp(a.wag or 0, 0, 1)
	if wag > 0 then
		local w = sin(tm * 2 * pi * lerp(2.5, 4.2, wag))
		P.tail[2] = P.tail[2] + 45 * wag * w
		if st ~= "dead" and st ~= "play_dead" and st ~= "die" and st ~= "roll_over" and st ~= "spin" then
			P.body[2] = P.body[2] - 6 * wag * w                       -- (the whole butt wiggles against the tail)
			P.tail[1] = P.tail[1] - 15 * wag                           -- (and the tail lifts)
		end
	end
	P.tail[2] = P.tail[2] + 4 * sin(tm * 1.3)                       -- (never quite still)
	local talk = clamp(a.talk or 0, 0, 1)
	if talk > 0 and st ~= "bark" then
		P.jaw[1] = math.max(P.jaw[1], talk * (7 + 15 * abs(sin(tm * 13 + sin(tm * 5)))))
	end
	if a.carry then P.jaw[1] = math.max(P.jaw[1], 18) end
	local scared = clamp(a.scared or 0, 0, 1)
	if scared > 0 and st ~= "dead" and st ~= "die" then
		P.tail[1] = P.tail[1] - 70 * scared                           -- (tucked down between the legs)
		P.tail[2] = P.tail[2] * (1 - scared)
		P.head[1] = P.head[1] + 16 * scared
		P.root.lift[2] = P.root.lift[2] - 0.025 * scared
	end
	local angry = clamp(a.angry or 0, 0, 1)
	if angry > 0 and st ~= "dead" and st ~= "die" then
		P.head[1] = P.head[1] + 14 * angry                            -- (head low, lips back, tail up and stiff)
		P.jaw[1] = math.max(P.jaw[1], 8 * angry + 3 * angry * sin(tm * 30))
		P.tail[1] = P.tail[1] + 35 * angry
		P.tail[2] = P.tail[2] * (1 - angry)
	end
	if st ~= "dead" and st ~= "play_dead" and st ~= "die" and st ~= "roll_over" then
		P.body[1] = P.body[1] + 0.8 * sin(tm * 2.2)                 -- (breathing)
		local ly = clamp(a.lookYaw or 0, -55, 55)
		local lp = clamp(a.lookPitch or 0, -25, 40)
		local free = (st == "spin" or st == "eat" or st == "jump" or st == "sniff") and 0 or 1
		P.head[2] = P.head[2] + ly * free
		P.head[1] = P.head[1] - lp * free
		if st ~= "stand" and st ~= "walk" then P.head[3] = P.head[3] + 10 * sin(tm * 0.7) * (1 - talk) end
	end
end

-- ---- forward kinematics into out
local frames = {}
local function solve(P, out)
	rig()
	local R = P.root
	local rootF = about(euler(R[1], R[2], R[3]), R.about, R.lift[1], R.lift[2], R.lift[3])
	for _, q in ipairs(PARTS) do
		local r = P[q.name] or {0, 0, 0}
		local local_ = about(euler(r[1], r[2], r[3]), q.pivot)
		local F = q.parent and frames[q.parent] or rootF
		F = compose(F, local_)
		frames[q.name] = F
		local x, y, z = apply(F, q.center)
		local t = out[q.name]
		if t then
			t.pos[1], t.pos[2], t.pos[3] = x, y, z
			t.rot[1], t.rot[2], t.rot[3], t.rot[4] = F.q[1], F.q[2], F.q[3], F.q[4]
		else
			out[q.name] = Transform(Vec(x, y, z), Quat(F.q[1], F.q[2], F.q[3], F.q[4]))
		end
	end
	local m = DOG_RIG.mouth
	local hf = frames.head
	if m and hf then
		local x, y, z = apply(hf, m)
		local v = out.__mouth
		if v then v[1], v[2], v[3] = x, y, z else out.__mouth = Vec(x, y, z) end
	end
end

local KNOWN = {}
for _, s in ipairs(DOG_STATES) do KNOWN[s] = true end

local work = {}
-- the pose DESCRIPTION for a (angles per part + the root motion; reused table: copy it to keep it)
function DogDescribe(a)
	local st = KNOWN[a.st] and a.st or "stand"
	local P
	if st == "walk" then P = gait(posture(work, "stand"), a)
	elseif POSTURES[st] then P = posture(work, st)
	else P = act(work, a, st, a.t or 0) end
	overlays(P, a, st)
	return P
end

-- a description -> out (each part's centre + rotation in the root frame, out.__mouth)
function DogSolve(P, out)
	solve(P, out)
	return out
end

function DogPose(a, out)
	return DogSolve(DogDescribe(a), out)
end

-- blending a state change: DogPoseCopy(P, keep) keeps a description; DogPoseMix(A, B, s) moves A s of the way to B
DogPoseCopy = copyPose
DogPoseMix = mix
