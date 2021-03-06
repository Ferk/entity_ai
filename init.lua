--[[

Copyright (c) 2016 - Auke Kok <sofar@foo-projects.org>

* entity_ai is licensed as follows:
- All code is: GNU Affero General Public License, Version 3.0 (AGPL-3.0)
- All artwork is: CC-BY-ND-4.0

A Contributor License Agreement exists, please read:
- https://github.com/sofar/entity_ai/readme.md.

--]]

--[[
General API design ideas:
	-- spawning a new entity
	obj = Entity({name = "sheep", state = {}})

	-- drivers
	self.driver:switch(self, driver)
	self.driver:step()
	self.driver:start()
	self.driver:stop()

- entity programming should use object:method() design.
- creating an entity should use simple methods as follows:

minetest.register_entity("sofar:sheep", {
	...,
	on_activate = entity_ai:on_activate,
	on_step = entity_ai:on_step,
	on_punch = entity_ai:on_punch,
	on_rightclick = entity_ai:on_rightclick,
	get_staticdata = entity_ai:get_staticdata,
})

entity activity is a structure organized as a graph:

events may cause:
  -> [flee]
  -> [defend]
  -> [dead]
  -> [return]
initial states
[roam]
[guard]
[hunt]

etc..

Each state may have several substates

[idle] -> { idle.1, idle.2, idle.3 }

Each state has a "driver". This is the algorithm that makes the entity do
stuff. "do stuff" can mean "stand still", "move to a pos", "attack something" or
a combination of any of these, including "use a node", "place a node" etc.

-- returns: nil
obj:driver_eat_grass = function(self) end
obj:driver_idle = function(self) end
obj:driver_find_food = function(self) end
obj:driver_defend = ...
obj:driver_death = ...
obj:driver_mate = ...

Each state has several "factors". These are conditions that may be met at any
point in time. Factors can be "A node is nearby that can be grazed on", "close to water",
"fertile", "was hit recently", "took damage recently", "a hostile faction is nearby"

-- returns: bool
obj:factor_is_fertile = function(self) end
obj:factor_is_near_foodnode = function(self) end
obj:factor_was_hit = function(self) end
obj:factor_is_near_mate = ...

--]]

--
-- misc functions
--

-- misc helper functions

function dir_to_yaw(vec)
	if vec.z < 0 then
		return math.pi - math.atan(vec.x / vec.z)
	elseif vec.z > 0 then
		return -math.atan(vec.x / vec.z)
	elseif vec.x < 0 then
		return math.pi
	else
		return 0
	end
end

function yaw_to_dir(yaw)
	local y = yaw + (math.pi / 2)
	return {x = math.cos(y), y = 0, z = math.sin(y)}
end

function vector.sort(v1, v2)
	return {x = math.min(v1.x, v2.x), y = math.min(v1.y, v2.y), z = math.min(v1.z, v2.z)},
		{x = math.max(v1.x, v2.x), y = math.max(v1.y, v2.y), z = math.max(v1.z, v2.z)}
end

function check_trapped_and_escape(self)
	local pos = vector.round(self.object:getpos())
	local node = minetest.get_node(pos)
	if minetest.registered_nodes[node.name].walkable then
		-- stuck, can we go up?
		local p2 = {x = pos.x, y = pos.y + 1, z = pos.z}
		local n2 = minetest.get_node(p2)
		if not minetest.registered_nodes[n2.name].walkable then
			--print("monster trapped, escaped upward!")
			self.object:setpos({x = pos.x, y = p2.y + 0.5, z = pos.z})
		else
			print("monster trapped but can't escape upward!", minetest.pos_to_string(pos))
		end
	end
end

--
-- globals
--
entity_ai = {}

entity_ai.registered_drivers = {}
function entity_ai.register_driver(name, def)
	entity_ai.registered_drivers[name] = def
end

entity_ai.registered_factors = {}
function entity_ai.register_factor(name, func)
	entity_ai.registered_factors[name] = func
end

entity_ai.registered_finders = {}
function entity_ai.register_finder(name, func)
	entity_ai.registered_finders[name] = func
end


