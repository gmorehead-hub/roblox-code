--[[
	Killer control — SERVER entry script
	------------------------------------
	This file runs on the server only. Tunable numbers and staff rules are NOT
	edited here for day-to-day work — they live in:
	  src/shared/KillerControlConfig.luau
	Read that file's header and "Staff / admin exclusion" section first.

	This script: remotes, eligibility, possession loop, combat validation, cleanup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")

-- Shared modules should live in ReplicatedStorage so both server and client can require them.
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local KillerControlConfig = require(SharedFolder:WaitForChild("KillerControlConfig"))

--[[
	Remote event setup
	------------------
	These events are used only for client-side presentation:
	- GUI message ("You are the Killer")
	- camera switch and reset

	All gameplay authority stays on the server.
]]
local RemotesFolder = ReplicatedStorage:FindFirstChild("KillerControlRemotes")
if not RemotesFolder then
	RemotesFolder = Instance.new("Folder")
	RemotesFolder.Name = "KillerControlRemotes"
	RemotesFolder.Parent = ReplicatedStorage
end

local PossessionStartedEvent = RemotesFolder:FindFirstChild("PossessionStarted")
if not PossessionStartedEvent then
	PossessionStartedEvent = Instance.new("RemoteEvent")
	PossessionStartedEvent.Name = "PossessionStarted"
	PossessionStartedEvent.Parent = RemotesFolder
end

local PossessionEndedEvent = RemotesFolder:FindFirstChild("PossessionEnded")
if not PossessionEndedEvent then
	PossessionEndedEvent = Instance.new("RemoteEvent")
	PossessionEndedEvent.Name = "PossessionEnded"
	PossessionEndedEvent.Parent = RemotesFolder
end

local AttackRequestedEvent = RemotesFolder:FindFirstChild("AttackRequested")
if not AttackRequestedEvent then
	AttackRequestedEvent = Instance.new("RemoteEvent")
	AttackRequestedEvent.Name = "AttackRequested"
	AttackRequestedEvent.Parent = RemotesFolder
end

-- Current possession state used for validating attack requests.
local activePossessingPlayer: Player? = nil
local activeKillerModel: Model? = nil
--[[
	While a possession is active, this holds the one cleanup function that:
	- restores the killer template to Workspace
	- destroys the possessed clone
	- clears activePossessingPlayer / activeKillerModel

	The main scheduling loop AND PlayerRemoving both call runPossessionCleanup(),
	which runs this at most once (whichever happens first: timer or disconnect).
]]
local activePossessionCleanup: (() -> ())? = nil
--[[
	Set true only while we are inside PlayerRemoving for the currently possessed
	player. The cleanup function reads this to skip FireClient / LoadCharacterAsync
	(which error or misbehave when the session is already ending).
]]
local disconnectingPossessedUserIds: { [number]: boolean } = {}

local lastAttackAtByUserId: { [number]: number } = {}
local lastAttackAtByKillerModel: { [Model]: number } = {}
local NO_ELIGIBLE_RETRY_SECONDS = 2

--[[
	Builds a fast lookup map from the configured excluded UserId list.
	Why this helper exists:
	1) It keeps selection code simple later: `if excludedSet[player.UserId] then ...`
	2) It tolerates missing/invalid config values instead of erroring.
	3) It avoids duplicate IDs and warns when entries are invalid.
]]
local function buildExcludedUserIdSet(rawList: { any }?): { [number]: boolean }
	local excludedSet: { [number]: boolean } = {}

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
				("[KillerControl] Ignoring invalid ExcludedUserIds[%d] value: %s"):format(index, tostring(userIdValue))
			)
		end
	end

	return excludedSet
end

local excludedUserIdSet = buildExcludedUserIdSet(KillerControlConfig.ExcludedUserIds)

