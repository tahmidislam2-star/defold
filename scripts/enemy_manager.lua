local M = {}

M.RADIUS = 9
M.SPACING = M.RADIUS * 2
M.FACTORY_URL = "/spawner#enemyfactory"
M.POP_EFFECT_FACTORY_URL = "/spawner#popeffectfactory"
M.POINTS_PER_SLIME = 5
M.CLEAR_MULTIPLIER = 3
M.score = 0

local HEX_E1 = vmath.vector3(M.SPACING, 0, 0)
local HEX_E2 = vmath.vector3(M.SPACING * 0.5, M.SPACING * 0.8660254, 0)

-- How many pixels of open gap between two slimes still count as "touching"
-- for match/connectivity purposes. Attach positions aren't snapped to a
-- perfect hex grid, so real gaps drift a bit past the ideal spacing even
-- when slimes are visually right next to each other - this just affects the
-- match/pop logic, not how slimes are drawn or laid out.
local ADJACENCY_GAP = 6
local ADJACENCY = M.SPACING + ADJACENCY_GAP

M.clusters = {} -- [cluster_id] = { anchor=, speed=, members = { [enemy_id]=true } }
M.enemies = {}  -- [enemy_id] = { color=, cluster_id=, offset= }
M.alive_count = 0

local next_cluster_id = 1
local SEPARATION_ITERATIONS = 3

function M.new_cluster_id()
	local id = next_cluster_id
	next_cluster_id = next_cluster_id + 1
	return id
end

function M.hex_offset(q, r)
	return HEX_E1 * q + HEX_E2 * r
end

-- All hex cells within `radius_rings` of the center, as a flat list of
-- offsets - a filled hexagonal "disc". Used for the boss body.
function M.hex_disc_offsets(radius_rings)
	local offsets = {}
	for q = -radius_rings, radius_rings do
		local r_min = math.max(-radius_rings, -q - radius_rings)
		local r_max = math.min(radius_rings, -q + radius_rings)
		for r = r_min, r_max do
			table.insert(offsets, M.hex_offset(q, r))
		end
	end
	return offsets
end

function M.create_cluster(cluster_id, anchor, speed)
	M.clusters[cluster_id] = { anchor = anchor, speed = speed, members = {} }
end

-- Directly overrides a cluster's anchor, bypassing the generic
-- home-toward-player movement in update_clusters(). Used by the boss, which
-- drives its own position (entrance, patrol) rather than homing to the
-- player like a normal enemy cluster. Leave the cluster's speed at 0 so the
-- generic homing never fights this.
function M.set_cluster_anchor(cluster_id, anchor)
	local cluster = M.clusters[cluster_id]
	if cluster then
		cluster.anchor = anchor
	end
end

-- Marks a cluster as the boss body, remembering its starting size so
-- boss.script can check remaining-count against the defeat threshold.
function M.mark_boss(cluster_id, original_size)
	local cluster = M.clusters[cluster_id]
	if cluster then
		cluster.is_boss = true
		cluster.boss_original_size = original_size
	end
end

-- Marks a cluster as a boss-spawned hazard ring: bullets are absorbed by it
-- (no attach / match logic) and it is never nudged by cluster separation.
function M.mark_ring(cluster_id)
	local cluster = M.clusters[cluster_id]
	if cluster then
		cluster.is_ring = true
	end
end

function M.cluster_member_count(cluster_id)
	local cluster = M.clusters[cluster_id]
	if not cluster then return 0 end
	local n = 0
	for _ in pairs(cluster.members) do n = n + 1 end
	return n
end

function M.get_cluster_member_ids(cluster_id)
	local cluster = M.clusters[cluster_id]
	if not cluster then return {} end
	local ids = {}
	for id in pairs(cluster.members) do table.insert(ids, id) end
	return ids
end

function M.get_cluster_anchor(cluster_id)
	local cluster = M.clusters[cluster_id]
	return cluster and cluster.anchor
end

-- Lets a controller (e.g. boss.script) directly drive a cluster's position,
-- bypassing the normal per-frame homing-toward-player in update_clusters.
-- The cluster's own `speed` should stay 0 so nothing else moves it.
function M.set_cluster_anchor(cluster_id, pos)
	local cluster = M.clusters[cluster_id]
	if cluster then cluster.anchor = pos end
end

-- Makes every member of a cluster continuously orbit the cluster's anchor at
-- `angular_speed` radians/sec (nil or 0 stops the rotation). Unlike a one-off
-- animation, this keeps spinning indefinitely until stopped or the cluster
-- is destroyed - fits a hazard ring that spins until it bursts away.
function M.set_cluster_rotation(cluster_id, angular_speed)
	local cluster = M.clusters[cluster_id]
	if cluster then cluster.rotation_speed = angular_speed end
end

