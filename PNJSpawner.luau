-- Discord Leorizoto Roblox Leorizoto

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")

local CT = require(script.Parent.ClientTypes)
local EM = require(script.Parent.EffectManager)
local S = require(script.Parent.GameState)
local OH = require(script.Parent.OrderHelper)
local ItemsModule = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("ItemsData"))

local GREEN = Color3.fromRGB(41, 255, 17)
local ORANGE = Color3.fromRGB(255, 162, 0)
local RED = Color3.fromRGB(200, 0, 0)
local BAR_TWEEN = TweenInfo.new(0.1, Enum.EasingStyle.Linear)
local WALK_ANIMATION = 913402848
local SPECIAL_WALK_ANIMATION = 10921152678

local PS = {}
local customers = {}
local movements = {}
local collisionReady = false

local function roundIsRunning(roundNumber)
	return S.isRoundRunning and not S.stopCurrentSpawn
		and S.lives > 0 and S.roundNumber == roundNumber
end

local function customerIsActive(pnj)
	return pnj.Parent ~= nil and not pnj:GetAttribute("Finalized")
end

local function getPatienceColor(ratio)
	-- each half uses the same zero to one range for the color blend
	if ratio > 0.5 then
		return ORANGE:Lerp(GREEN, (ratio - 0.5) * 2)
	end
	return RED:Lerp(ORANGE, ratio * 2)
end

