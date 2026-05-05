--[[
	Killer Control Config
	---------------------
	This module is the single place for values used by the killer-control system.
	Keeping settings here makes it easier to tweak behavior without hunting through
	server/client scripts.
]]

local KillerControlConfig = {}

--[[
	When to start the killer scheduling loop
	-----------------------------------------
	- InitialDelaySeconds: waits this long after the conditions below are met,
	  then runs the first random selection (and keeps looping forever after).
	  Example: set to 10 for "10 seconds after the game / round is allowed to start".

	- WaitForManualStart: if true, the script does NOTHING until another SERVER
	  script fires the BindableEvent:
	    ServerStorage.KillerControlInternals.RoundStartSignal
	  Use this when your elevator "round start" runs in a different script.
	  Flow when true:
	    1) Your script calls RoundStartSignal:Fire() when the round begins
	    2) This script waits InitialDelaySeconds (can be 0)
	    3) First killer cycle runs, then cooldowns, etc.

	If WaitForManualStart is false, scheduling begins after InitialDelaySeconds
	from server boot (no BindableEvent needed).
]]
KillerControlConfig.WaitForManualStart = false
KillerControlConfig.InitialDelaySeconds = 12

-- How long a selected player controls the killer (seconds).
KillerControlConfig.ControlDuration = 15

-- How long the system waits before selecting another player (seconds).
KillerControlConfig.CooldownDuration = 100

-- Players in this list will never be selected as the killer controller.
-- Add UserIds like: {12345678, 87654321}
KillerControlConfig.ExcludedUserIds = {}

-- Name of the existing killer NPC model in Workspace that will be possessed.
KillerControlConfig.KillerModelName = "Killer"

-- Damage per successful killer attack.
KillerControlConfig.AttackDamage = 25

-- Max distance from killer root to victim root for a hit.
KillerControlConfig.AttackRange = 12

-- Minimum time between attack requests from possessed player.
KillerControlConfig.AttackCooldown = 0.75

-- Set true while testing to print every attack + whether anyone was in range.
KillerControlConfig.DebugAttacks = true

return KillerControlConfig
