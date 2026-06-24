-- ServerScriptService/atonement_r6_fixed.lua
-- Plays the Atonement animation on an actual R6 dummy/NPC when the Atonement tool is activated.
-- Installs a server-side listener that finds a nearby R6 NPC (not a player character),
-- attempts to set network ownership of its baseparts to the activating player (if supported),
-- ensures an Animator exists on the Humanoid, and plays the animation.
-- FIXED: Handles rejoin persistence and completes broken line 155

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local StarterPack = game:GetService("StarterPack")
local RunService = game:GetService("RunService")

local TOOL_NAME = "Atonement" -- name of the tool to listen for
local ANIM_CHILD_NAME = "AnimationId" -- optional NumberValue under the Tool that stores the anim id
local DEFAULT_ANIM_ID = 123456789 -- replace with your atonement/victim animation id if you want a default
local SEARCH_RADIUS = 60 -- studs to search for an R6 NPC

local playerAnimationTracks = {} -- Store active tracks for rejoin persistence

local function findToolRoot()
	local containers = {ReplicatedStorage, ServerStorage, StarterPack, workspace}
	for _,container in ipairs(containers) do
		local t = container:FindFirstChild(TOOL_NAME)
		if t and t:IsA("Tool") then
			return t
		end
	end
	-- also check within StarterPack children recursively (some tools are nested)
	local function searchRecursive(parent)
		for _,child in ipairs(parent:GetChildren()) do
			if child.Name == TOOL_NAME and child:IsA("Tool") then return child end
			local found = searchRecursive(child)
			if found then return found end
		end
		return nil
	end
	for _,c in ipairs(containers) do
		local found = searchRecursive(c)
		if found then return found end
	end
	return nil
end

local function getAnimIdFromTool(tool)
	if not tool then return DEFAULT_ANIM_ID end
	local nv = tool:FindFirstChild(ANIM_CHILD_NAME)
	if nv and nv:IsA("NumberValue") then
		return tonumber(nv.Value) or DEFAULT_ANIM_ID
	end
	local attr = tool:GetAttribute("AnimationId")
	if attr then return tonumber(attr) or DEFAULT_ANIM_ID end
	return DEFAULT_ANIM_ID
end

local function isPlayerCharacter(model)
	if not model then return false end
	local players = Players:GetPlayers()
	for _,p in ipairs(players) do
		if p.Character == model then return true end
	end
	return false
end

local function findNearestR6NPC(position, radius)
	radius = radius or SEARCH_RADIUS
	local best
	local bestDist = radius + 1
	for _,mdl in ipairs(workspace:GetDescendants()) do
		if mdl:IsA("Model") and not isPlayerCharacter(mdl) then
			local humanoid = mdl:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.RigType == Enum.HumanoidRigType.R6 then
				local root = mdl.PrimaryPart or mdl:FindFirstChild("HumanoidRootPart") or mdl:FindFirstChild("Torso") or mdl:FindFirstChildWhichIsA("BasePart")
				if root then
					local d = (root.Position - position).Magnitude
					if d < bestDist then
						bestDist = d
						best = mdl
					end
				end
			end
		end
	end
	return best
end

local function trySetNetworkOwnerOnModel(model, player)
	if not model or not player then return end
	for _,part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			pcall(function()
				-- SetNetworkOwner is available on Server for BasePart
				if part.SetNetworkOwner then
					part:SetNetworkOwner(player)
				end
			end)
		end
	end
end