function M.register(enemy_id, color, cluster_id, offset)
	M.enemies[enemy_id] = { color = color, cluster_id = cluster_id, offset = offset }
	M.alive_count = M.alive_count + 1
	local cluster = M.clusters[cluster_id]
	if cluster then
		cluster.members[enemy_id] = true
	end
end

function M.unregister(enemy_id)
	local data = M.enemies[enemy_id]
	if not data then return end
	M.alive_count = M.alive_count - 1
	local cluster = M.clusters[data.cluster_id]
	if cluster then
		cluster.members[enemy_id] = nil
		if next(cluster.members) == nil then
			M.clusters[data.cluster_id] = nil
		end
	end
	M.enemies[enemy_id] = nil
end

local function separate_clusters()
	for _ = 1, SEPARATION_ITERATIONS do
		local list = {}
		for cluster_id, cluster in pairs(M.clusters) do
			if not cluster.is_boss and not cluster.is_ring then
				for enemy_id in pairs(cluster.members) do
					local data = M.enemies[enemy_id]
					if data then
						table.insert(list, { cluster_id = cluster_id, pos = cluster.anchor + data.offset })
					end
				end
			end
		end

		local corrections = {}
		local counts = {}

		for i = 1, #list do
			for j = i + 1, #list do
				local a, b = list[i], list[j]
				if a.cluster_id ~= b.cluster_id then
					local delta = b.pos - a.pos
					delta.z = 0
					local dist = vmath.length(delta)
					if dist < M.SPACING and dist > 0.0001 then
						local push = vmath.normalize(delta) * (M.SPACING - dist) * 0.5
						corrections[a.cluster_id] = (corrections[a.cluster_id] or vmath.vector3(0,0,0)) - push
						corrections[b.cluster_id] = (corrections[b.cluster_id] or vmath.vector3(0,0,0)) + push
						counts[a.cluster_id] = (counts[a.cluster_id] or 0) + 1
						counts[b.cluster_id] = (counts[b.cluster_id] or 0) + 1
					end
				end
			end
		end

		for cluster_id, corr in pairs(corrections) do
			local cluster = M.clusters[cluster_id]
			if cluster then
				cluster.anchor = cluster.anchor + corr * (1 / counts[cluster_id])
				cluster.anchor.z = 0
			end
		end
	end
end

-- Rotates every member's offset around its cluster's anchor for any cluster
-- with an active rotation_speed.
local function update_rotations(dt)
	for _, cluster in pairs(M.clusters) do
		local speed = cluster.rotation_speed
		if speed and speed ~= 0 then
			local angle = speed * dt
			local cos_a, sin_a = math.cos(angle), math.sin(angle)
			for enemy_id in pairs(cluster.members) do
				local data = M.enemies[enemy_id]
				if data then
					local o = data.offset
					data.offset = vmath.vector3(
					o.x * cos_a - o.y * sin_a,
					o.x * sin_a + o.y * cos_a,
					o.z
				)
			end
		end
	end
end
end

-- Re-aims every cluster toward the player's CURRENT position each frame, then moves it.
function M.update_clusters(dt, player_pos)
for _, cluster in pairs(M.clusters) do
	local dir = player_pos - cluster.anchor
	dir.z = 0
	if vmath.length_sqr(dir) > 0.0001 then
		dir = vmath.normalize(dir)
		cluster.anchor = cluster.anchor + dir * cluster.speed * dt
	end
end

separate_clusters()
update_rotations(dt)

for _, cluster in pairs(M.clusters) do
	for enemy_id in pairs(cluster.members) do
		local data = M.enemies[enemy_id]
		if data then
			go.set_position(cluster.anchor + data.offset, enemy_id)
		end
	end
end
end

local function resolve_attach_position(cluster, hit_pos, bullet_pos)
local dir = bullet_pos - hit_pos
dir.z = 0
if vmath.length_sqr(dir) < 0.0001 then
	dir = vmath.vector3(1, 0, 0)
end
dir = vmath.normalize(dir)
local new_pos = hit_pos + dir * M.SPACING

for _ = 1, 12 do
	local push = vmath.vector3(0, 0, 0)
	local overlaps = 0
	for enemy_id in pairs(cluster.members) do
		local other = M.enemies[enemy_id]
		if other then
			local other_pos = cluster.anchor + other.offset
			local delta = new_pos - other_pos
			local dist = vmath.length(delta)
			if dist < M.SPACING and dist > 0.0001 then
				push = push + vmath.normalize(delta) * (M.SPACING - dist)
				overlaps = overlaps + 1
			end
		end
	end
	if overlaps == 0 then break end
	new_pos = new_pos + push * (1 / overlaps)
end

new_pos.z = 0
return new_pos
end

