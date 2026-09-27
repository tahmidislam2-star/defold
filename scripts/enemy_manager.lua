local M = {}

M.RADIUS = 9
M.SPACING = M.RADIUS * 2
M.FACTORY_URL = "/spawner#enemyfactory"

local HEX_E1 = vmath.vector3(M.SPACING, 0, 0)
local HEX_E2 = vmath.vector3(M.SPACING * 0.5, M.SPACING * 0.8660254, 0)
local ADJACENCY = M.SPACING * 1.15

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

function M.create_cluster(cluster_id, anchor, speed)
	M.clusters[cluster_id] = { anchor = anchor, speed = speed, members = {} }
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
			for enemy_id in pairs(cluster.members) do
				local data = M.enemies[enemy_id]
				if data then
					table.insert(list, { cluster_id = cluster_id, pos = cluster.anchor + data.offset })
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
	msg.post(new_id, "setup", { color = color })

	local matched = flood_fill_same_color(cluster, new_id, color)
	local matched_count = 0
	for _ in pairs(matched) do matched_count = matched_count + 1 end

	if matched_count >= 3 then
		for enemy_id in pairs(cluster.members) do
			if matched[enemy_id] then
				msg.post(enemy_id, "pop")
			else
				local other = M.enemies[enemy_id]
				local dir = other and other.offset or vmath.vector3(0, 1, 0)
				if vmath.length_sqr(dir) < 0.0001 then
					dir = vmath.vector3(math.random() - 0.5, math.random() - 0.5, 0)
				end
				dir = vmath.normalize(dir)
				msg.post(enemy_id, "burst", { direction = dir })
			end
		end
		M.clusters[hit_data.cluster_id] = nil
	end
end

return M