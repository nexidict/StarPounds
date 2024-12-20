-- Dummy empty function so we save memory.
local function nullFunction()
end
-- Old functions. (we call these in functons we replace)
local init_old = init or nullFunction
local update_old = update or nullFunction
local uninit_old = uninit or nullFunction
-- Run on load.
function starPoundsInit()
	require "/scripts/starpounds/starpounds.lua"
	storage.starPounds = sb.jsonMerge(starPounds.baseData, storage.starPounds)
	-- This is stupid, but prevents 'null' data being saved.
	getmetatable(storage.starPounds).__nils = {}
	-- Used in functions for detection.
	starPounds.type = "monster"
	starPounds.isCritter = contains(starPounds.settings.critterBehaviors, config.getParameter("behavior", "monster")) ~= nil
	-- Replace some functions.
	makeOverrideFunction()
	starPounds.overrides()
	-- Setup message handlers
	starPounds.messageHandlers()
	message.setHandler("starPounds.notifyDamage", simpleHandler(function(args)
		self.damaged = true
		self.board:setEntity("damageSource", args.sourceId)
	end))
	-- Reload whenever the entity loads in/beams/etc.
	starPounds.statCache = {}
	starPounds.statCacheTimer = starPounds.settings.statCacheTimer
	storage.starPounds.options = sb.jsonMerge(storage.starPounds.options, config.getParameter("starPounds_options", {}))
	if not storage.starPounds.parsedInitialSkills then
		local skills = config.getParameter("starPounds_skills", {})
		for k, v in pairs(skills) do
			local level = 0
			if type(v) == "table" then
				level = math.random(v[1], v[2])
			elseif type(v) == "number" then
				level = v
			end
			if level > 0 then
				skills[k] = jarray()
				skills[k][1] = level
				skills[k][2] = level
			else
				skills[k] = nil
			end
		end
		storage.starPounds.skills = sb.jsonMerge(storage.starPounds.skills, skills)
		storage.starPounds.parsedInitialSkills = true
	end

	starPounds.parseSkills()
	starPounds.parseStats()
	starPounds.accessoryModifiers = starPounds.getAccessoryModifiers()
	starPounds.stomach = starPounds.getStomach()
	starPounds.currentVariant = starPounds.getChestVariant()
	starPounds.level = storage.starPounds.level
	starPounds.experience = storage.starPounds.experience
	starPounds.weightMultiplier = math.round(1 + (storage.starPounds.weight/entity.weight), 1)
	starPounds.moduleInit(starPounds.type)
	starPounds.effectInit()
	if not starPounds.getTrait() then
		starPounds.setTrait(config.getParameter("starPounds_trait"))
	end
end

function init()
	-- Run old NPC/Monster stuff.
	init_old()
	starPoundsInit()
end

function update(dt)
	if not starPounds then
		require "/scripts/starpounds/starpounds.lua"
		starPoundsInit()
	end
	-- Run old NPC/Monster stuff.
	update_old(dt)
	-- Check promises.
	promises:update()
	-- Reset stat cache.
	starPounds.statCacheTimer = math.max(starPounds.statCacheTimer - dt, 0)
	if starPounds.statCacheTimer == 0 then
		starPounds.statCache = {}
		starPounds.statCacheTimer = starPounds.settings.statCacheTimer
	end
	starPounds.stomach = starPounds.getStomach()
	-- Checks
	starPounds.voreCheck()
	-- Actions.
	starPounds.eaten(dt)
	starPounds.digest(dt)
	-- Stat/status updating stuff.
	starPounds.updateEffects(dt)
	-- Modules.
	starPounds.moduleUpdate(dt)
	starPounds.optionChanged = false
end

function uninit()
	starPounds.moduleUninit()
	uninit_old()
end

