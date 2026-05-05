--[[
	Client bootstrap (step 1)
	-------------------------
	For now, we only load and verify killer-control config values from Shared.
	This confirms the module is available to both sides (FE-friendly structure).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local KillerControlConfig = require(SharedFolder:WaitForChild("KillerControlConfig"))

print("[KillerControl] Config loaded on client.")
print("[KillerControl] ControlDuration:", KillerControlConfig.ControlDuration)
print("[KillerControl] CooldownDuration:", KillerControlConfig.CooldownDuration)