--[[
	-------------------------------------------------------------------------
	Staff exclusion (Owner / Admin / Mod, etc.) — implementation, not config
	-------------------------------------------------------------------------
	To ADD or CHANGE who counts as staff, edit ONLY KillerControlConfig.luau:
	  StaffGroupId, StaffExcludedRanks, ExcludePublishedExperienceCreator,
	  StaffPlayerAttributeName, StaffPlayerAttributeMustEqual

	Below: builds fast lookup tables and caches each player's group rank when
	they join (GetRankInGroupAsync). isExcludedByStaffRole() is called from
	isPlayerEligible() AFTER ExcludedUserIds.

	Do not hard-code rank numbers here — keep them in the shared config so
	designers and new devs have one place to look.
]]
local staffExcludedRankSet: { [number]: boolean } = {}
if type(KillerControlConfig.StaffExcludedRanks) == "table" then
	for _, rankValue in KillerControlConfig.StaffExcludedRanks do
		if type(rankValue) == "number" and rankValue > 0 then
			staffExcludedRankSet[rankValue] = true
		end
	end
end

--[[
	Cached group ranks (filled asynchronously via GetRankInGroupAsync).
	Key = UserId, value = rank number from Roblox for StaffGroupId (0 = not in group).
]]
local groupRankByUserId: { [number]: number } = {}

--[[
	Refresh one player's rank for StaffGroupId. Must be async — Roblox deprecated the
	synchronous GetRankInGroup API.
]]
local function refreshGroupRankForPlayer(player: Player)
	local groupId = KillerControlConfig.StaffGroupId
	if type(groupId) ~= "number" or groupId <= 0 then
		return
	end

	task.spawn(function()
		local ok, rankOrErr = pcall(function()
			return player:GetRankInGroupAsync(groupId)
		end)
		if not player.Parent then
			return
		end
		if ok and type(rankOrErr) == "number" then
			groupRankByUserId[player.UserId] = rankOrErr
		else
			groupRankByUserId[player.UserId] = 0
		end
	end)
end

Players.PlayerAdded:Connect(function(player)
	refreshGroupRankForPlayer(player)
end)

Players.PlayerRemoving:Connect(function(player)
	groupRankByUserId[player.UserId] = nil
end)

for _, existingPlayer in Players:GetPlayers() do
	refreshGroupRankForPlayer(existingPlayer)
end

--[[
	True = this player must not be killer (staff / creator / attribute rules).
	Config-driven — see KillerControlConfig. Server-only; clients cannot spoof.
]]
local function isExcludedByStaffRole(player: Player): boolean
	local attrName = KillerControlConfig.StaffPlayerAttributeName
	if type(attrName) == "string" and attrName ~= "" then
		local expected = KillerControlConfig.StaffPlayerAttributeMustEqual
		local attrValue = player:GetAttribute(attrName)
		if attrValue == expected then
			return true
		end
	end

	if KillerControlConfig.ExcludePublishedExperienceCreator then
		if game.CreatorType == Enum.CreatorType.User then
			local cid = game.CreatorId
			if cid ~= 0 and player.UserId == cid then
				return true
			end
		end
	end

	local groupId = KillerControlConfig.StaffGroupId
	if type(groupId) == "number" and groupId > 0 and next(staffExcludedRankSet) ~= nil then
		local rankInGroup = groupRankByUserId[player.UserId]
		-- While rank is still loading, we don't treat them as staff (rare short window).
		if type(rankInGroup) == "number" and rankInGroup > 0 and staffExcludedRankSet[rankInGroup] then
			return true
		end
	end

	return false
end

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

local staffRankParts = {}
for rank in staffExcludedRankSet do
	table.insert(staffRankParts, tostring(rank))