--
-- includes
--
local modpath = minetest.get_modpath(minetest.get_current_modname())

dofile(modpath .. "/path.lua")
dofile(modpath .. "/driver.lua")


--
-- Animation functions
--

local function animation_select(self, animation, segment)
	local state = self.entity_ai_state
	state.animation = animation
	--print(self.name .. ": driver = " .. self.driver.name .. ", animation = " .. animation .. ", segment = " .. (segment or 0))
	if not segment then
		local animations = self.script.animations[animation]
		if not animations then
			print(self.name .. ": no animations for " .. animation .. ", segment = " .. (segment or 0))
			return
		end
		for i = 1, 3 do
			local animdef = animations[i]
			if animdef then
				state.segment = i
				-- calculate when to advance to next segment
				if not animdef.frame_loop then
					local animlen = (animdef[1].y - animdef[1].x) / animdef.frame_speed
					state.animttl = animlen
				else
					state.animttl = nil
				end
				self.object:set_animation(animdef[1], animdef.frame_speed, animdef.frame_loop)
				return
			end
		end
	else
		local animdef = self.script.animations[animation][segment]
		if animdef then
			state.segment = segment
			self.object:set_animation(animdef[1], animdef.frame_speed, animdef.frame_loop)
			return
		end
	end
	print("animation_select: can't find animation " .. state.animation .. " for driver " .. state.driver .. " for entity " .. self.name)
end

local function animation_loop(self, dtime)
	local state = self.entity_ai_state

	if state.animttl then
		state.animttl = state.animttl - dtime
		if state.animttl <= 0 then
			state.animttl = nil
			state.factors.anim_end = true
			animation_select(self, state.animation, state.segment + 1)
		end
	end
end

local function consider_factors(self, dtime)
	local state = self.entity_ai_state

	for factor, factordriver in pairs(self.script[self.driver.name].factors) do
		-- do we have a test we need to run?
		if entity_ai.registered_factors[factor] then
			entity_ai.registered_factors[factor](self, dtime)
		end
		-- check results
		if state.factors[factor] then
			print("factor " .. factor .. " affects " ..  self.name .. " driver changed to " .. factordriver)
			state.driver = factordriver
			self.driver:switch(factordriver)
		end
	end
end

