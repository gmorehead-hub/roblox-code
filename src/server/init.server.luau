--[[
	Server bootstrap (step 1)
	-------------------------
	For now, we only load and verify killer-control config values.
	We'll plug this into the full possession system in the next steps.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared modules should live in ReplicatedStorage so both server and client can require them.
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local KillerControlConfig = require(SharedFolder:WaitForChild("KillerControlConfig"))

--[[
	Builds a fast lookup map from the configured excluded UserId list.
	Why this helper exists:
	1) It keeps selection code simple later: `if excludedSet[player.UserId] then ...`
	2) It tolerates missing/invalid config values instead of erroring.
	3) It avoids duplicate IDs and warns when entries are invalid.
]]
local function buildExcludedUserIdSet(rawList: {any}?): {[number]: boolean}
	local excludedSet: {[number]: boolean} = {}

	-- If list is missing or not a table, treat it as "no exclusions".
	if type(rawList) ~= "table" then
		warn("[KillerControl] ExcludedUserIds is not a table; using empty exclusion list.")
		return excludedSet
	end

	for index, userIdValue in ipairs(rawList) do
		if type(userIdValue) == "number" and userIdValue > 0 then
			excludedSet[userIdValue] = true
		else
			warn(
				("[KillerControl] Ignoring invalid ExcludedUserIds[%d] value: %s")
					:format(index, tostring(userIdValue))
			)
		end
	end

	return excludedSet
end

local excludedUserIdSet = buildExcludedUserIdSet(KillerControlConfig.ExcludedUserIds)

-- Convert lookup-map keys into a readable comma-separated debug string.
local excludedUserIdTextParts = {}
for userId in excludedUserIdSet do
	table.insert(excludedUserIdTextParts, tostring(userId))
end

print("[KillerControl] Config loaded on server.")
print("[KillerControl] ControlDuration:", KillerControlConfig.ControlDuration)
print("[KillerControl] CooldownDuration:", KillerControlConfig.CooldownDuration)
print("[KillerControl] ExcludedUserIds count:", #excludedUserIdTextParts)
print(
	"[KillerControl] ExcludedUserIds active:",
	(#excludedUserIdTextParts > 0) and table.concat(excludedUserIdTextParts, ", ") or "(none)"
)
