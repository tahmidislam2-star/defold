local M = {}

M.game_over = false
M.hitstop_timer = 0
M.boss_active = false

function M.reset()
	M.game_over = false
	M.hitstop_timer = 0
	M.boss_active = false
end

return M