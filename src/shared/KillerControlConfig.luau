--[[
	Killer Control Config
	---------------------
	This module is the single place for values used by the killer-control system.

	ONBOARDING (read this if you are new to this codebase)
	-------------------------------------------------------
	1) Almost everything gameplay-related is edited HERE — not scattered in scripts.
	2) After changing values, save the file and sync to Roblox Studio (e.g. Rojo).
	3) Server logic that READS this module lives in:
	     src/server/init.server.luau
	   Client UI / input lives in:
	     src/client/init.client.luau
	4) Killer eligibility order on the server (high level):
	     a) ExcludedUserIds (manual blocklist by UserId)
	     b) Staff rules below (group rank, optional creator, optional attribute)
	     c) Must have a living character (Humanoid with Health > 0)

	Staff / Owner–Admin–Mod exclusion is configured ONLY in this file under the
	"Staff / admin exclusion" section. You do not need to edit init.server.luau
	for normal rank / attribute tweaks — only if you change how eligibility works.
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

--[[
	---------------------------------------------------------------------------
	Staff / admin exclusion — HOW TO EDIT (Owner, Co-Owner, Admin, Mod, etc.)
	---------------------------------------------------------------------------
	Roblox does NOT expose role NAMES to scripts (there is no API for "is this
	player a Mod?"). The game only sees a numeric **Rank** per group (0–255).

	What "dynamic" means here:
	- You promote/demote people on the Roblox website.
	- Their rank number updates; this game re-reads it when they join (cached
	  on the server — see init.server.luau, refreshGroupRankForPlayer).

	CHECKLIST for whoever configures this place:
	1) Get your GROUP ID (the number in the group's URL on roblox.com).
	2) Open Group Admin → Roles. For EACH role that must NEVER be killer
	   (Owner, Co-Owner, Admin, Moderator, …), note the **Rank** column value.
	   Important: "Owner" is NOT always 255 — verify YOUR group's numbers.
	3) Set StaffGroupId to that group id (number).
	4) Set StaffExcludedRanks to a list of those rank numbers, e.g. { 255, 242, 230 }.
	5) Leave StaffGroupId = 0 if you do NOT use group-based staff exclusion.

	Optional extras (same section):
	- ExcludePublishedExperienceCreator: block the live game's user-owner from
	  being killer (only applies when CreatorType is User; group-owned games use ranks).
	- StaffPlayerAttributeName: if an admin COMMAND BAR kit sets an Attribute on
	  Player from the SERVER, put the attribute name here (e.g. "IsStaff") and
	  set StaffPlayerAttributeMustEqual to whatever value means "staff".

	All of this is enforced ONLY on the server (clients cannot fake rank).
]]
-- Your Roblox group id, or 0 to disable rank-based staff exclusion.
KillerControlConfig.StaffGroupId = 0
--[[
	Every rank number listed here cannot be selected as killer.
	Copy numbers from: Group → Configure → Roles → column "Rank".

	Example (DO NOT paste blindly — use YOUR group's ranks):
	KillerControlConfig.StaffExcludedRanks = { 255, 250, 245, 240 }
]]
KillerControlConfig.StaffExcludedRanks = {}

--[[
	If true, blocks the published experience creator when the place is owned by
	a single User (not a Group). Useful for solo dev accounts.
	Note: In Studio, game.CreatorId is often 0 — test this in a published server.
]]
KillerControlConfig.ExcludePublishedExperienceCreator = false

--[[
	Integration with third-party admin kits (optional)
	--------------------------------------------------
	Only use this if YOUR kit sets player Attributes from SERVER scripts.
	1) Find what attribute name and value mean "staff" in that kit (read their docs).
	2) Set StaffPlayerAttributeName to that string, e.g. "IsStaff".
	3) Set StaffPlayerAttributeMustEqual to the value that means staff — often `true`.

	If StaffPlayerAttributeName is nil, this check is skipped entirely.
]]
KillerControlConfig.StaffPlayerAttributeName = nil
-- When the attribute above equals this value, the player cannot be killer.
KillerControlConfig.StaffPlayerAttributeMustEqual = true

-- Name of the existing killer NPC model in Workspace that will be possessed.
KillerControlConfig.KillerModelName = "Killer"

-- Damage per successful killer attack.
KillerControlConfig.AttackDamage = 25

-- Max distance from killer root to victim root for a hit.
KillerControlConfig.AttackRange = 12

-- Minimum time between attack requests from possessed player.
KillerControlConfig.AttackCooldown = 0.75

--[[
	Attack swing animation (optional)
	---------------------------------
	Played on the SERVER when a possessed killer attack passes cooldown, so every
	player sees the swing (including on misses).

	How to get an AnimationId:
	1) Create or pick an Animation in Studio (or use a sword swing from Toolbox).
	2) Publish/upload the animation to Roblox (Animations must be owned / permitted for your game).
	3) Paste the numeric id here, OR the full string "rbxassetid://1234567890".

	Set to nil (or 0 / "") to disable swing animation.
]]
KillerControlConfig.AttackSwingAnimationId = nil
-- Blend-in time when starting the swing (seconds).
KillerControlConfig.AttackSwingFadeTime = 0.1
-- Playback speed (1 = normal).
KillerControlConfig.AttackSwingSpeed = 1

-- Set true while testing to print every attack + whether anyone was in range.
KillerControlConfig.DebugAttacks = true

return KillerControlConfig