local function flood_fill_same_color(cluster, start_id, color)
local visited = {}
local stack = { start_id }
while #stack > 0 do
	local id = table.remove(stack)
	if not visited[id] then
		visited[id] = true
		local a = M.enemies[id]
		for other_id in pairs(cluster.members) do
			if not visited[other_id] then
				local other = M.enemies[other_id]
				if a and other and other.color == color then
					local dist = vmath.length((cluster.anchor + a.offset) - (cluster.anchor + other.offset))
					if dist <= ADJACENCY then
						table.insert(stack, other_id)
					end
				end
			end
		end
	end
end
return visited
end

-- Finds the connected component (physical adjacency, any color) that
-- `start_id` belongs to, restricted to the ids in `member_set`. Used after a
-- pop to see what's still structurally attached to what.
local function connected_component(cluster, member_set, start_id, visited)
local component = {}
local stack = { start_id }
while #stack > 0 do
	local id = table.remove(stack)
	if not visited[id] then
		visited[id] = true
		component[id] = true
		local a = M.enemies[id]
		for other_id in pairs(member_set) do
			if not visited[other_id] then
				local other = M.enemies[other_id]
				if a and other then
					local dist = vmath.length((cluster.anchor + a.offset) - (cluster.anchor + other.offset))
					if dist <= ADJACENCY then
						table.insert(stack, other_id)
					end
				end
			end
		end
	end
end
return component
end
local function push_score()
msg.post("/ui#panel", "update_score", { score = M.score })
end

function M.reset_score()
M.score = 0
push_score()
end

local function award_points(slime_count, whole_cluster)
local per_slime = M.POINTS_PER_SLIME
if whole_cluster then
	per_slime = per_slime * M.CLEAR_MULTIPLIER
end
M.score = M.score + slime_count * per_slime
push_score()
end

function M.handle_attach(hit_enemy_id, color, bullet_pos)

local hit_data = M.enemies[hit_enemy_id]
if not hit_data then
	return
end
local cluster = M.clusters[hit_data.cluster_id]
if not cluster then
	return
end
if cluster.is_ring then
	return -- boss hazard ring: the bullet is absorbed, nothing attaches
end

-- Size of the cluster the bullet actually hit, BEFORE the new slime
-- joins it. This is what "the cluster" means for the small-cluster rule
-- below - counting after the attach would let a 3-slime cluster dodge
-- the rule just by having grown to 4 the instant the bullet landed.
local pre_attach_size = 0
for _ in pairs(cluster.members) do pre_attach_size = pre_attach_size + 1 end

local hit_pos = cluster.anchor + hit_data.offset
local new_pos = resolve_attach_position(cluster, hit_pos, bullet_pos)
local new_offset = new_pos - cluster.anchor

local new_id = factory.create(M.FACTORY_URL, new_pos, vmath.quat_rotation_z(0))
M.register(new_id, color, hit_data.cluster_id, new_offset)
msg.post(new_id, "setup", { color = color })

local matched = flood_fill_same_color(cluster, new_id, color)
local matched_count = 0
for _ in pairs(matched) do matched_count = matched_count + 1 end

if matched_count < 3 then
	return -- no match yet, the new slime just joins the cluster
end

-- Size counted AFTER the new slime joins (pre_attach_size + 1) - this is
-- what "the cluster" means for the explode rule below.
local post_attach_size = pre_attach_size + 1

if post_attach_size <= 6 and not cluster.is_boss then
	for enemy_id in pairs(cluster.members) do
		local other = M.enemies[enemy_id]
		local dir = other and other.offset or vmath.vector3(0, 1, 0)
		if vmath.length_sqr(dir) < 0.0001 then
			dir = vmath.vector3(math.random() - 0.5, math.random() - 0.5, 0)
		end
		dir = vmath.normalize(dir)
		msg.post(enemy_id, "burst", { direction = dir, effect = true })
	end
	award_points(post_attach_size, true)
	M.clusters[hit_data.cluster_id] = nil
	return
end
-- Bigger cluster: pop just the matched group; lone survivors pop too.
local popped_count = matched_count
for enemy_id in pairs(matched) do
	msg.post(enemy_id, "pop")
end

local remaining = {}
for enemy_id in pairs(cluster.members) do
	if not matched[enemy_id] then
		remaining[enemy_id] = true
	end
end

if next(remaining) == nil then
	M.clusters[hit_data.cluster_id] = nil
	award_points(popped_count, true) -- matched group was the whole cluster
	return
end

local visited = {}
local anything_survived = false
for start_id in pairs(remaining) do
	if not visited[start_id] then
		local component = connected_component(cluster, remaining, start_id, visited)
		local size = 0
		for _ in pairs(component) do size = size + 1 end
		if size <= 1 then
			for enemy_id in pairs(component) do
				msg.post(enemy_id, "pop")
				popped_count = popped_count + 1
			end
		else
			anything_survived = true
		end
	end
end

if not anything_survived then
	M.clusters[hit_data.cluster_id] = nil
end
award_points(popped_count, not anything_survived)
end

return M