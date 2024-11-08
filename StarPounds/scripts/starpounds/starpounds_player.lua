require "/scripts/rect.lua"
-- Dummy empty function so we save memory.
local function nullFunction()
end
-- Run on load.
function init()
	-- Load StarPounds.
	require "/scripts/starpounds/starpounds.lua"
	-- Radio message if we have QuickbarMini instead (or with) StardustLite.
	local mmconfig = root.assetJson("/interface/scripted/mmupgrade/mmupgradegui.config")
	if mmconfig.replaced and not pcall(root.assetJson, "/metagui/registry.json") then
		player.radioMessage("starpounds_quickbar")
	elseif not mmconfig.replaced then
		player.radioMessage("starpounds_stardust")
	end
	-- Grab or create the data.
	local loadBackup = not storage.starPounds
	storage.starPounds = sb.jsonMerge(starPounds.baseData, storage.starPounds)
	-- This is stupid, but prevents 'null' data being saved.
	getmetatable(storage.starPounds).__nils = {}
	getmetatable ''.starPounds = starPounds
	starPounds.type = "player"

	if loadBackup then
		storage.starPounds = sb.jsonMerge(storage.starPounds, player.getProperty("starPoundsBackup", {}))
	end
	-- Override functions for script compatibility on different entities.
	makeOverrideFunction()
	starPounds.overrides()
	-- Setup message handlers
	starPounds.messageHandlers()
	-- Setup species traits.
	local speciesTrait = starPounds.traits[starPounds.getSpecies()] or starPounds.traits.default
	for _, skill in ipairs(speciesTrait.skills or jarray()) do
		starPounds.forceUnlockSkill(skill[1], skill[2])
	end
	-- Reload whenever the entity loads in/beams/etc.
	starPounds.statCache = {}
	starPounds.statCacheTimer = starPounds.settings.statCacheTimer
	starPounds.parseSkills()
	starPounds.parseStats()
	starPounds.accessoryModifiers = starPounds.getAccessoryModifiers()
	starPounds.parseStatusEffectStats(1)
	starPounds.stomach = starPounds.getStomach()
	starPounds.breasts = starPounds.getBreasts()
	starPounds.setWeight(storage.starPounds.weight)
	starPounds.damageHitboxTiles = damageHitboxTiles
	-- Damage listener for fall/fire damage.
	starPounds.damageListener = damageListener("damageTaken", function(notifications)
		for _, notification in pairs(notifications) do
			if notification.sourceEntityId == entity.id() and notification.targetEntityId == entity.id() then
				if notification.damageSourceKind == "falling" and starPounds.currentSizeIndex > 1 then
					-- "explosive" damage (ignores tilemods) to blocks is reduced by 80%, for a total of 5% damage applied to blocks. (Isn't reduced by the fall damage skill)
					local baseDamage = (notification.damageDealt)/(1 + starPounds.currentSize.healthBonus * (1 - starPounds.getStat("fallDamageResistance")))
					local	tileDamage = baseDamage * (1 + starPounds.currentSize.healthBonus) * 0.25
					starPounds.damageHitboxTiles(tileDamage)
					break
				end
				if starPounds.currentSizeIndex > 1 and string.find(notification.damageSourceKind, "fire") and starPounds.getStat("firePenalty") > 0 then
					local percentLost = math.round(notification.healthLost/status.resourceMax("health"), 2)
					percentLost = 2 * percentLost * starPounds.getStat("firePenalty") * (starPounds.currentSizeIndex - 1)/(#starPounds.sizes - 1)

					if percentLost > 0.01 then
						status.overConsumeResource("energy", status.resourceMax("energy") * percentLost)
						status.addEphemeralEffect("sweat")
					end
				end
			end
		end
	end)
end

function update(dt)
	-- Holy shit why can we not detect what gamemode the player is using.
	if starPounds.hasOption("disableHunger") then
		status.setResourcePercentage("food", 1)
	end
	-- Check promises.
	promises:update()
	-- Reset stat cache.
	starPounds.statCacheTimer = math.max(starPounds.statCacheTimer - dt, 0)
	if starPounds.statCacheTimer == 0 then
		starPounds.statCache = {}
		starPounds.statCacheTimer = starPounds.settings.statCacheTimer
	end
	-- Update fall damage listener.
	starPounds.damageListener:update()
	-- Check if the entity has gone up a size.
	starPounds.currentSize, starPounds.currentSizeIndex = starPounds.getSize(storage.starPounds.weight)
	starPounds.stomach = starPounds.getStomach()
	starPounds.breasts = starPounds.getBreasts()
	starPounds.currentVariant = starPounds.getChestVariant(modifierSize or starPounds.currentSize)
	starPounds.weight = storage.starPounds.weight
	starPounds.level = storage.starPounds.level
	starPounds.experience = storage.starPounds.experience
	starPounds.weightMultiplier = storage.starPounds.enabled and math.round(1 + (storage.starPounds.weight/entity.weight), 1) or 1

	local doBlobProjectile = false
	local blobProjectileActive = starPounds.blobProjectile and world.entityExists(starPounds.blobProjectile)
	if storage.starPounds.enabled then
		starPounds.damageListener:update()
		if starPounds.currentSize.isBlob then
			-- Automatically open doors in front/close doors behind since blob's cant reach to interact.
			if not starPounds.hasOption("disableBlobDoors") then
				useDoors()
			end
			-- Spawn blob projectile.
			doBlobProjectile = status.stat("activeMovementAbilities") < 1 and not starPounds.hasOption("disableBlobCollision")
			if doBlobProjectile and not blobProjectileActive then
				starPounds.blobProjectile = world.spawnProjectile("starpoundsblobhitbox", mcontroller.position(), entity.id(), {0, 0}, true)
			end
		end
	end
	-- Kill the blob projectile if we don't need it.
	if blobProjectileActive and not doBlobProjectile then
		world.callScriptedEntity(starPounds.blobProjectile, "projectile.die")
		starPounds.blobProjectile = nil
	end

	local currentSizeWeight = starPounds.currentSize.weight
	local nextSizeWeight = starPounds.sizes[starPounds.currentSizeIndex + 1] and starPounds.sizes[starPounds.currentSizeIndex + 1].weight or starPounds.settings.maxWeight
	if nextSizeWeight ~= starPounds.settings.maxWeight and starPounds.sizes[starPounds.currentSizeIndex + 1].isBlob and starPounds.hasOption("disableBlob") then
		nextSizeWeight = starPounds.settings.maxWeight
	end

	-- Cross script voodoo witch magic.
	getmetatable ''.starPounds.progress = math.round((storage.starPounds.weight - currentSizeWeight)/(nextSizeWeight - currentSizeWeight) * 100)
	getmetatable ''.starPounds.weight = storage.starPounds.weight
	getmetatable ''.starPounds.enabled = storage.starPounds.enabled
	starPounds.swapSlotItem = player.swapSlotItem()
	if starPounds.swapSlotItem and root.itemType(starPounds.swapSlotItem.name) == "consumable" then
		local replaceItem = starPounds.updateFoodItem(starPounds.swapSlotItem)
		if replaceItem then
			player.setSwapSlotItem(replaceItem)
		end
	end

	if starPounds.currentSize.size ~= (oldSize and oldSize.size or nil) then
		-- Force stat update.
		starPounds.updateStats(true)
		-- Update status effect trackers.
		starPounds.createStatuses()
		-- Don't play the sound on the first load.
		if oldSize then
			-- Play sound to indicate size change.
			world.sendEntityMessage(entity.id(), "starPounds.playSound", "digest", 0.75, math.random(10,15) * 0.1 - storage.starPounds.weight/(starPounds.settings.maxWeight * 2))
		end
	end
	-- Checks
	starPounds.voreCheck()
	starPounds.equipCheck(starPounds.currentSize)
	-- Actions.
	starPounds.eaten(dt)
	starPounds.digest(dt)
	starPounds.slosh(dt)
	starPounds.exercise(dt)
	starPounds.drink(dt)
	starPounds.lactating(dt)
	-- Stat/status updating stuff.
	starPounds.updateEffects(dt)
	starPounds.hunger(dt)
	starPounds.parseStatusEffectStats(dt)
	starPounds.updateStatuses()
	starPounds.updateStats(starPounds.optionChanged, dt)
	-- Save for comparison later.
	oldSize = starPounds.currentSize
	oldVariant = starPounds.currentVariant
	oldWeightMultiplier = starPounds.weightMultiplier

	if storage.starPounds.enabled then
		if starPounds.stomach.contents > storage.starPounds.stomachLerp and (starPounds.stomach.contents - storage.starPounds.stomachLerp) > 1 then
			storage.starPounds.stomachLerp = math.round(util.lerp(5 * dt, storage.starPounds.stomachLerp, starPounds.stomach.contents), 4)
		else
			storage.starPounds.stomachLerp = math.round(util.lerp(10 * dt, storage.starPounds.stomachLerp, starPounds.stomach.contents), 4)
		end
		if math.abs(starPounds.stomach.contents - storage.starPounds.stomachLerp) < 1 then
			storage.starPounds.stomachLerp = starPounds.stomach.contents
		end
	end
	starPounds.optionChanged = false
	-- StarExtensions/OpenStarbound integrations.
	if input then
		checkBindings(dt)
	end
	-- Debug stuff.
	if starPounds.hasOption("showDebug") then
		local data = storage.starPounds
		local stomach = starPounds.stomach
		local breasts = starPounds.breasts
		local accessory = data.accessory
		local enabled = data.enabled
		starPounds.debug("accessory", enabled and string.format("^#665599,set;Accessory: ^gray;%s", accessory and accessory.name or "None") or "^gray;Mod disabled")
		starPounds.debug("experience", enabled and string.format("^#665599,set;Level: ^gray;%s ^reset;Experience: ^gray;%.0f/%.0f ^reset;Multiplier: ^gray;%s", data.level, data.experience, starPounds.settings.experienceAmount * (1 + data.level * starPounds.settings.experienceIncrement), math.max(starPounds.getStat("experienceMultiplier") - (starPounds.hasOption("disableHunger") and math.max((starPounds.getStat("hunger") - starPounds.stats.hunger.base) * 0.2, 0) or 0), 0)) or "^gray;Mod disabled")
		starPounds.debug("stomach", enabled and string.format("^#665599,set;Fullness: ^gray;%.0f%%%% ^reset;Capacity: ^gray;%.1f/%.1f ^reset;Hunger: ^gray;%.1f/%.0f", stomach.interpolatedFullness * 100, stomach.contents, stomach.capacity, status.resource("food"), status.resourceMax("food")) or "^gray;Mod disabled")
		starPounds.debug("stomachContents", enabled and string.format("^#665599,set;Contents: ^gray;%.1f ^#665599,set;Food: ^gray;%.1f ^reset;Entities: ^gray;%d", stomach.contents, stomach.food, #data.stomachEntities) or "^gray;Mod disabled")
		starPounds.debug("breasts", enabled and string.format("^#665599,set;Type: ^gray;%s ^reset;Capacity: ^gray;%.1f/%.1f ^reset;Contents: ^gray;%.1f", breasts.type, breasts.contents, breasts.capacity, data.breasts) or "^gray;Mod disabled")
		starPounds.debug("size", enabled and string.format("^#665599,set;Size: ^gray;%s ^reset;Weight: ^gray;%.2flb ^reset;Multiplier: ^gray;%.1fx", (starPounds.currentSize.size == "" and "none" or starPounds.currentSize.size)..(starPounds.currentVariant and ": "..starPounds.currentVariant or ""), data.weight, starPounds.weightMultiplier) or "^gray;Mod disabled")
		starPounds.debug("timers", enabled and string.format("^#665599,set;Gurgle: ^gray;%.1f ^reset;Rumble: ^gray;%.1f", starPounds.gurgleTimer or 0, starPounds.rumbleTimer or 0) or "^gray;Mod disabled")
		starPounds.debug("trait", enabled and string.format("^#665599,set;Trait: ^gray;%s", storage.starPounds.trait or "None") or "^gray;Mod disabled")
	end
end

function uninit()
	if not status.resourcePositive("health") then
		local experienceProgress = storage.starPounds.experience/(starPounds.settings.experienceAmount * (1 + storage.starPounds.level * starPounds.settings.experienceIncrement))
		local experienceCost = math.ceil(starPounds.settings.deathExperiencePercentile * storage.starPounds.level * starPounds.getStat("deathPenalty"))
		local weightCost = math.ceil(storage.starPounds.weight * starPounds.settings.deathWeightPercentile * starPounds.getStat("deathPenalty"))
		-- Reduce levels and progress to next experience level.
		storage.starPounds.level = math.max(storage.starPounds.level - experienceCost, 0)
		storage.starPounds.experience = math.max(experienceProgress - (starPounds.settings.deathExperiencePercentile * starPounds.getStat("deathPenalty")), 0) * starPounds.settings.experienceAmount * (1 + storage.starPounds.level * starPounds.settings.experienceIncrement)
		-- Lose weight.
		starPounds.loseWeight(weightCost)
		-- Reset stomach.
		starPounds.resetStomach()
		starPounds.resetBreasts()
	end
	starPounds.releaseEntity(nil, true)
	starPounds.backup()
end

function damageHitboxTiles(tileDamage)
	if starPounds.hasOption("disableTileDamage") then return end
	local lowDamageTiles = {}
	local highDamageTiles = {}
	local groundLevel = 0
	local height = 0
	local width = {0, 0}
	local position = mcontroller.position()
	-- Calculate height, groundLevel, and width.
	for _, v in ipairs(mcontroller.collisionPoly()) do
		height = math.max(height, v[2])
		groundLevel = math.min(groundLevel, v[2])
		width[1] = math.min(width[1], v[1])
		width[2] = math.max(width[2], v[1])
	end
	-- Create tile damage polys.
	local lowPoly = {
		vec2.add({width[1] - 1, groundLevel - 0.5}, position),
		vec2.add({width[2] + 1, groundLevel - 0.5}, position),
		vec2.add({math.max(0, width[2] - 1.5), groundLevel - 2.5}, position),
		vec2.add({math.min(0, width[1] + 1.5), groundLevel - 2.5}, position)
	}
	local highPoly = {
		vec2.add({math.min(-0.5, width[1] + 0.5), groundLevel - 0.5}, position),
		vec2.add({math.max(0.5, width[2] - 0.5), groundLevel - 0.5}, position),
		vec2.add({math.max(0, width[2] - 1.5), groundLevel - 1.5}, position),
		vec2.add({math.min(0, width[1] + 1.5), groundLevel - 1.5}, position)
	}
	-- Check if nearby tiles fall in the damage poly.
	local tileQueryRadius = (0.5 * (math.abs(width[1]) + width[2])) - groundLevel + 1
	local foregroundTiles = world.radialTileQuery(position, tileQueryRadius, "foreground")
	for _, tile in pairs(foregroundTiles) do
		if world.polyContains(lowPoly, tile) then
			lowDamageTiles[#lowDamageTiles + 1] = tile
		end
		if world.polyContains(highPoly, tile) then
			highDamageTiles[#highDamageTiles + 1] = tile
		end
	end
	-- Damage valid tiles based on fall damage.
	world.damageTiles(lowDamageTiles, "foreground", position, "explosive", tileDamage * 0.25, 1, entity.id())
	world.damageTiles(highDamageTiles, "foreground", position, "explosive", tileDamage * 0.75, 1, entity.id())
end

function makeOverrideFunction()
  function starPounds.overrides()
    if not starPounds.didOverrides then
			local speciesData = starPounds.getSpeciesData(player.species())
      entity = {
        id = player.id,
	      weight = speciesData.weight,
	      foodType = speciesData.foodType
      }
			local mt = {__index = function () return nullFunction end}
			setmetatable(entity, mt)
    	if not speciesData.weightGain then
    		message.setHandler("starPounds.feed", simpleHandler(function(amount) status.giveResource("food", amount) end))
    		starPounds.getChestVariant = function() return "" end
    		starPounds.getDirectives = function() return "" end
    		starPounds.getBreasts = function() return {capacity = 10 * starPounds.getStat("breastCapacity"), contents = 0, fullness = 0, type = "milk"} end
    		starPounds.equipSize = nullFunction
    		starPounds.equipCheck = nullFunction
    		starPounds.gainWeight = nullFunction
    		starPounds.loseWeight = nullFunction
    		starPounds.setWeight = nullFunction
    		starPounds.getSize = function() return starPounds.sizes[1], 1 end
    	end

			-- Pizza stuff.
			starPounds.digestedPizzaEmployee = function()
				storage.starPounds.pizzaEmployeesEaten = (storage.starPounds.pizzaEmployeesEaten or 0) + 1
			end

			starPounds.boughtPizza = function()
				storage.starPounds.pizzaEmployeesEaten = nil
			end

      -- Only ever run this once per load.
      starPounds.didOverrides = true
    end
  end
end

function useDoors()
  if not (mcontroller.running() or mcontroller.walking()) then
    return
  end

	local playerBounds = rect.pad(mcontroller.boundBox(), {0, -1})
	local playerWidth = math.abs(playerBounds[3] - playerBounds[1]) * 0.5
  local openBounds = rect.translate(playerBounds, mcontroller.position())
  local closeBounds = {table.unpack(openBounds)}

  if mcontroller.movingDirection() > 0 then
		openBounds[1], openBounds[3] = openBounds[3], openBounds[3] + 0.5
    closeBounds[3], closeBounds[1] = closeBounds[1] - 3, closeBounds[1] - 3.5
  else
    openBounds[3], openBounds[1] = openBounds[1], openBounds[1] - 0.5
    closeBounds[1], closeBounds[3] = closeBounds[3] + 3, closeBounds[3] + 3.5
  end

	local function sendDoorMessage(doorId, minimumDistance, message)
    local canInteract = world.isEntityInteractive(doorId)
    local isDoor = contains(world.getObjectParameter(doorId, "scripts", jarray()), "/objects/wired/door/door.lua")
    if canInteract and isDoor then
      local distance = math.floor(math.abs(world.distance(mcontroller.position(), world.entityPosition(doorId))[1]) - playerWidth)
      if not minimumDistance or distance <= minimumDistance then
        world.sendEntityMessage(doorId, message)
      end
    end
  end

  local function queryDoors(bounds, minimumDistance, message)
    local doorIds = world.objectQuery(rect.ll(bounds), rect.ur(bounds))
    for _, doorId in ipairs(doorIds) do
      sendDoorMessage(doorId, minimumDistance, message)
    end
  end

  queryDoors(openBounds, nil, "openDoor")
  queryDoors(closeBounds, 1, "closeDoor")
end

function checkBindings(dt)
	-- Menu time.
	for _, menu in ipairs({"menu", "skills", "accessories", "options"}) do
		if input.bindDown("starpounds", menu.."Menu") then
			player.interact("ScriptPane", {gui = {}, scripts = {"/metagui.lua"}, ui = "starpounds:"..menu})
		end
	end
	-- Toggle the mod.
	if input.bindDown("starpounds", "toggle") then
		starPounds.toggleEnable()
	end
	-- Burpy.
	if input.bindDown("starpounds", "belch") then
		starPounds.belch(0.75, starPounds.belchPitch(), nil, false)
	end
	-- Eat entity.
	if input.bindDown("starpounds", "voreEat") then
		local mouthOffset = {0.375 * mcontroller.facingDirection() * (mcontroller.crouching() and 1.5 or 1), (mcontroller.crouching() and 0 or 1) - 1}
		local mouthPosition = vec2.add(world.entityMouthPosition(entity.id()), mouthOffset)
		local aimPosition = player.aimPosition()
		local positionMagnitude = math.min(world.magnitude(mouthPosition, aimPosition), 2)
		local targetPosition = vec2.add(mouthPosition, vec2.mul(vec2.norm(world.distance(aimPosition, mouthPosition)), math.max(positionMagnitude, 0)))
		starPounds.eatNearbyEntity(targetPosition, 3, 1)
	end
	-- Regurgitate last entity.
	if input.bindDown("starpounds", "voreRegurgitate") then
		starPounds.releaseEntity()
	end
	-- Lactate.
	if input.bind("starpounds", "lactate") then
		if input.bindDown("starpounds", "lactate") then
			starPounds.lactate(math.random(5, 10)/10)
		end
		-- Lactate constantly after holding for 1 second.
		starPounds.lactateBindTimer = math.max((starPounds.lactateBindTimer or 1) - dt, 0)
		if starPounds.lactateBindTimer == 0 then
			starPounds.lactate(math.random(5, 10)/10)
			starPounds.lactateBindTimer = 0.1
		end
	else
		starPounds.lactateBindTimer = nil
	end
end
