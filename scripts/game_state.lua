local M = {}

M.game_over = false
M.hitstop_timer = 0
M.boss_active = false
M.cursor_visible = true

function M.reset()
	M.game_over = false
	M.hitstop_timer = 0
	M.boss_active = false
end

function M.set_cursor_visible(visible)
	M.cursor_visible = visible
	if defos then
		defos.set_cursor_visible(visible)
	end
end

return M