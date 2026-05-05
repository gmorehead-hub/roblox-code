--[[
	Killer Control Config
	---------------------
	This module is the single place for values used by the killer-control system.
	Keeping settings here makes it easier to tweak behavior without hunting through
	server/client scripts.
]]

local KillerControlConfig = {}

-- How long a selected player controls the killer (seconds).
KillerControlConfig.ControlDuration = 15

-- How long the system waits before selecting another player (seconds).
KillerControlConfig.CooldownDuration = 100

-- Players in this list will never be selected as the killer controller.
-- Add UserIds like: {12345678, 87654321}
KillerControlConfig.ExcludedUserIds = {}

return KillerControlConfig
