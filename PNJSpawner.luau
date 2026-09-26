local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- shared state keeps the spawner and the other round modules on the same data
local S = require(script.Parent.GameState)
local EM = require(script.Parent.EffectManager)
local OH = require(script.Parent.OrderHelper)
local CT = require(script.Parent.ClientTypes)
local ItemsModule = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("ItemsData"))

local PS = {}

local green = Color3.fromRGB(41, 255, 17)
local orange = Color3.fromRGB(255, 162, 0)
local red = Color3.fromRGB(200, 0, 0)

local function lerpColor(c1, c2, t)
	-- each channel moves a fraction t of the distance from the first color to the second
	return Color3.new(c1.R+(c2.R-c1.R)*t, c1.G+(c2.G-c1.G)*t, c1.B+(c2.B-c1.B)*t)
end

-- split the range at halfway so the bar goes from green to orange then red
local function getPatienceColor(ratio)
	if ratio > 0.5 then return lerpColor(orange, green, (ratio-0.5)/0.5)
	else return lerpColor(red, orange, ratio/0.5) end
end

-- smooth the bar between patience updates instead of snapping its width
local function updatePatienceBar(fill, ratio)
	TweenService:Create(fill, TweenInfo.new(0.1, Enum.EasingStyle.Linear, Enum.EasingDirection.Out), {
		Size = UDim2.new(ratio, 0, 0.7, 0)
	}):Play()
end

local function freeSpot(occupiedTable, spotName, folder)
	if not spotName or not folder then return end
	local spot = folder:FindFirstChild(spotName)
	-- the table uses the part itself as a key
	-- assigning nil removes the reservation instead of keeping a false entry
	if spot then occupiedTable[spot] = nil end
end

