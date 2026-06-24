-- ServerScriptService/atonement_r6_fixed.lua
-- Plays the Atonement animation on an actual R6 dummy/NPC when the Atonement tool is activated.
-- FIXED: Ensures animations replicate to ALL players without requiring rejoin

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local StarterPack = game:GetService("StarterPack")
local RunService = game:GetService("RunService")

local TOOL_NAME = "Atonement"
local ANIM_CHILD_NAME = "AnimationId"
local DEFAULT_ANIM_ID = 123456789
local SEARCH_RADIUS = 60

local function findToolRoot()
	local containers = {ReplicatedStorage, ServerStorage, StarterPack, workspace}
	for _,container in ipairs(containers) do
		local t = container:FindFirstChild(TOOL_NAME)
		if t and t:IsA("Tool") then
			return t
		end
	end
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
				if part:FindFirstChild("BodyVelocity") or part.Parent:FindFirstChildOfClass("Humanoid") then
					part:SetNetworkOwner(nil) -- Server ownership for proper replication
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

local function playAnimationOnModel(model, animId, activatingPlayer)
	if not model then return end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	
	-- Ensure server ownership for proper animation replication
	pcall(function()
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				part:SetNetworkOwner(nil)
			end
		end
	end)
	
	local animator = ensureAnimator(humanoid)
	local animation = Instance.new("Animation")
	animation.Name = "AtonementTempAnim"
	animation.AnimationId = "rbxassetid://" .. tostring(animId)
	
	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	
	if not ok or not track then
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
	
	-- Force attribute update to trigger replication to all clients
	model:SetAttribute("AnimationPlaying_" .. tick(), animId)
	
	-- Replicate to all players by firing a change event
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part:SetAttribute("AnimSync", animId)
		end
	end
	
	return track
end

local function onToolFound(tool)
	if not tool then return end
	
	local function onEquipped(playerTool)
		local player = Players:GetPlayerFromCharacter(playerTool.Parent)
		if not player then return end
		
		local function onActivated()
			local char = player.Character
			local pos
			
			if char and char.PrimaryPart then
				pos = char.PrimaryPart.Position
			elseif char then
				local root = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChildWhichIsA("BasePart")
				if root then pos = root.Position end
			end
			
			pos = pos or Vector3.new(0, 0, 0)
			
			local target = findNearestR6NPC(pos, SEARCH_RADIUS)
			if not target then
				warn("Atonement: no R6 NPC found nearby")
				return
			end
			
			-- Set server ownership to ensure all clients see animation
			pcall(function()
				trySetNetworkOwnerOnModel(target, player)
			end)
			
			local animId = getAnimIdFromTool(tool)
			playAnimationOnModel(target, animId, player)
		end
		
		local function connectToolInstance()
			local backpack = player:FindFirstChildOfClass("Backpack")
			local tinst = (player.Character and player.Character:FindFirstChild(tool.Name)) or (backpack and backpack:FindFirstChild(tool.Name))
			if tinst and tinst:IsA("Tool") then
				if not tinst:GetAttribute("AtonementHooked") then
					tinst.Activated:Connect(onActivated)
					tinst:SetAttribute("AtonementHooked", true)
				end
			end
		end
		
		player.CharacterAdded:Connect(function()
			connectToolInstance()
		end)
		
		connectToolInstance()
	end

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			local backpack = player:FindFirstChildOfClass("Backpack")
			if backpack then
				local tinst = (player.Character and player.Character:FindFirstChild(tool.Name)) or backpack:FindFirstChild(tool.Name)
				if tinst and tinst:IsA("Tool") then
					onEquipped(tinst)
				end
			end
		end)
	end)

	tool.AncestryChanged:Connect(function(child, parent)
		if parent and parent:IsDescendantOf(Players) then
			-- do nothing
		end
	end)

	for _,player in ipairs(Players:GetPlayers()) do
		if player.Character or player:FindFirstChildOfClass("Backpack") then
			local backpack = player:FindFirstChildOfClass("Backpack")
			local tinst = (player.Character and player.Character:FindFirstChild(tool.Name)) or (backpack and backpack:FindFirstChild(tool.Name))
			if tinst and tinst:IsA("Tool") then
				onEquipped(tinst)
			end
		end
	end
end

local tool = findToolRoot()
if tool then
	onToolFound(tool)
else
	warn("Atonement tool not found. Ensure Tool named '"..TOOL_NAME.."' exists in ReplicatedStorage, ServerStorage, StarterPack or workspace.")
end