local function getFreeSpot(folder, occupied)
	local free = {}
	for _, spot in folder:GetChildren() do
		if spot:IsA("BasePart") and not occupied[spot] then
			table.insert(free, spot)
		end
	end
	if #free == 0 then
		return nil
	end

	-- checking and claiming happen without a yield so spawns cannot share a spot
	local spot = free[math.random(1, #free)]
	occupied[spot] = true
	return spot
end

local function freeSpot(pnj, attribute, folderName, occupied)
	local name = pnj:GetAttribute(attribute)
	if not name then
		return
	end
	local folder = workspace:FindFirstChild(folderName)
	local spot = folder and folder:FindFirstChild(name)
	if spot then
		occupied[spot] = nil
	end
	-- clear ownership too so later cleanup cannot release a spot reused by another customer
	pnj:SetAttribute(attribute, nil)
end

local function releaseTicket(pnj)
	if not pnj:GetAttribute("HasArrivalTicket") then
		return
	end
	pnj:SetAttribute("HasArrivalTicket", nil)
	S.arrivalTicketsInUse = math.max(0, S.arrivalTicketsInUse - 1)
end

local function ensureCollision()
	if collisionReady then
		return
	end
	if not PhysicsService:IsCollisionGroupRegistered("PNJ") then
		PhysicsService:RegisterCollisionGroup("PNJ")
	end
	PhysicsService:CollisionGroupSetCollidable("PNJ", "PNJ", false)
	PhysicsService:CollisionGroupSetCollidable("PNJ", "Default", true)
	collisionReady = true
end

local function preparePhysics(pnj)
	ensureCollision()
	for _, part in pnj:GetDescendants() do
		if not part:IsA("BasePart") then
			continue
		end
		part.CollisionGroup = "PNJ"
		if part.Name == "Handle" and part.Parent:IsA("Accessory") then
			part.CanCollide = false
			part.Massless = true
			part.CustomPhysicalProperties = PhysicalProperties.new(0.01, 0.3, 0.5, 1, 1)
		end
	end
end

local function pivotRootTo(pnj, root, target)
	-- the model pivot can differ from the root so preserve their relative offset
	local rootToPivot = root.CFrame:ToObjectSpace(pnj:GetPivot())
	pnj:PivotTo(target * rootToPivot)
end

local function placeOnSpot(pnj, spot, offset)
	local humanoid = pnj:FindFirstChildOfClass("Humanoid")
	local root = pnj:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not spot then
		return
	end
	local position = spot.Position + Vector3.new(0, humanoid.HipHeight + root.Size.Y * 0.5 + offset, 0)
	pivotRootTo(pnj, root, CFrame.lookAt(position, position + spot.CFrame.LookVector))
end

local function stopTrack(track)
	if not track then
		return
	end
	track:Stop()
	track:Destroy()
end

local function loadTrack(humanoid, animationId)
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = "rbxassetid://" .. tostring(animationId)
	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	-- the track keeps the loaded animation so the temporary instance can be removed
	animation:Destroy()
	if not ok then
		warn("PNJ animation could not load", track)
		return nil
	end
	return track
end

local function cancelMovement(humanoid)
	local movement = movements[humanoid]
	if not movement then
		return
	end
	movements[humanoid] = nil
	movement.connection:Disconnect()
	stopTrack(movement.track)
end

local function moveTo(humanoid, position, animationId, timeout, canContinue)
	if not humanoid or not humanoid.Parent then
		return false
	end
	local model = humanoid.Parent
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	cancelMovement(humanoid)
	local track = loadTrack(humanoid, animationId)
	local reached = false
	local finished = false
	-- one connection handles the result so separate callbacks cannot cancel each other
	local connection = humanoid.MoveToFinished:Connect(function(success)
		reached = success
		finished = true
	end)
	local movement = { connection = connection, track = track }
	movements[humanoid] = movement
	humanoid:MoveTo(position)
	if track then
		track:Play()
	end
	local deadline = os.clock() + timeout
	while model.Parent and movements[humanoid] == movement and not finished and os.clock() < deadline do
		if canContinue and not canContinue() then
			break
		end
		if (root.Position - position).Magnitude <= 2 then
			reached = true
			break
		end
		task.wait(0.1)
	end
	-- an older movement must not stop the exit walk that replaced it
	if movements[humanoid] ~= movement then
		return false
	end
	cancelMovement(humanoid)
	-- stop the move command as well when the wait was cancelled or timed out
	if model.Parent and not reached then
		humanoid:MoveTo(root.Position)
	end
	return reached
end

local function applyFriendSkin(pnj)
	local humanoid = pnj:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	if not next(S.friendPool) and next(S.usedFriends) then
		for id in S.usedFriends do
			S.friendPool[id] = true
		end
		table.clear(S.usedFriends)
	end
	local ids = {}
	for id in S.friendPool do
		table.insert(ids, id)
	end
	if #ids == 0 then
		return
	end
	local id = ids[math.random(1, #ids)]
	S.friendPool[id] = nil
	S.usedFriends[id] = true
	local description
	-- both avatar operations can yield or fail so protect the whole request
	local ok, err = pcall(function()
		description = Players:GetHumanoidDescriptionFromUserIdAsync(id)
		if customerIsActive(pnj) then
			humanoid:ApplyDescriptionAsync(description)
		end
	end)
	if description then
		description:Destroy()
	end
	if not ok then
		warn("PNJ appearance could not load", err)
	end
end

local function colorFrame(frame, colors)
	if not frame then
		return
	end
	frame.BackgroundColor3 = colors.main
	local stroke = frame:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = colors.stroke
	end
end

local function applyTypeToBillboard(frame, clientType)
	local colors = S.TYPE_COLORS[clientType]
	if not colors then
		return
	end
	local gradient = frame:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient:Destroy()
	end
	colorFrame(frame, colors)
	colorFrame(frame:FindFirstChild("Frame"), colors)
	colorFrame(frame:FindFirstChild("Frame1"), colors)
end

local function prepCarryPart(part)
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.CastShadow = false
end

local function makeCarryTool(itemName)
	local tool = Instance.new("Tool")
	tool.Name = "ServedCarryItem"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool:SetAttribute("ItemName", itemName)
	-- combine a local offset with a rotation to set how the food sits in the hand
	-- CFrame angles use radians so the 90 degree turn is converted first
	tool.Grip = CFrame.new(0, -0.08, -0.32) * CFrame.Angles(math.rad(90), 0, 0)

	local base = Instance.new("Part")
	base.Name = "Handle"
	base.Size = Vector3.new(0.55, 0.18, 0.55)
	base.Shape = Enum.PartType.Cylinder
	base.Material = Enum.Material.SmoothPlastic
	base.Color = Color3.fromRGB(245, 238, 218)
	base.Parent = tool
	prepCarryPart(base)

	local function addPart(name, size, color, offset, shape)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.Shape = shape or Enum.PartType.Block
		p.Material = Enum.Material.SmoothPlastic
		p.Color = color
		-- apply the food offset in handle space so the pieces stay aligned
		p.CFrame = base.CFrame * offset
		p.Parent = tool
		prepCarryPart(p)

		-- keep each food piece attached when the humanoid moves the tool
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = base
		weld.Part1 = p
		weld.Parent = base
		return p
	end

	if itemName == "Soup_Miso" then
		base.Color = Color3.fromRGB(240, 245, 250)
		addPart("Soup", Vector3.new(0.5, 0.08, 0.5), Color3.fromRGB(174, 112, 57), CFrame.new(0, 0.12, 0), Enum.PartType.Cylinder)
		addPart("Steam", Vector3.new(0.06, 0.24, 0.06), Color3.fromRGB(235, 235, 235), CFrame.new(0.12, 0.32, 0.04), Enum.PartType.Ball).Transparency = 0.25
	elseif itemName == "Rice" then
		base.Color = Color3.fromRGB(235, 235, 235)
		addPart("RiceMound", Vector3.new(0.48, 0.24, 0.48), Color3.fromRGB(255, 255, 245), CFrame.new(0, 0.18, 0), Enum.PartType.Ball)
	elseif itemName == "Riz_Saumon" then
		base.Color = Color3.fromRGB(255, 255, 245)
		addPart("Salmon", Vector3.new(0.58, 0.12, 0.34), Color3.fromRGB(255, 132, 93), CFrame.new(0, 0.18, 0), Enum.PartType.Block)
	elseif itemName == "Riz_Omelet_Algue" then
		base.Color = Color3.fromRGB(255, 255, 245)
		addPart("Omelet", Vector3.new(0.58, 0.12, 0.36), Color3.fromRGB(245, 208, 77), CFrame.new(0, 0.18, 0), Enum.PartType.Block)
		addPart("Seaweed", Vector3.new(0.16, 0.14, 0.42), Color3.fromRGB(38, 74, 55), CFrame.new(0, 0.2, 0), Enum.PartType.Block)
	else
		base.Color = Color3.fromRGB(255, 244, 205)
		addPart("Snack", Vector3.new(0.42, 0.22, 0.42), Color3.fromRGB(226, 183, 91), CFrame.new(0, 0.18, 0), Enum.PartType.Ball)
	end

	return tool
end


function PS.attachServedItem(pnj, itemName)
	if not pnj or not customerIsActive(pnj) or pnj:FindFirstChild("ServedCarryItem") then
		return
	end
	if not itemName or itemName == "" then
		return
	end
	local humanoid = pnj:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local tool = makeCarryTool(itemName)
	tool.Parent = pnj
	humanoid:EquipTool(tool)
end

local function clearWarning(context)
	stopTrack(context.warningTrack)
	context.warningTrack = nil
	if context.warningSound then
		context.warningSound:Destroy()
		context.warningSound = nil
	end
	if context.warningVFX then
		context.warningVFX:Destroy()
		context.warningVFX = nil
	end
	context.warningActive = false
end

local function unregisterCustomer(pnj)
	local context = customers[pnj]
	customers[pnj] = nil
	if context then
		cancelMovement(context.humanoid)
		clearWarning(context)
		if context.barTween then
			context.barTween:Cancel()
			context.barTween:Destroy()
		end
		context.removalConnection:Disconnect()
	end
	freeSpot(pnj, "AssignedSpot", "ArrivePNJ", S.occupiedArriveSpots)
	freeSpot(pnj, "DepartSpot", "DepartSpots", S.occupiedDepartSpots)
	releaseTicket(pnj)
	if S.activePNJ[pnj] then
		S.activePNJ[pnj] = nil
		S.aliveThisRound = math.max(0, S.aliveThisRound - 1)
	end
end

function PS.finalizePNJ(pnj, reason)
	if not pnj or not customerIsActive(pnj) then
		return
	end
	-- mark the customer before yielding so timeout and serving cannot both finalize it
	pnj:SetAttribute("Finalized", reason or "unknown")
	local context = customers[pnj]
	if context and context.billboard then
		context.billboard.Enabled = false
	end
	unregisterCustomer(pnj)
	local humanoid = pnj:FindFirstChildOfClass("Humanoid")
	local exit = workspace:FindFirstChild("SortiePNJ")
	local animationId = pnj:GetAttribute("IsSpecialClient") and SPECIAL_WALK_ANIMATION or WALK_ANIMATION
	task.spawn(function()
		if exit and exit:IsA("BasePart") then
			moveTo(humanoid, exit.Position, animationId, 8)
		end
		task.wait(0.5)
		pnj:Destroy()
	end)
end

local function registerCustomer(pnj, roundNumber)
	local context = { roundNumber = roundNumber, warningActive = false }
	customers[pnj] = context
	S.activePNJ[pnj] = true
	S.aliveThisRound += 1
	-- register before avatar loading because that request can yield while the round ends
	context.removalConnection = pnj.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			unregisterCustomer(pnj)
		end
	end)
	return context
end

local function selectOrder(pnj, roundNumber, clientType, special)
	if special then
		pnj:SetAttribute("IsSpecialClient", true)
		pnj:SetAttribute("RewardMultiplier", S.SPECIAL_REWARD_MULT)
		return OH.pickSpecialOrder()
	end
	if clientType == "inspector" then
		pnj:SetAttribute("RewardMultiplier", 1 + math.floor(roundNumber / 3) * 0.5)
		return OH.pickInspectorOrder(roundNumber)
	end
	pnj:SetAttribute("RewardMultiplier", clientType == "vacationer" and 2 or 1)
	if clientType == "mysterious" then
		return {}, {}
	end
	return OH.pickOrder(roundNumber)
end

local function configureOrder(pnj, roundNumber, clientType, special)
	local expanded, counts = selectOrder(pnj, roundNumber, clientType, special)
	pnj:SetAttribute("OrderCount", #expanded)
	pnj:SetAttribute("ServedCount", 0)
	-- attributes cannot hold tables so the shared order uses a separated string
	pnj:SetAttribute("Order", table.concat(expanded, ";"))
	local patience = S.MYSTERIOUS_TIMEOUT
	if clientType ~= "mysterious" then
		patience = OH.computePatienceForOrder(expanded, roundNumber)
		if clientType == "inspector" then
			patience *= S.INSPECTOR_PATIENCE_MULT
		end
	end
	pnj:SetAttribute("PatienceMax", patience)
	pnj:SetAttribute("Patience", patience)
	pnj:SetAttribute("IsCustomer", true)
	pnj:SetAttribute("PartialBonusApplied", false)
	return counts
end

local function positionForIndex(index, count)
	if count == 1 then
		return UDim2.fromScale(0.5, 0), Vector2.new(0.5, 0)
	end
	if count == 2 then
		return UDim2.fromScale(index == 1 and 0.25 or 0.75, 0), Vector2.new(0.5, 0)
	end
	return UDim2.fromOffset((index - 1) * 52, 0), Vector2.zero
end

local function createOrderIcon(container, name, index, count)
	local image = Instance.new("ImageLabel")
	image.Name = "Item_" .. name
	image.Size = UDim2.fromScale(0.5, 0.85)
	image.BackgroundTransparency = 1
	image.Position, image.AnchorPoint = positionForIndex(index, count)
	local data = ItemsModule.GetData(name)
	image.Image = data and data.Image or ""
	image.Parent = container
	return image
end

local function fillOrderIcons(pnj, container, counts, clientType)
	container:ClearAllChildren()
	if clientType == "mysterious" then
		local image = Instance.new("ImageLabel")
		image.Size = UDim2.fromScale(0.5, 0.85)
		image.Position = UDim2.fromScale(0.5, 0)
		image.AnchorPoint = Vector2.new(0.5, 0)
		image.BackgroundTransparency = 1
		image.Image = "rbxassetid://133644464181177"
		image.Parent = container
		return
	end
	local names = {}
	for name in counts do
		table.insert(names, name)
	end
	-- sorting dictionary keys keeps the icon order stable between customers
	table.sort(names)
	pnj:SetAttribute("DistinctItemCount", #names)
	for index, name in names do
		local need = Instance.new("IntValue")
		need.Name = "Need_" .. name
		need.Value = counts[name]
		need.Parent = pnj
		local image = createOrderIcon(container, name, index, #names)
		local quantity = ServerStorage.TextLabel:Clone()
		quantity.Name = "Qty"
		quantity.Text = "x" .. tostring(counts[name])
		quantity.Visible = counts[name] > 1
		quantity.Parent = image
	end
end

local function prepareBillboard(pnj, context, counts, clientType)
	local head = pnj:FindFirstChild("Head")
	if not head then
		return
	end
	context.head = head
	local billboard = head:FindFirstChildWhichIsA("BillboardGui")
	if not billboard then
		billboard = ServerStorage.BillboardGuiTemplate:Clone()
		billboard.Parent = head
	end
	context.billboard = billboard
	billboard.Adornee = head
	billboard.MaxDistance = 50
	billboard.Enabled = false
	local frame = billboard:FindFirstChild("Frame")
	if not frame then
		return
	end
	applyTypeToBillboard(frame, clientType)
	local container = frame:FindFirstChild("ItemContainer")
	if container then
		fillOrderIcons(pnj, container, counts, clientType)
	end
	local bar = frame:FindFirstChild("PatienceBar")
	if not bar then
		return
	end
	context.fill = bar:FindFirstChild("Fill")
	if context.fill then
		context.fill.Size = UDim2.fromScale(0.97, 0.7)
	end
	local marker = bar:FindFirstChild("MidIndicator")
	if marker then
		marker.Visible = S.currentRoundType == "streak"
			and clientType ~= "mysterious" and clientType ~= "inspector"
	end
end

local function updatePatienceBar(context, ratio)
	local fill = context.fill
	if not fill or not fill.Parent then
		return
	end
	-- keep one tween per customer instead of separate size and color tweens
	if context.barTween then
		context.barTween:Cancel()
		context.barTween:Destroy()
	end
	context.barTween = TweenService:Create(fill, BAR_TWEEN, {
		Size = UDim2.fromScale(ratio, 0.7),
		BackgroundColor3 = getPatienceColor(ratio),
	})
	context.barTween:Play()
end

local function updateStreak(pnj, ratio, clientType)
	if ratio > 0.5 or pnj:GetAttribute("PassedHalfway") then
		return
	end
	if S.currentRoundType ~= "streak" or not S.streakData.boosted then
		return
	end
	if clientType == "mysterious" or clientType == "inspector" then
		return
	end
	pnj:SetAttribute("PassedHalfway", true)
	S.streakData.boosted = false
	S.streakData.count = 0
	EM.removeStreakBoost(S.roundNumber)
	S.REFolder.StreakUpdate:FireAllClients(0, S.STREAK_REQUIRED, false)
end

local function startWarning(pnj, context)
	context.warningActive = true
	pnj:SetAttribute("LowPatienceSignaled", true)
	local vfx = ServerStorage:FindFirstChild(S.LOW_PATIENCE_VFX_NAME)
	if vfx then
		context.warningVFX = vfx:Clone()
		context.warningVFX.Parent = context.head
	end
	local sound = ServerStorage:FindFirstChild(S.LOW_PATIENCE_SOUND_NAME)
	if sound and sound:IsA("Sound") then
		context.warningSound = sound:Clone()
		context.warningSound.Parent = context.head
		context.warningSound:Play()
	end
	context.warningTrack = loadTrack(context.humanoid, S.LOW_PATIENCE_ANIM_ID)
	if context.warningTrack then
		context.warningTrack.Looped = true
		context.warningTrack:Play()
	end
end

local function updateWarning(pnj, context, ratio, clientType)
	if clientType == "mysterious" or not context.head or not context.head.Parent then
		return
	end
	local isLow = ratio <= S.LOW_PATIENCE_THRESHOLD
	if isLow == context.warningActive then
		return
	end
	-- react only when crossing the threshold so the loop does not clone effects repeatedly
	if isLow then
		startWarning(pnj, context)
		return
	end
	clearWarning(context)
	pnj:SetAttribute("LowPatienceSignaled", false)
end

local function orderIsComplete(pnj, clientType)
	if pnj:GetAttribute("OrderComplete") then
		return true
	end
	-- an empty mysterious order must not count as a completed normal order
	return clientType ~= "mysterious"
		and (pnj:GetAttribute("ServedCount") or 0) >= (pnj:GetAttribute("OrderCount") or math.huge)
end

local function handleTimeout(pnj, clientType)
	if orderIsComplete(pnj, clientType) then
		return
	end
	if clientType == "mysterious" or clientType == "inspector" then
		PS.finalizePNJ(pnj, "timeout")
		return
	end
	S.lives = math.max(0, S.lives - 1)
	S.REFolder.removelife:FireAllClients(S.lives)
	S.REFolder.LifeChanged:FireAllClients(S.lives)
	S.onBroadcastBuyLifeState()
	PS.finalizePNJ(pnj, "timeout")
	if S.lives <= 0 then
		S.isRoundRunning = false
		S.onGameOver()
	end
end

local function runPatience(pnj, context, clientType)
	local previousTime = os.clock()
	while customerIsActive(pnj) and not pnj:GetAttribute("OrderComplete") do
		if not roundIsRunning(context.roundNumber) then
			PS.finalizePNJ(pnj, "roundended")
			break
		end
		-- use elapsed time because a resumed task can run later than the requested wait
		local now = os.clock()
		local patience = (pnj:GetAttribute("Patience") or 0) - (now - previousTime)
		previousTime = now
		pnj:SetAttribute("Patience", patience)
		local maximum = math.max(pnj:GetAttribute("PatienceMax") or 1, 0.001)
		local ratio = math.clamp(patience / maximum, 0, 1)
		updatePatienceBar(context, ratio)
		updateStreak(pnj, ratio, clientType)
		updateWarning(pnj, context, ratio, clientType)
		if patience <= 0 then
			handleTimeout(pnj, clientType)
			break
		end
		task.wait(0.15)
	end
	clearWarning(context)
end

local function waitForSpot(folder, occupied, canContinue)
	while canContinue() do
		local spot = getFreeSpot(folder, occupied)
		if spot then
			return spot
		end
		task.wait(0.2)
	end
	return nil
end

local function claimArrival(pnj, canContinue)
	while canContinue() do
		if S.arrivalTicketsInUse < S.arrivalQuota then
			-- claim without yielding after the check and record who must return the ticket
			S.arrivalTicketsInUse += 1
			pnj:SetAttribute("HasArrivalTicket", true)
			return true
		end
		task.wait(0.1)
	end
	return false
end

local function prepareCustomer(pnj, context, departSpot, clientType, special)
	if not special then
		applyFriendSkin(pnj)
	end
	if not customerIsActive(pnj) or not roundIsRunning(context.roundNumber) then
		return false
	end
	local humanoid = pnj:FindFirstChildOfClass("Humanoid")
	local root = pnj:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then
		return false
	end
	context.humanoid = humanoid
	pnj.PrimaryPart = root
	preparePhysics(pnj)
	-- assigning nil keeps physics on the server when the assembly supports ownership
	local canSetOwnership = root:CanSetNetworkOwnership()
	if canSetOwnership then
		root:SetNetworkOwner(nil)
	end
	root.CanCollide = true
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	local animate = ServerStorage:FindFirstChild("Animate")
	if animate then
		animate:Clone().Parent = pnj
	end
	placeOnSpot(pnj, departSpot, 0.05)
	local counts = configureOrder(pnj, context.roundNumber, clientType, special)
	prepareBillboard(pnj, context, counts, clientType)
	return true
end

local function arriveAtCounter(pnj, context, passage, arriveFolder, animationId)
	local function canContinue()
		return customerIsActive(pnj) and roundIsRunning(context.roundNumber)
	end
	local reached = moveTo(context.humanoid, passage.Position, animationId, 8, canContinue)
	if not canContinue() then
		return false
	end
	if not reached then
		placeOnSpot(pnj, passage, 0)
	end
	freeSpot(pnj, "DepartSpot", "DepartSpots", S.occupiedDepartSpots)
	if not claimArrival(pnj, canContinue) then
		return false
	end
	local spot = waitForSpot(arriveFolder, S.occupiedArriveSpots, canContinue)
	if not spot then
		return false
	end
	pnj:SetAttribute("AssignedSpot", spot.Name)
	moveTo(context.humanoid, spot.Position, animationId, 8, canContinue)
	-- a round can end during movement so recheck before starting the order timer
	if not canContinue() then
		return false
	end
	placeOnSpot(pnj, spot, 0)
	if context.billboard then
		context.billboard.Enabled = true
	end
	return true
end

local function cloneCustomer(template)
	local pnj = template:Clone()
	-- remove the template animation controller before it can run as a player script
	-- the shared npc controller is added after the appearance is ready
	for _, child in pnj:GetChildren() do
		if child.Name == "Animate" and child:IsA("LuaSourceContainer") then
			child:Destroy()
		end
	end
	return pnj
end

function PS.spawnPNJForRound(roundNumber, opts)
	opts = opts or {}
	if not roundIsRunning(roundNumber) then
		return nil
	end
	local departFolder = workspace:FindFirstChild("DepartSpots")
	local arriveFolder = workspace:FindFirstChild("ArrivePNJ")
	local passage = workspace:FindFirstChild("PassagePNJ")
	local template = ServerStorage:FindFirstChild(opts.special and "SpecialClientRig" or "TemplatePNJ")
	if not departFolder or not arriveFolder or not passage or not template then
		warn("PNJ spawn is missing a required map object or template")
		return nil
	end
	local departSpot = waitForSpot(departFolder, S.occupiedDepartSpots, function()
		return roundIsRunning(roundNumber)
	end)
	if not departSpot then
		return nil
	end
	local clientType = opts.special and "special" or CT.pickClientType()
	local pnj = cloneCustomer(template)
	pnj.Name = (opts.special and "VIP_R" or "PNJ_R") .. roundNumber
	pnj:SetAttribute("ClientType", clientType)
	pnj:SetAttribute("DepartSpot", departSpot.Name)
	pnj.Parent = workspace
	local context = registerCustomer(pnj, roundNumber)
	if clientType == "vacationer" then
		S.vacationersRemaining = math.max(0, S.vacationersRemaining - 1)
	end
	local ok, prepared = pcall(prepareCustomer, pnj, context, departSpot, clientType, opts.special)
	if not ok or not prepared then
		if not ok then
			warn("PNJ setup failed", prepared)
		end
		PS.finalizePNJ(pnj, "cancelled")
		return nil
	end
	local vipSound = opts.special and workspace:FindFirstChild("vip")
	if vipSound and vipSound:IsA("Sound") then
		vipSound:Play()
	end
	local animationId = opts.special and SPECIAL_WALK_ANIMATION or WALK_ANIMATION
	if not arriveAtCounter(pnj, context, passage, arriveFolder, animationId) then
		PS.finalizePNJ(pnj, "cancelled")
		return nil
	end
	-- only start patience at the counter so time spent walking does not punish the player
	task.spawn(runPatience, pnj, context, clientType)
	return pnj
end

return PS