function makeOverrideFunction()
  function starPounds.overrides()
    if not starPounds.didOverrides then
			-- No debug stuffs for monsters
			starPounds.debug = nullFunction
			-- Shortcuts to make functions work for monsters.
			player = {}
			local mt = {__index = function () return nullFunction end}
			setmetatable(player, mt)
			entity.setDropPool = monster.setDropPool
			entity.setDeathParticleBurst = monster.setDeathParticleBurst
			entity.setDeathSound = monster.setDeathSound
			entity.setDamageOnTouch = monster.setDamageOnTouch
			entity.setDamageSources = monster.setDamageSources
			entity.setDamageTeam = monster.setDamageTeam
			local boundBox = mcontroller.boundBox()
			local monsterArea = math.abs(boundBox[1]) + math.abs(boundBox[3]) * math.abs(boundBox[2]) + math.abs(boundBox[4])
			entity.weight = math.min(math.round(monsterArea * starPounds.settings.voreMonsterFood), starPounds.settings.voreMonsterFoodCap)
			local deathActions = config.getParameter("behaviorConfig.deathActions", {})
			-- Remove base weight if the monster is 'replaced'.
			for _, action in ipairs(deathActions) do
				if action.name == "action-spawnmonster" and action.parameters.replacement then
					entity.weight = 0
				end
			end
			for _, action in ipairs(deathActions) do
				if action.name == "action-spawnmonster" then
					local monsterPoly = root.monsterParameters(action.parameters.monsterType).movementSettings.collisionPoly
					local boundBox = util.boundBox(monsterPoly)
					local monsterArea = math.abs(boundBox[1]) + math.abs(boundBox[3]) * math.abs(boundBox[2]) + math.abs(boundBox[4])
					entity.weight = entity.weight + math.min(math.round(monsterArea * starPounds.settings.voreMonsterFood), starPounds.settings.voreMonsterFoodCap)
				end
			end
			-- Robotic monsters don't give food.
			entity.foodType = "preyMonster"
			if status.statusProperty("targetMaterialKind") == "robotic" then
				entity.foodType = "preyMonsterInedible"
			end
			-- No XP if the monster is a pet (prevents infinite XP). Using configParameter instead of hasOption because default options aren't merged yet when this runs.
			if config.getParameter("starPounds_options.disableExperience") or (capturable and (capturable.tetherUniqueId() or capturable.ownerUuid())) then
				entity.foodType = entity.foodType.."_noExperience"
			end
			-- Monsters don't have a food stat, and trying to adjust it crashes the script.
			starPounds.feed = starPounds.eat
			-- Disable stuff monsters don't use
			starPounds.getChestVariant = function() return "" end
			starPounds.getDirectives = function() return "" end
			starPounds.getSpecies = function() return "" end
			starPounds.equipSize = nullFunction
			starPounds.equipCheck = nullFunction
			starPounds.updateStats = nullFunction
			starPounds.gainWeight = nullFunction
			starPounds.loseWeight = nullFunction
			starPounds.setWeight = nullFunction
			starPounds.gainMilk = nullFunction
			starPounds.lactate = nullFunction
			-- Save default functions.
			openDoors_old = openDoors_old or openDoors
			closeDoors_old = closeDoors_old or closeDoors
			closeDoorsBehind_old = closeDoorsBehind_old or closeDoorsBehind
			-- Override default functions.
			closeDoorsBehind = function() if storage.starPounds.pred then closeDoorsBehind_old() end end
			openDoors = function(...) return storage.starPounds.pred and false or openDoors_old(...) end
			closeDoors = function(...) return storage.starPounds.pred and false or closeDoors_old(...) end
			-- Ignore things that have been eaten.
			entity.isValidTarget_old = entity.isValidTarget_old or entity.isValidTarget
			entity.isValidTarget = function(entityId)
				local eatenEntity = nil
				if not world.entityExists(entityId) then return false end
				for preyIndex, prey in ipairs(storage.starPounds.stomachEntities) do
					if prey.id == entityId then
						eatenEntity = prey
					end
				end
				if #world.monsterQuery(world.entityPosition(entityId), 1, {withoutEntityId = entity.id(), callScript = "hasEatenEntity", callScriptArgs = {{entity = entityId}}}) > 0 then
					return false
				end
				if #world.npcQuery(world.entityPosition(entityId), 1, {withoutEntityId = entity.id(), callScript = "hasEatenEntity", callScriptArgs = {{entity = entityId}}}) > 0 then
					return false
				end
				if eatenEntity then return false end
				return entity.isValidTarget_old(entityId)
			end
      -- Only ever run this once per load.
      starPounds.didOverrides = true
    end
  end
end

-- Default override functions
----------------------------------------------------------------------------------
local die_old = die or nullFunction
local setDying = setDying or nullFunction
function die()
	if storage.starPounds.pred then
		storage.starPounds.pred = nil
		setDying({shouldDie = true})
		entity.setDropPool()
		entity.setDeathSound()
		entity.setDeathParticleBurst()
		status.setResource("health", 0)
		self.deathBehavior = nil
	end
	die_old()
end
