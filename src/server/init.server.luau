--[[
	Server bootstrap (step 1)
	-------------------------
	For now, we only load and verify killer-control config values.
	We'll plug this into the full possession system in the next steps.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

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
local disconnectingPossessedUserIds: {[number]: boolean} = {}

local lastAttackAtByUserId: {[number]: number} = {}
local NO_ELIGIBLE_RETRY_SECONDS = 2

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

--[[
	Returns true when a player can be selected for killer control.
	For now we only enforce exclusions + basic character/humanoid health checks.
	We keep this as a separate function so future rules are easy to add.
]]
local function isPlayerEligible(player: Player): boolean
	if excludedUserIdSet[player.UserId] then
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
local function getEligiblePlayers(): {Player}
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
		warn(
			("[KillerControl] Killer model '%s' not found in Workspace.")
				:format(KillerControlConfig.KillerModelName)
		)
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
local function disableKillerAiScripts(killerModel: Model): {[BaseScript]: boolean}
	local previousDisabledStateByScript: {[BaseScript]: boolean} = {}

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
local function restoreKillerAiScripts(previousDisabledStateByScript: {[BaseScript]: boolean})
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
		Return a cleanup function to guarantee consistent restoration path.
		Safe to call from:
		- the normal timer after ControlDuration
		- PlayerRemoving if the possessed player disconnects early

		When the player has left, we still must restore the killer NPC to the map;
		we only skip client-only steps (end remote + respawn).
	]]
	return function()
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
	`reason` is only for logging (timer vs disconnect vs manual).
]]
local function runPossessionCleanup(reason: string)
	if not activePossessionCleanup then
		return
	end

	local finish = activePossessionCleanup
	activePossessionCleanup = nil
	finish()

	print(("[KillerControl] Possession cycle closed (%s)."):format(reason))
end

--[[
	Server-authoritative melee hit handling.
	Client only says "I tried to attack" and server decides whether it is valid.
]]
AttackRequestedEvent.OnServerEvent:Connect(function(player: Player)
	-- Only the currently selected possessed player can attack.
	if activePossessingPlayer ~= player then
		return
	end

	local killerModel = activeKillerModel
	if not killerModel or killerModel.Parent == nil then
		return
	end

	local killerHumanoid = killerModel:FindFirstChildOfClass("Humanoid")
	local killerRoot = killerModel:FindFirstChild("HumanoidRootPart") or killerModel.PrimaryPart
	if not killerHumanoid or killerHumanoid.Health <= 0 or not killerRoot then
		return
	end

	-- Anti-spam cooldown per player (server side).
	local now = os.clock()
	local lastAttackAt = lastAttackAtByUserId[player.UserId] or 0
	if now - lastAttackAt < KillerControlConfig.AttackCooldown then
		return
	end
	lastAttackAtByUserId[player.UserId] = now

	-- Hit the single closest valid victim in range (simple melee feel).
	local bestHumanoid: Humanoid? = nil
	local bestDistance = KillerControlConfig.AttackRange

	for _, otherPlayer in Players:GetPlayers() do
		if otherPlayer ~= player then
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
		if KillerControlConfig.DebugAttacks then
			print(
				("[KillerControl] Attack hit %s for %d damage (dist %.1f).")
					:format(bestHumanoid.Parent and bestHumanoid.Parent.Name or "?", KillerControlConfig.AttackDamage, bestDistance)
			)
		end
	elseif KillerControlConfig.DebugAttacks then
		print(
			("[KillerControl] Attack missed — no player in range (range=%.1f)."):format(KillerControlConfig.AttackRange)
		)
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
			("[KillerControl] Initial delay: %ds before first selection.")
				:format(KillerControlConfig.InitialDelaySeconds)
		)
		task.wait(KillerControlConfig.InitialDelaySeconds)
	end

	print("[KillerControl] Main scheduling loop running.")

	while true do
		local selectedPlayer = selectRandomEligiblePlayer()

		if selectedPlayer then
			print(
				("[KillerControl] Selected player: %s (%d)")
					:format(selectedPlayer.Name, selectedPlayer.UserId)
			)

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
			print(
				("[KillerControl] Retrying in %ds (not starting full cooldown).")
					:format(NO_ELIGIBLE_RETRY_SECONDS)
			)
			task.wait(NO_ELIGIBLE_RETRY_SECONDS)
			continue
		end

		print(
			("[KillerControl] Cooldown started (%ds).")
				:format(KillerControlConfig.CooldownDuration)
		)
		task.wait(KillerControlConfig.CooldownDuration)
	end
end)