end
print("[KillerControl] StaffGroupId:", KillerControlConfig.StaffGroupId)
print(
	"[KillerControl] StaffExcludedRanks:",
	(#staffRankParts > 0) and table.concat(staffRankParts, ", ") or "(none — set StaffGroupId + StaffExcludedRanks)"
)

--[[
	True when this player may be randomly picked as killer.
	Order: (1) ExcludedUserIds  (2) staff rules in config  (3) alive character
]]
local function isPlayerEligible(player: Player): boolean
	if excludedUserIdSet[player.UserId] then
		return false
	end

	if isExcludedByStaffRole(player) then
		return false
	end

	local character = player.Character
	if not character then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end

	return true
end

-- Collect all currently eligible players into an array for random picking.
local function getEligiblePlayers(): { Player }
	local eligiblePlayers = {}

	for _, player in Players:GetPlayers() do
		if isPlayerEligible(player) then
			table.insert(eligiblePlayers, player)
		end
	end

	return eligiblePlayers
end

-- Pick one random player from the eligible list, or nil if nobody is eligible.
local function selectRandomEligiblePlayer(): Player?
	local eligiblePlayers = getEligiblePlayers()
	if #eligiblePlayers == 0 then
		return nil
	end

	local randomIndex = math.random(1, #eligiblePlayers)
	return eligiblePlayers[randomIndex]
end

--[[
	Finds the existing killer NPC in Workspace by configured name.
	We require:
	- a Model
	- a Humanoid (so player can control it)
	- a HumanoidRootPart or PrimaryPart (movement/root for control)
]]
local function getKillerModelForPossession(): Model?
	local killerModel = workspace:FindFirstChild(KillerControlConfig.KillerModelName)
	if not killerModel or not killerModel:IsA("Model") then
		warn(("[KillerControl] Killer model '%s' not found in Workspace."):format(KillerControlConfig.KillerModelName))
		return nil
	end

	local killerHumanoid = killerModel:FindFirstChildOfClass("Humanoid")
	local killerRoot = killerModel:FindFirstChild("HumanoidRootPart") or killerModel.PrimaryPart
	if not killerHumanoid or not killerRoot then
		warn("[KillerControl] Killer model is missing Humanoid or root part.")
		return nil
	end

	return killerModel
end

--[[
	Disables server Scripts inside the killer clone while a player is possessing it.
	This stops AI (e.g. pathfinding "Follow") from fighting player input.

	We intentionally do NOT disable LocalScripts:
	- The default "Animate" script is a LocalScript; turning it off makes the
	  character slide around with frozen limbs (no walk/idle animation).
	- Client-run animation should keep running on the possessed rig.
]]
local function disableKillerAiScripts(killerModel: Model): { [BaseScript]: boolean }
	local previousDisabledStateByScript: { [BaseScript]: boolean } = {}

	for _, descendant in killerModel:GetDescendants() do
		-- Only ServerScriptService-style Scripts run on the server; skip LocalScripts.
		if descendant:IsA("Script") then
			-- Rare old rigs use a Script named Animate; never kill that.
			if descendant.Name == "Animate" then
				continue
			end

			local baseScript = descendant :: BaseScript
			previousDisabledStateByScript[baseScript] = baseScript.Disabled
			baseScript.Disabled = true
		end
	end

	return previousDisabledStateByScript
end

-- Restore script states captured by disableKillerAiScripts.
local function restoreKillerAiScripts(previousDisabledStateByScript: { [BaseScript]: boolean })
	for scriptObject, previousDisabled in previousDisabledStateByScript do
		if scriptObject.Parent ~= nil then
			scriptObject.Disabled = previousDisabled
		end
	end
end

--[[
	Holds the real Killer NPC off-screen while a player possesses a clone.
	Roblox may destroy whatever is set as Player.Character when we clear it;
	using a clone keeps the original model safe for AI after possession.
]]
local killerStashFolder = ServerStorage:FindFirstChild("KillerNpcStash")
if not killerStashFolder then
	killerStashFolder = Instance.new("Folder")
	killerStashFolder.Name = "KillerNpcStash"
	killerStashFolder.Parent = ServerStorage
end

--[[
	Other server scripts can fire this when your round / elevator phase begins.
	Only used when KillerControlConfig.WaitForManualStart == true.
]]
local killerControlInternals = ServerStorage:FindFirstChild("KillerControlInternals")
if not killerControlInternals then
	killerControlInternals = Instance.new("Folder")
	killerControlInternals.Name = "KillerControlInternals"
	killerControlInternals.Parent = ServerStorage
end

local roundStartSignal = killerControlInternals:FindFirstChild("RoundStartSignal")
if not roundStartSignal then
	roundStartSignal = Instance.new("BindableEvent")
	roundStartSignal.Name = "RoundStartSignal"
	roundStartSignal.Parent = killerControlInternals
end

-- AI scripts can fire this to use the exact same attack logic as possession attacks.
local aiAttackRequestedSignal = killerControlInternals:FindFirstChild("AiAttackRequested")
if not aiAttackRequestedSignal then
	aiAttackRequestedSignal = Instance.new("BindableEvent")
	aiAttackRequestedSignal.Name = "AiAttackRequested"
	aiAttackRequestedSignal.Parent = killerControlInternals
end

-- Forward declaration: Humanoid.Died during possession calls this before it is assigned below.
local runPossessionCleanup: (reason: string) -> ()

--[[
	Starts possession:
	- finds the killer template in Workspace
	- clones it for the player (the clone becomes Character)
	- stashes the original in ServerStorage so it is not destroyed
	- disables AI scripts on the clone only

	Returns cleanup function when successful, or nil if setup failed.
]]
local function startPlayerPossession(player: Player): (() -> ())?
	local killerTemplate = getKillerModelForPossession()
	if not killerTemplate then
		return nil
	end

	local originalCharacter = player.Character
	if not originalCharacter then
		return nil
	end

	local previousKillerName = killerTemplate.Name
	local stashPivot = killerTemplate:GetPivot()

	-- Clone is what the player actually controls; template stays intact for later AI.
	local possessionKiller = killerTemplate:Clone()
	possessionKiller.Name = "KillerPossessed"
	possessionKiller:PivotTo(stashPivot)
	possessionKiller.Parent = workspace

	local previousDisabledOnClone = disableKillerAiScripts(possessionKiller)

	-- Move original NPC out of Workspace so Roblox never treats it as a discarded Character.
	killerTemplate.Parent = killerStashFolder

	-- Player character models are usually named after the player.
	possessionKiller.Name = player.Name
	player.Character = possessionKiller
	activePossessingPlayer = player
	activeKillerModel = possessionKiller

	-- Tell chosen player client to show UI and switch camera to killer.
	PossessionStartedEvent:FireClient(player, possessionKiller)
	print(("[KillerControl] %s now controls killer clone."):format(player.Name))

	--[[
		If the killer clone dies mid-possession, end the round early.
		Otherwise the main loop still waits ControlDuration while the player is dead,
		and the stashed template can get out of sync with gameplay expectations.
	]]
	local killerDiedConnection: RBXScriptConnection? = nil
	local possessionHumanoid = possessionKiller:FindFirstChildOfClass("Humanoid")
	if possessionHumanoid and KillerControlConfig.EndPossessionWhenKillerDies ~= false then
		killerDiedConnection = possessionHumanoid.Died:Connect(function()
			if killerDiedConnection then
				killerDiedConnection:Disconnect()
				killerDiedConnection = nil
			end
			if activePossessionCleanup then
				runPossessionCleanup("possessed killer died")
			end
		end)
	end

	--[[
		Return a cleanup function to guarantee consistent restoration path.
		Safe to call from:
		- the normal timer after ControlDuration
		- PlayerRemoving if the possessed player disconnects early
		- Humanoid.Died on the possessed killer clone (if enabled in config)

		When the player has left, we still must restore the killer NPC to the map;
		we only skip client-only steps (end remote + respawn).
	]]
	return function()
		if killerDiedConnection then
			killerDiedConnection:Disconnect()
			killerDiedConnection = nil
		end

		activePossessingPlayer = nil
		activeKillerModel = nil

		local skipPlayerClientActions = disconnectingPossessedUserIds[player.UserId] == true

		if not skipPlayerClientActions then
			-- Detach killer clone from the player so it is not their Character anymore.
			player.Character = nil
			PossessionEndedEvent:FireClient(player)
			task.spawn(function()
				-- Still check Parent in case they leave before this thread runs.
				if player.Parent == Players then
					player:LoadCharacterAsync()
				end
			end)
		end

		-- Prefer the clone's last position; if Roblox already removed it, fall back.
		local endPivot = stashPivot
		if possessionKiller.Parent then
			endPivot = possessionKiller:GetPivot()
		end

		pcall(function()
			possessionKiller:Destroy()
		end)

		killerTemplate.Name = previousKillerName
		killerTemplate:PivotTo(endPivot)
		killerTemplate.Parent = workspace
		restoreKillerAiScripts(previousDisabledOnClone)

		if skipPlayerClientActions then
			print("[KillerControl] Possessed player left — skipped respawn/UI; killer template restored.")
		else
			print(("[KillerControl] %s returned to normal character."):format(player.Name))
		end
		print("[KillerControl] Killer template returned to Workspace for AI.")
	end
end

--[[
	Runs the active possession cleanup once, then clears the handle.
	`reason` is only for logging (timer vs disconnect vs killer death).
]]
runPossessionCleanup = function(reason: string)
	if not activePossessionCleanup then
		return
	end

	local finish = activePossessionCleanup
	activePossessionCleanup = nil
	finish()

	print(("[KillerControl] Possession cycle closed (%s)."):format(reason))
end

--[[
	Normalizes config values to full rbxassetid:// URLs (sounds, animations, images).
]]
local function toRbxAssetUrl(v: any): string?
	if v == nil or v == "" or v == 0 then
		return nil
	end
	if type(v) == "number" and v > 0 then
		return "rbxassetid://" .. tostring(v)
	end
	if type(v) == "string" then
		if string.sub(v, 1, 13) == "rbxassetid://" then
			return v
		end
		local n = tonumber(v)
		if n and n > 0 then
			return "rbxassetid://" .. tostring(n)
		end
	end
	return nil
end

local function getAttackSwingAnimationUrl(): string?
	return toRbxAssetUrl(KillerControlConfig.AttackSwingAnimationId)
end

-- Plays a short 3D one-shot sound for nearby players.
local function playAttackSound(parentPart: BasePart, soundIdValue: any, volume: number, maxDistance: number)
	local soundUrl = toRbxAssetUrl(soundIdValue)
	if not soundUrl then
		if KillerControlConfig.DebugAttacks then
			warn("[KillerControl] Attack sound skipped: sound id is nil/invalid.")
		end
		return
	end

	local sound = Instance.new("Sound")
	sound.SoundId = soundUrl
	sound.Volume = volume
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMaxDistance = maxDistance
	sound.Parent = parentPart

	if KillerControlConfig.DebugAttacks then
		print(("[KillerControl] Playing attack sound: %s"):format(soundUrl))
	end

	sound:Play()

	-- Auto cleanup for temporary sound instances.
	Debris:AddItem(sound, 3)
end

--[[
	Cached AnimationTracks per Animator (one track per possessed killer rig).
	Playing from the server replicates to all clients for that character.
]]
local swingTrackByAnimator: { [Animator]: AnimationTrack } = {}

--[[
	Plays the configured melee swing on the killer model (if AttackSwingAnimationId is set).
	Called once per accepted attack after cooldown — includes whiffs so the killer still animates.
]]
local function playKillerSwingAnimation(killerModel: Model)
	local url = getAttackSwingAnimationUrl()
	if not url then
		return
	end

	local humanoid = killerModel:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local track = swingTrackByAnimator[animator]
	if not track then
		local anim = Instance.new("Animation")
		anim.AnimationId = url
		local ok, loaded = pcall(function()
			return animator:LoadAnimation(anim)
		end)
		anim:Destroy()
		if not ok or not loaded then
			if KillerControlConfig.DebugAttacks then
				warn(
					"[KillerControl] Failed to LoadAnimation for swing — check AttackSwingAnimationId / permissions."
				)
			end
			return
		end
		track = loaded
		swingTrackByAnimator[animator] = track
	end

	local fade = KillerControlConfig.AttackSwingFadeTime
	local speed = KillerControlConfig.AttackSwingSpeed
	pcall(function()
		track:Play(fade, 1, speed)
	end)
end

--[[
	Server-authoritative melee hit handling.
	Both player possession and AI call this same function so attacks behave identically:
	- same cooldown rule
	- same swing animation/sounds
	- same nearest-target hit detection
	- same damage application

	DEV NOTE (where to customize, safely):
	- Tune numbers (damage/range/cooldown/sounds/animation) in shared config, not here.
	- If you want different targeting rules (cone, raycast, team checks), edit only the
	  "bestHumanoid" selection block below.
	- If AI should attack less/more often, prefer changing AiAutoAttack* config values
	  and leave performKillerAttack untouched so player/AI parity stays intact.
]]
local function performKillerAttack(killerModel: Model, attackerPlayer: Player?)
	if not killerModel or killerModel.Parent == nil then
		return
	end

	local killerHumanoid = killerModel:FindFirstChildOfClass("Humanoid")
	local killerRoot = killerModel:FindFirstChild("HumanoidRootPart") or killerModel.PrimaryPart
	if not killerHumanoid or killerHumanoid.Health <= 0 or not killerRoot then
		return
	end

	-- Shared anti-spam cooldown:
	-- - possession attacks: key by attacker user id
	-- - AI attacks: key by killer model instance
	local now = os.clock()
	local lastAttackAt: number
	if attackerPlayer then
		lastAttackAt = lastAttackAtByUserId[attackerPlayer.UserId] or 0
	else
		lastAttackAt = lastAttackAtByKillerModel[killerModel] or 0
	end

	if now - lastAttackAt < KillerControlConfig.AttackCooldown then
		return
	end

	if attackerPlayer then
		lastAttackAtByUserId[attackerPlayer.UserId] = now
	else
		lastAttackAtByKillerModel[killerModel] = now
	end

	-- Visual feedback for everyone (hits and misses); requires valid uploaded AnimationId in config.
	playKillerSwingAnimation(killerModel)
	playAttackSound(
		killerRoot,
		KillerControlConfig.AttackSwingSoundId,
		KillerControlConfig.AttackSwingSoundVolume,
		KillerControlConfig.AttackSwingSoundRollOffMaxDistance
	)

	-- Hit the single closest valid victim in range (simple melee feel).
	local bestHumanoid: Humanoid? = nil
	local bestDistance = KillerControlConfig.AttackRange

	for _, otherPlayer in Players:GetPlayers() do
		if attackerPlayer == nil or otherPlayer ~= attackerPlayer then
			local otherCharacter = otherPlayer.Character
			if otherCharacter then
				local otherHumanoid = otherCharacter:FindFirstChildOfClass("Humanoid")
				local otherRoot = otherCharacter:FindFirstChild("HumanoidRootPart") or otherCharacter.PrimaryPart

				if otherHumanoid and otherHumanoid.Health > 0 and otherRoot then
					local distance = (otherRoot.Position - killerRoot.Position).Magnitude
					if distance <= bestDistance then
						bestDistance = distance
						bestHumanoid = otherHumanoid
					end
				end
			end
		end
	end

	if bestHumanoid then
		bestHumanoid:TakeDamage(KillerControlConfig.AttackDamage)

		local victimRoot = bestHumanoid.Parent and bestHumanoid.Parent:FindFirstChild("HumanoidRootPart")
		if victimRoot and victimRoot:IsA("BasePart") then
			playAttackSound(
				victimRoot,
				KillerControlConfig.AttackHitSoundId,
				KillerControlConfig.AttackHitSoundVolume,
				KillerControlConfig.AttackHitSoundRollOffMaxDistance
			)
		end

		if KillerControlConfig.DebugAttacks then
			print(
				("[KillerControl] Attack hit %s for %d damage (dist %.1f)."):format(
					bestHumanoid.Parent and bestHumanoid.Parent.Name or "?",
					KillerControlConfig.AttackDamage,
					bestDistance
				)
			)
		end
	elseif KillerControlConfig.DebugAttacks then
		print(
			("[KillerControl] Attack missed — no player in range (range=%.1f)."):format(
				KillerControlConfig.AttackRange
			)
		)
	end
end

-- Possessed player path -> same shared attack logic.
AttackRequestedEvent.OnServerEvent:Connect(function(player: Player)
	if activePossessingPlayer ~= player then
		return
	end

	local killerModel = activeKillerModel
	if not killerModel then
		return
	end

	performKillerAttack(killerModel, player)
end)

-- AI path -> any server AI script can fire this bindable with the killer model.
-- Example from an AI script:
-- ServerStorage.KillerControlInternals.AiAttackRequested:Fire(script.Parent)
-- Why this exists:
-- - Marketplace AI scripts are inconsistent. Some have no clean attack event.
-- - This gives a stable API entrypoint so future AI rewrites can still reuse
--   the same shared attack function without duplicating combat logic.
aiAttackRequestedSignal.Event:Connect(function(killerModel: Model)
	if typeof(killerModel) ~= "Instance" or not killerModel:IsA("Model") then
		return
	end

	performKillerAttack(killerModel, nil)
end)

--[[
	Fallback AI attack loop:
	- Runs only when nobody is possessing the killer
	- If any alive player is close enough to the AI killer, it triggers the
	  same shared attack function used by human possession attacks.
	- This keeps behavior working even if marketplace AI scripts don't call the bindable.

	To replace this with your own AI:
	1) Set AiAutoAttackEnabled = false in KillerControlConfig
	2) From your AI script, call AiAttackRequested:Fire(killerModel) when your
	   pathfinding/targeting logic decides to attack
]]
task.spawn(function()
	while true do
		if KillerControlConfig.AiAutoAttackEnabled and activePossessingPlayer == nil then
			local killerModel = getKillerModelForPossession()
			if killerModel then
				local killerHumanoid = killerModel:FindFirstChildOfClass("Humanoid")
				local killerRoot = killerModel:FindFirstChild("HumanoidRootPart") or killerModel.PrimaryPart

				if killerHumanoid and killerHumanoid.Health > 0 and killerRoot then
					local targetInRange = false
					for _, player in Players:GetPlayers() do
						local character = player.Character
						if character then
							local humanoid = character:FindFirstChildOfClass("Humanoid")
							local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
							if humanoid and humanoid.Health > 0 and root then
								local distance = (root.Position - killerRoot.Position).Magnitude
								if distance <= KillerControlConfig.AiAutoAttackRange then
									targetInRange = true
									break
								end
							end
						end
					end

					if targetInRange then
						performKillerAttack(killerModel, nil)
					end
				end
			end
		end

		task.wait(KillerControlConfig.AiAutoAttackCheckInterval)
	end
end)