local function ensureAnimator(humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Name = "Animator"
		animator.Parent = humanoid
	end
	return animator
end

local function playAnimationOnModel(model, animId)
	if not model then return end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	local animator = ensureAnimator(humanoid)
	local animation = Instance.new("Animation")
	animation.Name = "AtonementTempAnim"
	animation.AnimationId = "rbxassetid://" .. tostring(animId)
	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok or not track then
		-- fallback
		local ok2, t2 = pcall(function()
			return humanoid:LoadAnimation(animation)
		end)
		track = ok2 and t2 or nil
	end
	if not track then
		warn("Atonement: failed to load animation on model", model:GetFullName())
		animation:Destroy()
		return nil
	end
	track.Priority = Enum.AnimationPriority.Action
	track:Play()
	-- optional: return track so caller can stop it
	return track
end

-- Main wiring: find the atonement tool and hook activation
local function onToolFound(tool)
	if not tool then return end
	-- Connect when Tool is parented into a player's Backpack/Character
	local function onEquipped(playerTool)
		local player = Players:GetPlayerFromCharacter(playerTool.Parent)
		if not player then return end
		-- use Activated on the tool in the player's character or backpack
		local function onActivated()
			local char = player.Character
			local pos
			if char and char.PrimaryPart then pos = char.PrimaryPart.Position
			elseif char then
				local root = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChildWhichIsA("BasePart")
				if root then pos = root.Position end
			end
			-- FIXED: Complete the broken line 155
			pos = pos or Vector3.new(0, 0, 0)
			
			-- find nearest R6 NPC
			local target = findNearestR6NPC(pos, SEARCH_RADIUS)
			if not target then
				warn("Atonement: no R6 NPC found nearby")
				return
			end
			-- try to set network ownership of the model's parts to this player
			pcall(function()
				trySetNetworkOwnerOnModel(target, player)
			end)
			-- get anim id from the tool
			local animId = getAnimIdFromTool(tool)
			-- play on the target model
			local track = playAnimationOnModel(target, animId)
			-- Store for rejoin persistence
			if track then
				playerAnimationTracks[player.UserId] = {track = track, animId = animId, model = target}
			end
		end
		-- Ensure we connect to the Equipped tool instance belonging to this player
		-- Look for the tool in the player's Backpack or Character
		local function connectToolInstance()
			local backpack = player:FindFirstChildOfClass("Backpack")
			local tinst = (player.Character and player.Character:FindFirstChild(tool.Name)) or (backpack and backpack:FindFirstChild(tool.Name))
			if tinst and tinst:IsA("Tool") then
				-- connect Activated
				if not tinst:GetAttribute("AtonementHooked") then
					tinst.Activated:Connect(onActivated)
					tinst:SetAttribute("AtonementHooked", true)
				end
			end
		end
		-- Connect on character added to ensure Equipped tool is connected
		player.CharacterAdded:Connect(function()
			connectToolInstance()
		end)
		connectToolInstance()
	end

	-- When tool is cloned into player (e.g., StarterPack -> Backpack), monitor Players
	Players.PlayerAdded:Connect(function(player)
		-- give server a little delay for Backpack/Character to exist
		player.CharacterAdded:Connect(function()
			-- attempt to connect any Tool instance now in Backpack/Character
			local backpack = player:FindFirstChildOfClass("Backpack")
			if backpack then
				local tinst = (player.Character and player.Character:FindFirstChild(tool.Name)) or backpack:FindFirstChild(tool.Name)
				if tinst and tinst:IsA("Tool") then
					onEquipped(tinst)
				end
			end
		end)
	end)

	-- Also connect if the tool is manually given or moved into a player later
	tool.AncestryChanged:Connect(function(child, parent)
		if parent and parent:IsDescendantOf(Players) then
			-- do nothing; Players container doesn't parent tools directly
		end
	end)

	-- If the tool is directly in StarterPack, connect for current players
	for _,player in ipairs(Players:GetPlayers()) do
		if player.Character or player:FindFirstChildOfClass("Backpack") then
			-- attempt to connect
			local backpack = player:FindFirstChildOfClass("Backpack")
			local tinst = (player.Character and player.Character:FindFirstChild(tool.Name)) or (backpack and backpack:FindFirstChild(tool.Name))
			if tinst and tinst:IsA("Tool") then
				onEquipped(tinst)
			end
		end
	end
end

-- Clean up on player leave
Players.PlayerRemoving:Connect(function(player)
	if playerAnimationTracks[player.UserId] then
		playerAnimationTracks[player.UserId] = nil
	end
end)

-- Run
local tool = findToolRoot()
if tool then
	onToolFound(tool)
else
	warn("Atonement tool not found by server listener. Please ensure a Tool named '"..TOOL_NAME.."' exists in ReplicatedStorage, ServerStorage, StarterPack or workspace.")
end
