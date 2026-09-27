local M = {}

M.RADIUS = 9              -- match this to your 16px sprite's collision shape radius
M.SPACING = M.RADIUS * 2  -- distance between touching centers
M.FACTORY_URL = "/spawner#enemyfactory"

local HEX_E1 = vmath.vector3(M.SPACING, 0, 0)
local HEX_E2 = vmath.vector3(M.SPACING * 0.5, M.SPACING * 0.8660254, 0)
local ADJACENCY = M.SPACING * 1.15 -- tolerance for "touching"

M.clusters = {} -- [cluster_id] = { anchor=, velocity=, members = { [enemy_id]=true } }
M.enemies = {}  -- [enemy_id] = { color=, cluster_id=, offset= }

local next_cluster_id = 1

function M.new_cluster_id()
	local id = next_cluster_id
	next_cluster_id = next_cluster_id + 1
	return id
end

function M.hex_offset(q, r)
	return HEX_E1 * q + HEX_E2 * r
end

function M.create_cluster(cluster_id, anchor, velocity)
	M.clusters[cluster_id] = { anchor = anchor, velocity = velocity, members = {} }
end

function M.register(enemy_id, color, cluster_id, offset)
	M.enemies[enemy_id] = { color = color, cluster_id = cluster_id, offset = offset }
	local cluster = M.clusters[cluster_id]
	if cluster then
		cluster.members[enemy_id] = true
	end
end
function M.unregister(enemy_id)
	local data = M.enemies[enemy_id]
	if not data then return end
	local cluster = M.clusters[data.cluster_id]
	if cluster then
		cluster.members[enemy_id] = nil
		if next(cluster.members) == nil then
			M.clusters[data.cluster_id] = nil
		end
	end
	M.enemies[enemy_id] = nil
end

function M.update_clusters(dt)
	for _, cluster in pairs(M.clusters) do
		cluster.anchor = cluster.anchor + cluster.velocity * dt
		for enemy_id in pairs(cluster.members) do
			local data = M.enemies[enemy_id]
			if data then
				go.set_position(cluster.anchor + data.offset, enemy_id)
			else
				print("WARNING: member in cluster.members has no enemies[] entry:", enemy_id)
			end
		end
	end
end

-- Contact point, nudged outward until it no longer overlaps any existing member
local function resolve_attach_position(cluster, hit_pos, bullet_pos)
	local dir = bullet_pos - hit_pos
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
		new_pos = new_pos + push * (1 / overlaps) -- average the corrections instead of stacking them
	end

	return new_pos
end
-- Only same-color members reachable via a chain of touching neighbors count
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

-- Called by a bullet on hitting hit_enemy_id, regardless of color match.
-- Spawns a new enemy at the contact point, then checks for a chain match.
function M.handle_attach(hit_enemy_id, color, bullet_pos)
	local hit_data = M.enemies[hit_enemy_id]
	if not hit_data then return end
	local cluster = M.clusters[hit_data.cluster_id]
	if not cluster then return end

	local hit_pos = cluster.anchor + hit_data.offset
	local new_pos = resolve_attach_position(cluster, hit_pos, bullet_pos)
	local new_offset = new_pos - cluster.anchor

	local new_id = factory.create(M.FACTORY_URL, new_pos, vmath.quat_rotation_z(0))
	M.register(new_id, color, hit_data.cluster_id, new_offset)
	print("attached new enemy", new_id, "to cluster", hit_data.cluster_id, "offset:", new_offset) -- moved here

	msg.post(new_id, "setup", { color = color })

	local matched = flood_fill_same_color(cluster, new_id, color)
	local matched_count = 0
	for _ in pairs(matched) do matched_count = matched_count + 1 end
	print("matched_count:", matched_count, "for color:", color)

	if matched_count >= 3 then
		print("MATCH TRIGGERED - clearing cluster", hit_data.cluster_id)
		for enemy_id in pairs(cluster.members) do
			if matched[enemy_id] then
				msg.post(enemy_id, "pop")
			else
				msg.post(enemy_id, "burst")
			end
		end
		M.clusters[hit_data.cluster_id] = nil -- clear immediately so nothing else attaches to a dying cluster
	end
end

return M