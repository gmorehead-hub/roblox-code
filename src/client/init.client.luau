local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local KillerControlConfig = require(SharedFolder:WaitForChild("KillerControlConfig"))

local remotesFolder = ReplicatedStorage:WaitForChild("KillerControlRemotes")
local possessionStartedEvent = remotesFolder:WaitForChild("PossessionStarted") :: RemoteEvent
local possessionEndedEvent = remotesFolder:WaitForChild("PossessionEnded") :: RemoteEvent
local attackRequestedEvent = remotesFolder:WaitForChild("AttackRequested") :: RemoteEvent

--[[
	Killer banner GUI — tweak these to match your horror elevator style
	-------------------------------------------------------------------
	All values are in one place so you can experiment without hunting the file.
]]
local KILLER_UI = {
	-- Banner size (scale = fraction of screen). Wider + shorter reads well on mobile.
	WidthScale = 0.5,
	HeightScale = 0.085,
	-- Distance from top of screen (0 = top edge).
	TopInsetScale = 0.055,

	-- Panel: dark backing + subtle red border (horror / alert feel).
	PanelColor = Color3.fromRGB(12, 6, 8),
	PanelTransparency = 0.12,
	CornerRadius = 14,
	BorderColor = Color3.fromRGB(180, 28, 40),
	BorderThickness = 2,

	-- Text (assignment wording — change if you want a different tone)
	TitleText = "You are the Killer",
	TitleFont = Enum.Font.GothamBlack,
	TextColor = Color3.fromRGB(255, 235, 235),
	-- Thin outline keeps text readable on bright backgrounds.
	TextStrokeColor = Color3.fromRGB(60, 0, 0),
	TextStrokeTransparency = 0.35,
}

--[[
	Layout: ScreenGui → Frame (rounded panel) → TextLabel (full bleed with padding)

	Why a Frame wrapper? TextLabel can't use UICorner cleanly for the whole banner;
	nesting gives you rounded corners + stroke + padding in one package.
]]
local killerUi = Instance.new("ScreenGui")
killerUi.Name = "KillerControlUi"
killerUi.ResetOnSpawn = false
killerUi.Enabled = true
killerUi.DisplayOrder = 50
killerUi.IgnoreGuiInset = false
killerUi.Parent = playerGui

local messageBanner = Instance.new("Frame")
messageBanner.Name = "KillerMessageBanner"
messageBanner.AnchorPoint = Vector2.new(0.5, 0)
messageBanner.Position = UDim2.new(0.5, 0, KILLER_UI.TopInsetScale, 0)
messageBanner.Size = UDim2.new(KILLER_UI.WidthScale, 0, KILLER_UI.HeightScale, 0)
messageBanner.BackgroundColor3 = KILLER_UI.PanelColor
messageBanner.BackgroundTransparency = KILLER_UI.PanelTransparency
messageBanner.BorderSizePixel = 0
messageBanner.Visible = false
messageBanner.Parent = killerUi

local bannerCorner = Instance.new("UICorner")
bannerCorner.CornerRadius = UDim.new(0, KILLER_UI.CornerRadius)
bannerCorner.Parent = messageBanner

local bannerStroke = Instance.new("UIStroke")
bannerStroke.Color = KILLER_UI.BorderColor
bannerStroke.Thickness = KILLER_UI.BorderThickness
bannerStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
bannerStroke.Parent = messageBanner

local bannerPadding = Instance.new("UIPadding")
bannerPadding.PaddingTop = UDim.new(0, 10)
bannerPadding.PaddingBottom = UDim.new(0, 10)
bannerPadding.PaddingLeft = UDim.new(0, 18)
bannerPadding.PaddingRight = UDim.new(0, 18)
bannerPadding.Parent = messageBanner

local killerLabel = Instance.new("TextLabel")
killerLabel.Name = "KillerMessage"
killerLabel.Size = UDim2.fromScale(1, 1)
killerLabel.Position = UDim2.fromScale(0, 0)
killerLabel.BackgroundTransparency = 1
killerLabel.BorderSizePixel = 0
killerLabel.Text = KILLER_UI.TitleText
killerLabel.TextScaled = true
killerLabel.Font = KILLER_UI.TitleFont
killerLabel.TextColor3 = KILLER_UI.TextColor
killerLabel.TextStrokeColor3 = KILLER_UI.TextStrokeColor
killerLabel.TextStrokeTransparency = KILLER_UI.TextStrokeTransparency
killerLabel.TextXAlignment = Enum.TextXAlignment.Center
killerLabel.TextYAlignment = Enum.TextYAlignment.Center
killerLabel.Parent = messageBanner

-- Caps minimum text size so it doesn't get mushy on huge screens.
local textConstraint = Instance.new("UITextSizeConstraint")
textConstraint.MinTextSize = 18
textConstraint.MaxTextSize = 44
textConstraint.Parent = killerLabel

-- Internal state that helps us avoid double-reset bugs.
local isPossessingKiller = false
local lastAttackSentAt = 0

--[[
	Moves camera focus to a model's humanoid/root when possible.
	This works on both PC and mobile because camera behavior is separate from input.
]]
local function focusCameraOnModel(model: Model)
	local targetHumanoid = model:FindFirstChildOfClass("Humanoid")
	local targetRoot = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart

	camera.CameraType = Enum.CameraType.Custom
	if targetHumanoid then
		camera.CameraSubject = targetHumanoid
	elseif targetRoot then
		camera.CameraSubject = targetRoot
	end
end

-- Restores camera to current local character.
local function resetCameraToLocalCharacter()
	local character = localPlayer.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart

	camera.CameraType = Enum.CameraType.Custom
	if humanoid then
		camera.CameraSubject = humanoid
	elseif rootPart then
		camera.CameraSubject = rootPart
	end
end

-- Sends one attack request to server, using local throttle to reduce network spam.
local function requestAttack()
	if not isPossessingKiller then
		return
	end

	local now = os.clock()
	if now - lastAttackSentAt < KillerControlConfig.AttackCooldown then
		return
	end
	lastAttackSentAt = now

	attackRequestedEvent:FireServer()
end

-- If we are in possession mode and character changes, keep camera on new character.
localPlayer.CharacterAdded:Connect(function()
	if isPossessingKiller then
		task.defer(resetCameraToLocalCharacter)
	end
end)

-- Server notifies selected player that possession started.
possessionStartedEvent.OnClientEvent:Connect(function(killerModel: Model)
	isPossessingKiller = true
	lastAttackSentAt = 0
	killerLabel.Text = KILLER_UI.TitleText
	messageBanner.Visible = true

	if killerModel and killerModel:IsA("Model") then
		focusCameraOnModel(killerModel)
	else
		resetCameraToLocalCharacter()
	end
end)

-- Server notifies selected player that possession ended.
possessionEndedEvent.OnClientEvent:Connect(function()
	isPossessingKiller = false
	messageBanner.Visible = false
	task.defer(resetCameraToLocalCharacter)
end)

-- PC support: left-click / primary mouse button.
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
	if gameProcessedEvent or not isPossessingKiller then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		requestAttack()
	end
end)

-- Mobile support: tap anywhere to attack while possessing.
UserInputService.TouchTap:Connect(function(_touchPositions: { Vector2 }, gameProcessedEvent: boolean)
	if gameProcessedEvent or not isPossessingKiller then
		return
	end

	requestAttack()
end)

print("[KillerControl] Config loaded on client.")
print("[KillerControl] ControlDuration:", KillerControlConfig.ControlDuration)
print("[KillerControl] CooldownDuration:", KillerControlConfig.CooldownDuration)