--[[
	STEP 4 LOOP (selection + possession on server)
	----------------------------------------------
	Flow:
	1) choose random eligible player
	2) hand control of existing killer NPC to that player
	3) wait ControlDuration seconds
	4) restore player + killer AI
	5) run cooldown
	
]]
--[[
	Disconnect-safe cleanup (placed near the scheduling loop)
	---------------------------------------------------------
	If the possessed player leaves during the control window, the main loop is
	still stuck in task.wait(ControlDuration). Without this handler, the killer
	template could stay stashed in ServerStorage and the clone could be left in
	a bad state.

	We mark their UserId while handling PlayerRemoving, run the same cleanup as
	the timer would, and the later runPossessionCleanup("timer") becomes a no-op.
]]
Players.PlayerRemoving:Connect(function(player)
	if activePossessingPlayer ~= player then
		return
	end

	disconnectingPossessedUserIds[player.UserId] = true
	runPossessionCleanup("possessed player disconnected")
	disconnectingPossessedUserIds[player.UserId] = nil
end)

task.spawn(function()
	-- Optional: wait until your elevator / round script says go.
	if KillerControlConfig.WaitForManualStart then
		print(
			"[KillerControl] WaitForManualStart is true — blocking until "
				.. "ServerStorage.KillerControlInternals.RoundStartSignal:Fire() ..."
		)
		roundStartSignal.Event:Wait()
		print("[KillerControl] RoundStartSignal received; continuing startup.")
	end

	-- Optional: delay after server boot (and after manual start, if used).
	if KillerControlConfig.InitialDelaySeconds > 0 then
		print(
			("[KillerControl] Initial delay: %ds before first selection."):format(
				KillerControlConfig.InitialDelaySeconds
			)
		)
		task.wait(KillerControlConfig.InitialDelaySeconds)
	end

	print("[KillerControl] Main scheduling loop running.")

	while true do
		local selectedPlayer = selectRandomEligiblePlayer()

		if selectedPlayer then
			print(("[KillerControl] Selected player: %s (%d)"):format(selectedPlayer.Name, selectedPlayer.UserId))

			local cleanupPossession = startPlayerPossession(selectedPlayer)
			if cleanupPossession then
				activePossessionCleanup = cleanupPossession
				task.wait(KillerControlConfig.ControlDuration)
				runPossessionCleanup("control timer elapsed")
			else
				warn("[KillerControl] Possession setup failed; skipping control window.")
			end
		else
			print("[KillerControl] No eligible players currently available.")
			print(("[KillerControl] Retrying in %ds (not starting full cooldown)."):format(NO_ELIGIBLE_RETRY_SECONDS))
			task.wait(NO_ELIGIBLE_RETRY_SECONDS)
			continue
		end

		print(("[KillerControl] Cooldown started (%ds)."):format(KillerControlConfig.CooldownDuration))
		task.wait(KillerControlConfig.CooldownDuration)
	end
end)