-- reserve the chosen spot before returning so another customer cannot take it
local function getFreeSpot(folder, occupiedTable)
	local free = {}
	for _, spot in ipairs(folder:GetChildren()) do
		if spot:IsA("BasePart") and not occupiedTable[spot] then
			table.insert(free, spot)
		end
	end
	if #free > 0 then
		local chosen = free[math.random(1, #free)]
		-- there is no yield between checking and reserving the spot
		-- another spawn using this same table cannot run in the middle of this step
		occupiedTable[chosen] = true
		return chosen
	end
	return nil
end

-- tickets limit how many customers can enter the serving area
local function releaseTicket()
	if S.arrivalTicketsInUse > 0 then
		S.arrivalTicketsInUse = math.max(0, S.arrivalTicketsInUse - 1)
	end
end

-- customers can pass through each other but still collide with the map
local function ensureCollision()
	pcall(function()
		local groups = PhysicsService:GetRegisteredCollisionGroups()
		local has = false
		for _, g in ipairs(groups) do
			if g.name == "PNJ" or g.Name == "PNJ" then
				has = true
				break
			end
		end
		if not has then PhysicsService:RegisterCollisionGroup("PNJ") end
		-- the collision matrix applies this rule to every part in the PNJ group
		PhysicsService:CollisionGroupSetCollidable("PNJ", "PNJ", false)
		PhysicsService:CollisionGroupSetCollidable("PNJ", "Default", true)
	end)
end

-- avatar accessories should not push the customer around or add weight
local function sanitize(model)
	for _, acc in ipairs(model:GetDescendants()) do
		if acc:IsA("Accessory") then
			local h = acc:FindFirstChild("Handle")
			if h and h:IsA("BasePart") then
				h.CanCollide = false
				h.Massless = true
				h.CustomPhysicalProperties = PhysicalProperties.new(0.01, 0.3, 0.5, 1, 1)
			end
		end
	end
end

local function setCollisionGroup(pnj)
	for _, p in ipairs(pnj:GetDescendants()) do
		if p:IsA("BasePart") then p.CollisionGroup = "PNJ" end
	end
end

local function placeOnSpot(model, spot)
	local hum = model:FindFirstChildOfClass("Humanoid")
	local hrp = model:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or not spot then return end
	-- keep the customer physics on the server
	-- nil assigns the assembly to the server instead of letting a nearby client simulate it
	hrp:SetNetworkOwner(nil)
	hrp.CanCollide = true
	-- offset the root by the rig height so the feet sit above the spot
	local y = spot.Position.Y + hum.HipHeight + (hrp.Size.Y * 0.5)
	-- the spot orientation supplies the forward direction
	-- adding that vector to the root position gives the point for the rig to face
	local look = spot.CFrame.LookVector
	hrp.CFrame = CFrame.new(
		Vector3.new(spot.Position.X, y+0.05, spot.Position.Z),
		Vector3.new(spot.Position.X, y+0.05, spot.Position.Z) + look
	)
end

-- use a timeout so a blocked customer cannot hold this call forever
local function moveTo(humanoid, targetPos, id, timeout)
	if not humanoid or not humanoid.Parent then return false end
	timeout = timeout or 6
	local reached = false
	local anim = Instance.new("Animation")
	anim.AnimationId = "rbxassetid://" .. id
	local track = humanoid.Animator:LoadAnimation(anim)
	local conn
	local faceConn
	conn = humanoid.MoveToFinished:Connect(function(r)
		track:Stop()
		if r then reached = true end
		if conn then conn:Disconnect() end
		if faceConn then faceConn:Disconnect() end
	end)
	-- use the root height when building the direction so the turn stays horizontal
	faceConn = humanoid.MoveToFinished:Connect(function()
		local root = humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart")
		if root then
			local delta = Vector3.new(targetPos.X, root.Position.Y, targetPos.Z) - root.Position
			-- avoid normalizing a near zero vector before using it as a facing direction
			if delta.Magnitude > 0.05 then
				root.CFrame = CFrame.lookAt(root.Position, root.Position + delta.Unit)
			end
		end
	end)
	humanoid:MoveTo(targetPos)
	track:Play()
	local t = tick()
	while not reached and tick()-t < timeout do
		if not humanoid.Parent then break end
		local root = humanoid.Parent:FindFirstChild("HumanoidRootPart")
		-- allow a small distance margin when the customer is already close enough
		if root and (root.Position - targetPos).Magnitude <= 2 then reached = true track:Stop() break end
		task.wait(0.1)
	end
	-- disconnect after the wait too because the timeout may finish before the event
	if conn then conn:Disconnect() end
	if faceConn then faceConn:Disconnect() end
	return reached
end

-- reuse the friend pool only after all available friends have been picked
local function applyFriendSkin(pnj)
	-- next returns nil for an empty table so this checks whether the current pool is exhausted
	if not next(S.friendPool) and next(S.usedFriends) then
		for id in pairs(S.usedFriends) do S.friendPool[id] = true end
		S.usedFriends = {}
	end
	-- friend ids are dictionary keys so build an array for a random numeric index
	local keys = {}
	for k in pairs(S.friendPool) do table.insert(keys, k) end
	if #keys == 0 then return end
	local friendId = keys[math.random(1, #keys)]
	-- move the selected id to the used set so it cannot be picked again during this cycle
	S.friendPool[friendId] = nil
	S.usedFriends[friendId] = true
	local humanoid = pnj:FindFirstChildWhichIsA("Humanoid")
	if not humanoid then return end
	-- a failed avatar lookup should not stop the spawn
	local ok, desc = pcall(function()
		return Players:GetHumanoidDescriptionFromUserId(friendId)
	end)
	if ok and desc then humanoid:ApplyDescription(desc) end
end

-- use the customer type colors for the background and borders
local function applyTypeToBillboard(frame, clientType)
	local colors = S.TYPE_COLORS[clientType]
	if not colors or not frame then return end

	-- remove the old gradient so it does not tint the new customer type colors
	local existing = frame:FindFirstChildOfClass("UIGradient")
	if existing then existing:Destroy() end

	frame.BackgroundColor3 = colors.main

	local s = frame:FindFirstChildOfClass("UIStroke")
	if s then s.Color = colors.stroke end

	local fi = frame:FindFirstChild("Frame")
	if fi then fi.BackgroundColor3 = colors.main end

	local f1 = frame:FindFirstChild("Frame1")
	if f1 then
		f1.BackgroundColor3 = colors.main
		local s1 = f1:FindFirstChildOfClass("UIStroke")
		if s1 then s1.Color = colors.stroke end
	end
end

-- carried food is visual and should not affect movement or hit detection
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

-- only attach one carried item even if this is called again
function PS.attachServedItem(pnj, itemName)
	if not pnj or not pnj.Parent or pnj:FindFirstChild("ServedCarryItem") then return end
	if not itemName or itemName == "" then return end

	local humanoid = pnj:FindFirstChildWhichIsA("Humanoid")
	if not humanoid then return end

	local tool = makeCarryTool(itemName)
	tool.Parent = pnj
	humanoid:EquipTool(tool)
end

function PS.finalizePNJ(pnj, reason)
	if not pnj or not pnj.Parent then return end
	-- prevent repeated cleanup from releasing the same customer twice
	if pnj:GetAttribute("Finalized") then return end
	-- set the flag before the exit task starts so later calls see that cleanup already began
	pnj:SetAttribute("Finalized", reason or "unknown")

	local arriveFolder = workspace:FindFirstChild("ArrivePNJ")
	local departFolder = workspace:FindFirstChild("DepartSpots")
	freeSpot(S.occupiedArriveSpots, pnj:GetAttribute("AssignedSpot"), arriveFolder)
	freeSpot(S.occupiedDepartSpots, pnj:GetAttribute("DepartSpot"), departFolder)

	if pnj:GetAttribute("HasArrivalTicket") then
		releaseTicket()
		pnj:SetAttribute("HasArrivalTicket", nil)
	end

	local head = pnj:FindFirstChild("Head")
	local bb = head and head:FindFirstChildWhichIsA("BillboardGui")
	if bb then bb.Enabled = false end

	-- only remove the round count while the customer is still registered as active
	if S.activePNJ[pnj] then
		S.activePNJ[pnj] = nil
		S.aliveThisRound = math.max(0, S.aliveThisRound - 1)
	end

	local humanoid = pnj:FindFirstChildWhichIsA("Humanoid")
	local sortie = workspace:FindFirstChild("SortiePNJ")
	local animId = pnj:GetAttribute("IsSpecialClient") and 10921152678 or 913402848

	task.spawn(function()
		-- the exit runs in a separate task so the caller does not wait for the walk to finish
		moveTo(humanoid, sortie.Position, animId, 8)
		task.wait(0.5)
		if pnj.Parent then pnj:Destroy() end
	end)
end

function PS.spawnPNJForRound(roundNum, opts)
	local departFolder = workspace:WaitForChild("DepartSpots")
	local arriveFolder = workspace:WaitForChild("ArrivePNJ")
	local passagePart = workspace:WaitForChild("PassagePNJ")
	opts = opts or {}

	if not S.isRoundRunning or S.stopCurrentSpawn or S.lives <= 0 then return nil end

	-- wait for a spawn position while still allowing the round to stop
	local departSpot
	while not departSpot do
		if not S.isRoundRunning or S.stopCurrentSpawn or S.lives <= 0 then return nil end
		departSpot = getFreeSpot(departFolder, S.occupiedDepartSpots)
		if not departSpot then task.wait(0.25) end
	end

	local clientType = opts.special and "special" or CT.pickClientType()

	local pnj
	if opts.special then
		pnj = ServerStorage:WaitForChild("SpecialClientRig"):Clone()
		pnj.Name = "VIP_R" .. roundNum
	else
		pnj = ServerStorage:WaitForChild("TemplatePNJ"):Clone()
		pnj.Name = "PNJ_R" .. roundNum
	end
	pnj.Parent = workspace
	pnj:SetAttribute("ClientType", clientType)

	if clientType == "vacationer" then
		S.vacationersRemaining = math.max(0, S.vacationersRemaining - 1)
	end

	if not opts.special then applyFriendSkin(pnj) end
	if opts.special then
		local snd = workspace:FindFirstChild("vip")
		if snd then pcall(function() snd:Play() end) end
	end

	local anim = ServerStorage.Animate:Clone()
	anim.Parent = pnj

	ensureCollision()
	sanitize(pnj)
	setCollisionGroup(pnj)

	if not pnj.PrimaryPart then
		pnj.PrimaryPart = pnj:FindFirstChild("HumanoidRootPart") or pnj:FindFirstChildWhichIsA("BasePart")
	end

	local humanoid = pnj:FindFirstChildWhichIsA("Humanoid")
	pnj.Humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	placeOnSpot(pnj, departSpot)
	pnj:SetAttribute("DepartSpot", departSpot.Name)

	-- the expanded list tracks the full order and the counts group matching food items
	local orderExpanded, orderCounts
	if opts.special then
		orderExpanded, orderCounts = OH.pickSpecialOrder()
		pnj:SetAttribute("IsSpecialClient", true)
		pnj:SetAttribute("RewardMultiplier", S.SPECIAL_REWARD_MULT)
	elseif clientType == "inspector" then
		orderExpanded, orderCounts = OH.pickInspectorOrder(roundNum)
		pnj:SetAttribute("RewardMultiplier", 1 + math.floor(roundNum / 3) * 0.5)
	elseif clientType == "mysterious" then
		-- mysterious customers have no normal food order and are handled through their timeout
		orderExpanded, orderCounts = {}, {}
		pnj:SetAttribute("RewardMultiplier", 1)
	elseif clientType == "vacationer" then
		orderExpanded, orderCounts = OH.pickOrder(roundNum)
		pnj:SetAttribute("RewardMultiplier", 2)
	else
		orderExpanded, orderCounts = OH.pickOrder(roundNum)
		pnj:SetAttribute("RewardMultiplier", 1)
	end

	-- attributes let the serving logic and clients read the customer state
	pnj:SetAttribute("OrderCount", #orderExpanded)
	pnj:SetAttribute("ServedCount", 0)
	-- attributes cannot store a Lua table so the item list is joined into one string
	pnj:SetAttribute("Order", table.concat(orderExpanded, ";"))

	-- normal patience depends on the order while mysterious customers use a fixed timeout
	local patience = clientType == "mysterious" and S.MYSTERIOUS_TIMEOUT
		or OH.computePatienceForOrder(orderExpanded, roundNum) * (clientType == "inspector" and S.INSPECTOR_PATIENCE_MULT or 1)
	pnj:SetAttribute("PatienceMax", patience)
	pnj:SetAttribute("Patience", patience)
	pnj:SetAttribute("IsCustomer", true)

	local head = pnj:FindFirstChild("Head")
	if head then
		local bb = head:FindFirstChildWhichIsA("BillboardGui")
		if not bb then
			bb = ServerStorage.BillboardGuiTemplate:Clone()
			bb.Parent = head
		end
		bb.Adornee = head
		bb.MaxDistance = 50
		-- show the order only after the customer reaches the serving spot
		bb.Enabled = false
		local frame = bb:FindFirstChild("Frame")
		if frame then
			if clientType ~= "normal" then
				applyTypeToBillboard(frame, clientType)
			end

			local ic = frame:FindFirstChild("ItemContainer")
			if ic then
				for _, c in ipairs(ic:GetChildren()) do c:Destroy() end

				if clientType == "mysterious" then
					local img = Instance.new("ImageLabel")
					img.Size = UDim2.new(0.5,0,0.85,0)
					img.Position = UDim2.new(0.5,0,0,0)
					img.AnchorPoint = Vector2.new(0.5,0)
					img.BackgroundTransparency = 1
					img.Image = "rbxassetid://133644464181177"
					img.Parent = ic
				else
					local distinctCount = 0
					-- pairs counts dictionary entries while the length operator is meant for array sequences
					for _ in pairs(orderCounts) do distinctCount += 1 end
					pnj:SetAttribute("DistinctItemCount", distinctCount)

					local function positionForIndex(i)
						if distinctCount == 1 then
							return UDim2.new(0.5, 0, 0, 0), Vector2.new(0.5, 0)
						elseif distinctCount == 2 then
							local pos = ({0.25, 0.75})[i] or 0.5
							return UDim2.new(pos, 0, 0, 0), Vector2.new(0.5, 0)
						else
							return UDim2.new(0, (i - 1) * 52, 0, 0), Vector2.new(0, 0)
						end
					end

					-- sort item names so the icons keep a consistent order
					local keys = {}
					for n in pairs(orderCounts) do table.insert(keys, n) end
					table.sort(keys)

					for i, name in ipairs(keys) do
						local count = orderCounts[name]
						local need = Instance.new("IntValue")
						-- store a separate quantity for each food type so repeated items share one counter
						need.Name = "Need_" .. name
						need.Value = count
						need.Parent = pnj

						local img = Instance.new("ImageLabel")
						img.Name = "Item_" .. name
						img.Size = UDim2.new(0.5, 0, 0.85, 0)
						img.BackgroundTransparency = 1
						local pos, anchor = positionForIndex(i)
						img.Position = pos
						img.AnchorPoint = anchor
						local itemData = ItemsModule.GetData(name)
						img.Image = (itemData and itemData.Image) or ""
						img.Parent = ic

						local qty = ServerStorage.TextLabel:Clone()
						qty.Name = "Qty"
						qty.Text = "x" .. tostring(count)
						-- only show a quantity label when the order needs more than one of this item
						qty.Visible = (count or 1) > 1
						qty.Parent = img
					end
				end
			end

			local bar = frame:FindFirstChild("PatienceBar")
			if bar then
				if bar:FindFirstChild("Fill") then bar.Fill.Size = UDim2.new(0.97,0,0.7,0) end
				local mid = bar:FindFirstChild("MidIndicator")
				if mid then
					mid.Visible = S.currentRoundType == "streak"
						and clientType ~= "mysterious"
						and clientType ~= "inspector"
				end
			end
		end
	end

	pnj:SetAttribute("PartialBonusApplied", false)
	S.activePNJ[pnj] = true
	S.aliveThisRound += 1

	-- release reservations if the customer is removed before normal cleanup
	pnj.AncestryChanged:Connect(function(_, parent)
		-- the active set guard avoids counting a removal again after finalizePNJ already handled it
		if parent == nil and S.activePNJ[pnj] then
			S.activePNJ[pnj] = nil
			S.aliveThisRound = math.max(0, S.aliveThisRound - 1)
			if pnj:GetAttribute("HasArrivalTicket") then
				releaseTicket()
				pnj:SetAttribute("HasArrivalTicket", nil)
			end
			local df = workspace:FindFirstChild("DepartSpots")
			local af = workspace:FindFirstChild("ArrivePNJ")
			if df then freeSpot(S.occupiedDepartSpots, pnj:GetAttribute("DepartSpot"), df) end
			if af then freeSpot(S.occupiedArriveSpots, pnj:GetAttribute("AssignedSpot"), af) end
		end
	end)

	local walkAnimId = opts.special and 10921152678 or 913402848

	if humanoid then
		local ok = moveTo(humanoid, passagePart.Position, walkAnimId, 8)
		-- move a stuck customer to the passage so it can continue to the queue
		if not ok then
			local root = pnj.PrimaryPart or pnj:FindFirstChild("HumanoidRootPart")
			if root then
				local y = passagePart.Position.Y + humanoid.HipHeight + (root.Size.Y * 0.5)
				pnj:SetPrimaryPartCFrame(CFrame.lookAt(
					Vector3.new(passagePart.Position.X, y, passagePart.Position.Z),
					Vector3.new(passagePart.Position.X, y, passagePart.Position.Z) + passagePart.CFrame.LookVector,
					Vector3.new(0,1,0)
					))
			end
		end
	end

	freeSpot(S.occupiedDepartSpots, departSpot.Name, departFolder)

	-- the arrival quota is separate from the number of physical serving spots
	while S.arrivalTicketsInUse >= S.arrivalQuota do
		if not S.isRoundRunning or S.stopCurrentSpawn or S.lives <= 0 then
			if pnj and pnj.Parent then PS.finalizePNJ(pnj, "gameover") end
			return nil
		end
		task.wait(0.1)
	end

	-- claim the ticket without yielding after the quota check
	-- the attribute records ownership so cleanup knows whether this customer must return it
	S.arrivalTicketsInUse += 1
	pnj:SetAttribute("HasArrivalTicket", true)

	-- keep the ticket while waiting for an actual serving spot
	local arriveSpot
	while not arriveSpot do
		if not S.isRoundRunning or S.stopCurrentSpawn or S.lives <= 0 then
			releaseTicket()
			pnj:SetAttribute("HasArrivalTicket", nil)
			if pnj and pnj.Parent then PS.finalizePNJ(pnj, "gameover") end
			return nil
		end
		arriveSpot = getFreeSpot(arriveFolder, S.occupiedArriveSpots)
		if not arriveSpot then task.wait(0.2) end
	end

	pnj:SetAttribute("AssignedSpot", arriveSpot.Name)

	if humanoid then
		moveTo(humanoid, arriveSpot.Position, walkAnimId, 8)
		local root = pnj.PrimaryPart or pnj:FindFirstChild("HumanoidRootPart")
		if root then
			local y = arriveSpot.Position.Y + humanoid.HipHeight + (root.Size.Y * 0.5)
			pnj:SetPrimaryPartCFrame(CFrame.lookAt(
				Vector3.new(arriveSpot.Position.X, y, arriveSpot.Position.Z),
				Vector3.new(arriveSpot.Position.X, y, arriveSpot.Position.Z) + arriveSpot.CFrame.LookVector,
				Vector3.new(0,1,0)
				))
		end
		local bb = head and head:FindFirstChildWhichIsA("BillboardGui")
		if bb then bb.Enabled = true end
	end

	task.spawn(function()
		-- start patience after arrival so travel time does not count against the order
		local start = tick()
		local vfxT = ServerStorage:FindFirstChild(S.LOW_PATIENCE_VFX_NAME)
		local sndT = ServerStorage:FindFirstChild(S.LOW_PATIENCE_SOUND_NAME)
		local animInst = Instance.new("Animation")
		animInst.AnimationId = "rbxassetid://" .. tostring(S.LOW_PATIENCE_ANIM_ID)

		local lowSignaled = false
		local spawnedVFX, spawnedSound, spawnedTrack = nil, nil, nil

		while pnj.Parent do
			if pnj:GetAttribute("OrderComplete") or pnj:GetAttribute("Finalized") then break end

			-- subtract actual elapsed time because task wait does not resume at an exact interval
			local elapsed = tick() - start
			start = tick()
			-- read the current attribute each time so patience changes from other systems are preserved
			local cur = (pnj:GetAttribute("Patience") or 0) - elapsed
			pnj:SetAttribute("Patience", cur)

			if head and head:FindFirstChildWhichIsA("BillboardGui") then
				local bb = head:FindFirstChildWhichIsA("BillboardGui")
				if bb and bb.Frame and bb.Frame:FindFirstChild("PatienceBar") and bb.Frame.PatienceBar:FindFirstChild("Fill") then
					local maxP = pnj:GetAttribute("PatienceMax") or 1
					-- clamp the display ratio so the bar cannot shrink below zero or overflow
					local ratio = math.clamp(cur / maxP, 0, 1)
					updatePatienceBar(bb.Frame.PatienceBar.Fill, ratio)
					TweenService:Create(bb.Frame.PatienceBar.Fill, TweenInfo.new(0.1, Enum.EasingStyle.Linear), {
						BackgroundColor3 = getPatienceColor(ratio)
					}):Play()

					-- an eligible customer passing halfway cancels the active streak boost
					if ratio <= 0.5
						and not pnj:GetAttribute("PassedHalfway")
						and S.currentRoundType == "streak"
						and S.streakData.boosted
						and clientType ~= "mysterious"
						and clientType ~= "inspector" then
						-- remember this crossing on the customer so it cannot cancel a later boost a second time
						pnj:SetAttribute("PassedHalfway", true)
						S.streakData.boosted = false
						S.streakData.count = 0
						EM.removeStreakBoost(S.roundNumber)
						S.REFolder.StreakUpdate:FireAllClients(0, S.STREAK_REQUIRED, false)
					end

					if clientType ~= "mysterious" then
						-- trigger the warning once instead of cloning effects on every update
						if ratio <= S.LOW_PATIENCE_THRESHOLD and not lowSignaled then
							lowSignaled = true
							pnj:SetAttribute("LowPatienceSignaled", true)
							if vfxT then spawnedVFX = vfxT:Clone() spawnedVFX.Parent = head end
							if sndT then
								spawnedSound = sndT:Clone()
								spawnedSound.Parent = head
								pcall(function() spawnedSound:Play() end)
							end
							if humanoid then
								local ok, track = pcall(function() return humanoid.Animator:LoadAnimation(animInst) end)
								if ok and track then
									spawnedTrack = track
									spawnedTrack.Looped = true
									spawnedTrack:Play()
								end
							end
						end
						-- clear the warning if patience goes back above the threshold
						if ratio > S.LOW_PATIENCE_THRESHOLD and lowSignaled then
							lowSignaled = false
							pnj:SetAttribute("LowPatienceSignaled", false)
							if spawnedTrack then pcall(function() spawnedTrack:Stop(); spawnedTrack:Destroy() end) spawnedTrack = nil end
							if spawnedSound then pcall(function() spawnedSound:Stop(); spawnedSound:Destroy() end) spawnedSound = nil end
							if spawnedVFX then pcall(function() spawnedVFX:Destroy() end) spawnedVFX = nil end
						end
					end
				end
			end

			-- check completion again before applying a timeout penalty
			if cur <= 0 then
				local served = pnj:GetAttribute("ServedCount") or 0
				local need = pnj:GetAttribute("OrderCount") or math.huge
				if pnj:GetAttribute("OrderComplete") then break end
				-- a mysterious customer has an empty order so zero served must not count as completion
				if clientType ~= "mysterious" and served >= need then break end

				if spawnedTrack then pcall(function() spawnedTrack:Stop(); spawnedTrack:Destroy() end) end
				if spawnedSound then pcall(function() spawnedSound:Stop(); spawnedSound:Destroy() end) end
				if spawnedVFX then pcall(function() spawnedVFX:Destroy() end) end

				-- these two customer types leave on timeout without removing a life
				if clientType == "mysterious" or clientType == "inspector" then
					PS.finalizePNJ(pnj, "timeout")
				else
					S.lives -= 1
					S.REFolder.removelife:FireAllClients(S.lives)
					-- send the server value to every player so their life displays can stay in sync
					S.REFolder.LifeChanged:FireAllClients(S.lives)
					S.onBroadcastBuyLifeState()
					PS.finalizePNJ(pnj, "timeout")
					if S.lives <= 0 then
						S.isRoundRunning = false
						S.onGameOver()
					end
				end
				break
			end

			-- yield between updates so this loop does not block the server
			-- the elapsed time calculation accounts for any delay beyond this wait
			task.wait(0.15)
		end

		if spawnedTrack then pcall(function() spawnedTrack:Stop(); spawnedTrack:Destroy() end) end
		if spawnedSound then pcall(function() spawnedSound:Stop(); spawnedSound:Destroy() end) end
		if spawnedVFX then pcall(function() spawnedVFX:Destroy() end) end
	end)

	return pnj
end

return PS