entity_ai.register_finder("find_habitat", function(self)
	local pos = self.object:getpos()
	local minp, maxp = vector.sort({
		x = math.random(pos.x - 10, pos.x + 10),
		y = pos.y - 5,
		z = math.random(pos.z - 10, pos.z + 10)
		}, {
		x = math.random(pos.x - 10, pos.x + 10),
		y = pos.y + 5,
		z = math.random(pos.z - 10, pos.z + 10)
		})
	minp, maxp = vector.sort(minp, maxp)
	local nodes = minetest.find_nodes_in_area_under_air(minp, maxp, self.driver:get_property("habitatnodes"))
	if #nodes == 0 then
		return nil
	end

	local pick = nodes[math.random(1, #nodes)]
	-- find top walkable node
	while true do
		local node = minetest.get_node(pick)
		if not minetest.registered_nodes[node.name].walkable then
			pick.y = pick.y - 1
		else
			-- one up at the end
			pick.y = pick.y + 1
			break
		end
	end
	-- move to the top surface of pick
	if not pick then
		return nil
	end

--[[		minetest.add_particle({
		pos = {x = pick.x, y = pick.y - 0.1, z = pick.z},
		velocity = vector.new(),
		acceleration = vector.new(),
		expirationtime = 3,
		size = 6,
		collisiondetection = false,
		vertical = false,
		texture = "wool_red.png",
		playername = nil
	})
--]]
	return pick
end)


entity_ai.register_driver("roam", {
	start = function(self)
		-- start with idle animation unless we get a path
		animation_select(self, "idle")
		local state = self.entity_ai_state
		state.roam_ttl = math.random(3, 9)

		self.path = Path(self)
		if not self.path:find() then
			--print("Unable to calculate path")
			self.driver:switch("idle")
			return
		end

		-- done, roaming mode good!
		animation_select(self, "move")
	end,
	step = function(self, dtime)
		-- handle movement stuff
		local state = self.entity_ai_state
		if state.roam_ttl > 0 then
			state.roam_ttl = state.roam_ttl - dtime
			-- do path movement
			if not self.path or
					self.path:distance() < 0.7 or
					not self.path:step(dtime) then
				self.driver:switch("idle")
				return
			end
		else
			self.driver:switch("idle")
		end
	end,
	stop = function(self)
		local state = self.entity_ai_state
		state.roam_ttl = nil
	end,
})

entity_ai.register_driver("idle", {
	start = function(self)
		animation_select(self, "idle")
		self.object:setvelocity(vector.new())
		local state = self.entity_ai_state
		state.idle_ttl = math.random(2, 20)
		-- sanity checks
		check_trapped_and_escape(self)
		local pos = vector.round(self.object:getpos())
		local node = minetest.get_node(pos)
		if minetest.registered_nodes[node.name].walkable then
			-- stuck, can we go up?
			local p2 = {x = pos.x, y = pos.y + 1, z = pos.z}
			local n2 = minetest.get_node(pos)
			if not minetest.registered_nodes[n2.name].walkable then
			end
		end
	end,
	step = function(self, dtime)
		local state = self.entity_ai_state
		state.idle_ttl = state.idle_ttl - dtime
		if state.idle_ttl <= 0 then
			self.driver:switch("roam")
		end
	end,
	stop = function(self)
		local state = self.entity_ai_state
		state.idle_ttl = nil
	end,
})

entity_ai.register_driver("startle", {
	start = function(self)
		-- startle animation
		animation_select(self, "startle")
		self.object:setvelocity(vector.new())
		-- collect info we want to use in this driver
		local state = self.entity_ai_state
		if state.factors.got_hit then
			state.attacker = state.factors.got_hit[1]
			state.attacked_at = state.factors.got_hit[5]
		end
		-- clear factors
		state.factors.got_hit = nil
		state.factors.anim_end = nil
	end,
	step = function(self, dtime)
	end,
	stop = function(self)
		-- play out remaining animations
	end,
})

entity_ai.register_driver("eat", {
	start = function(self)
		animation_select(self, "eat")
		self.object:setvelocity(vector.new())
		-- collect info we want to use in this driver
		local state = self.entity_ai_state
		state.eat_ttl = math.random(30, 60)
	end,
	step = function(self, dtime)
		local state = self.entity_ai_state
		if state.eat_ttl > 0 then
			state.eat_ttl = state.eat_ttl - dtime
			return
		end
		state.factors.ate_enough = math.random(200, 00)
		self.driver:switch("eat_end")
	end,
	stop = function(self)
		local state = self.entity_ai_state
		state.eat_ttl = nil
		-- increase HP
		local hp = self.object:get_hp()
		if hp < self.driver:get_property("hp_max") then
			self.object:set_hp(hp + 1)
		end

		-- eat foodnode
		local food = state.factors.near_foodnode
		if not food then
			return
		end
		-- FIXME can probably be removed.
		if type(food) == "number" then
			return
		end
		local node = minetest.get_node(food)
		minetest.sound_play(minetest.registered_nodes[node.name].sounds.dug, {pos = food, max_hear_distance = 18})
		if node.name == "default:dirt_with_grass" or node.name == "default:dirt_with_dry_grass" then
			minetest.set_node(food, {name = "default:dirt"})
		--elseif node.name == "default:grass_1" or node.name == "default:dry_grass_1" then
		--	minetest.remove_node(food)
		elseif node.name == "default:grass_2" then
			minetest.set_node(food, {name = "default:grass_1"})
		elseif node.name == "default:grass_3" then
			minetest.set_node(food, {name = "default:grass_2"})
		elseif node.name == "default:grass_4" then
			minetest.set_node(food, {name = "default:grass_3"})
		elseif node.name == "default:grass_5" then
			minetest.set_node(food, {name = "default:grass_4"})
		elseif node.name == "default:dry_grass_2" then
			minetest.set_node(food, {name = "default:dry_grass_1"})
		elseif node.name == "default:dry_grass_3" then
			minetest.set_node(food, {name = "default:dry_grass_2"})
		elseif node.name == "default:dry_grass_4" then
			minetest.set_node(food, {name = "default:dry_grass_3"})
		elseif node.name == "default:dry_grass_5" then
			minetest.set_node(food, {name = "default:dry_grass_4"})
		end

		state.factors.near_foodnode = nil
	end,
})

entity_ai.register_driver("eat_end", {
	start = function(self)
		animation_select(self, "eat")
		self.object:setvelocity(vector.new())
	end,
	step = function(self, dtime)
	end,
	stop = function(self)
	end,
})

entity_ai.register_finder("flee_attacker", function(self)
	local state = self.entity_ai_state
	local from = state.attacked_at
	if state.attacker and state.attacker ~= "" then
		local player = minetest.get_player_by_name(state.attacker)
		if player then
			from = player:getpos()
		end
	end
	if not from then
		from = self.object:getpos()
		state.attacked_at = from
	end

	from = vector.round(from)

	local pos = self.object:getpos()
	local dir = vector.subtract(pos, from)
	dir = vector.normalize(dir)
	dir = vector.multiply(dir, 10)
	local to = vector.add(pos, dir)

	local nodes = minetest.find_nodes_in_area_under_air(
			vector.subtract(to, 4),
			vector.add(to, 4),
			{"group:crumbly", "group:cracky", "group:stone"})

	if #nodes == 0 then
		-- failed to get a target, just run away from attacker?!
		print("No target found, stopped")
		return
	end

	-- find top walkable node
	local pick = nodes[math.random(1, #nodes)]
	while true do
		local node = minetest.get_node(pick)
		if not minetest.registered_nodes[node.name].walkable then
			pick.y = pick.y - 1
		else
			-- one up at the end
			pick.y = pick.y + 1
			break
		end
	end

	-- move to the top surface of pick
	if not pick then
		return false
	end
--[[
	minetest.add_particle({
		pos = {x = pick.x, y = pick.y - 0.1, z = pick.z},
		velocity = vector.new(),
		acceleration = vector.new(),
		expirationtime = 3,
		size = 6,
		collisiondetection = false,
		vertical = false,
		texture = "wool_red.png",
		playername = nil
	})
--]]
	return pick
end)

entity_ai.register_driver("flee", {
	start = function(self)
		animation_select(self, "move")
		local state = self.entity_ai_state
		state.flee_start = minetest.get_us_time()
		state.factors.fleed_too_long = nil
	end,
	step = function(self, dtime)
		-- check timer ourselves
		local state = self.entity_ai_state
		if (minetest.get_us_time() - state.flee_start) > (15 * 1000000) then
			state.factors.got_hit = nil
			state.factors.fleed_too_long = true
		end

		-- are we fleeing yet?
		if self.path and self.path.distance then
			-- stop fleeing if we're at a safe distance
			-- execute flee path
			if self.path:distance() < 2.0 then
				-- get a new flee path
				self.path = {}
			else
				-- follow path
				if not self.path:step() then
					self.path = {}
				end
			end
		else
			self.path = Path(self)
			if not self.path:find() then
				--print("Unable to calculate path")
				return
			end

			-- done, flee path good!
			animation_select(self, "move")
		end
	end,
	stop = function(self)
		-- play out remaining animations
	end,
})

entity_ai.register_driver("death", {
	start = function(self)
		-- start with moving animation
		animation_select(self, "idle")
	end,
	step = function(self, dtime)
	end,
	stop = function(self)
		-- play out remaining animations
	end,
})

entity_ai.register_factor("near_foodnode", function(self, dtime)
	local state = self.entity_ai_state
	if state.factors.ate_enough and state.factors.ate_enough > 0 then
		state.factors.ate_enough = state.factors.ate_enough - dtime
		return
	else
		state.factors.ate_enough = nil
	end
	if self.near_foodnode_ttl and self.near_foodnode_ttl > 0 then
		self.near_foodnode_ttl = self.near_foodnode_ttl - dtime
		return
	end
	-- don't check too often
	self.near_foodnode_ttl = 2.0
	local pos = vector.round(self.object:getpos())
	local yaw = self.object:getyaw()
	self.yaw = yaw
	local offset = yaw_to_dir(yaw)
	local maxp = vector.add(pos, offset)
	local minp = vector.subtract(maxp, {x = 0, y = 1, z = 0 })
	local nodes = minetest.find_nodes_in_area(minp, maxp, self.driver:get_property("foodnodes"))

	if #nodes == 0 then
		return
	end

--[[	minetest.add_particle({
		pos = maxp,
		velocity = vector.new(),
		acceleration = vector.new(),
		expirationtime = 3,
		size = 6,
		collisiondetection = false,
		vertical = false,
		texture = "wool_pink.png",
		playername = nil
	})
--]]

	-- store grass node in our factor result - take topmost in list
	state.factors.near_foodnode = nodes[#nodes]
end)


local function entity_ai_on_activate(self, staticdata)
	self.entity_ai_state = {
		factors = {}
	}
	local driver = ""

	if staticdata ~= "" then
		-- load staticdata
		self.entity_ai_state = minetest.deserialize(staticdata)
		if not self.entity_ai_state then
			self.object:remove()
			return
		end

		local state = self.entity_ai_state

		-- driver class, has to come before path
		if state.driver_save then
			driver = state.driver_save
			state.driver_save = nil
		else
			driver = self.script.driver
		end
		self.driver = Driver(self, driver)

		-- path class
		if self.script[driver].finders then
			if state.path_save then
				self.path = Path(self, state.path_save.target)
				self.path:set_config(state.path_save.config)
				self.path:find()
				state.path_save = {}
			end
		end

		--print("loaded: " .. self.name .. ", driver=" .. driver )
	else
		-- set initial monster driver
		driver = self.script.driver
		self.driver = Driver(self, driver)
		--print("activate: " .. self.name .. ", driver=" .. driver)
	end

	-- properties
	self.object:set_hp(self.driver:get_property("hp_max"))

	-- gravity
	self.object:setacceleration({x = 0, y = -9.81, z = 0})

	-- init driver
	self.driver:start()
end

local function entity_ai_on_step(self, dtime)
	animation_loop(self, dtime)
	consider_factors(self, dtime)
	self.driver:step(dtime)
end

local function entity_ai_on_punch(self, puncher, time_from_last_punch, tool_capabilities, dir)
	local state = self.entity_ai_state
	state.factors["got_hit"] = {puncher:get_player_name(), time_from_last_punch, tool_capabilities, dir, self.object:getpos()}
	-- sounds?
	minetest.sound_play("on_punch", {object = self.object})
	-- hp dmg
	if self.object:get_hp() == 0 then
		--FIXME
		print("death")
		self.driver:switch("death")
	end
end

local function entity_ai_on_rightclick(self, clicker)
end

local function entity_ai_get_staticdata(self)
	--print("saved: " .. self.name)
	local state = self.entity_ai_state
	state.driver_save = self.driver.name
	if self.path and self.path.save then
		state.path_save = self.path:save()
	end
	return minetest.serialize(state)
end


function entity_ai.register_entity(name, def)
	-- FIXME add some sort of entity registration table
	-- FIXME handle spawning and reloading?
	def.name = name
	def.physical = def.physical or true
	def.visual = def.visual or "mesh"
	def.makes_footstep_sound = def.makes_footstep_sound or true
	def.stepheight = def.stepheight or 0.55
	def.collisionbox = def.collisionbox or {-1/2, -1/2, -1/2, 1/2, 1/2, 1/2}
	-- entity_ai callbacks
	def.on_activate = entity_ai_on_activate
	def.on_step = entity_ai_on_step
	def.on_punch = entity_ai_on_punch
	def.on_rightclick = entity_ai_on_rightclick
	def.get_staticdata = entity_ai_get_staticdata

	minetest.register_entity(name, def)
end

-- load entities
dofile(modpath .. "/sheep.lua")
dofile(modpath .. "/stone_giant.lua")


-- misc.
minetest.register_on_joinplayer(function(player)
	minetest.add_entity({x=31.0,y=2.0,z=96.0}, "entity_ai:stone_giant")
end)
