
--
-- Path class - manage and execute an entity path
--

-- misc helper function
local function dir_to_yaw(vec)
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

-- Class definition
Path = {}
Path.__index = Path

setmetatable(Path, {
	__call = function(c, ...)
		return c.new(...)
	end,
})

-- constructor
function Path.new(obj, to)
	local self = setmetatable({}, Path)
	self.object = obj.object
	self.origin = self.object:getpos()
	self.target = to
	self.config = {
		distance = 30,
		jump = 1.0,
		fall = 3.0,
		algorithm = "Dijkstra",
	}
	self.path = {}
	return self
end

-- to help serialization
function Path:save()
	return {
		target = self.target,
		config = self.config
	}
end

function Path:find()
	-- pathing will fail if we're on a ledge. We can fix this by
	-- pathing from the node below instead
	local pos = vector.round(self.origin)
	local onpos = {x = pos.x, y = pos.y - 1, z = pos.z}
	local on = minetest.get_node(onpos)

	if not minetest.registered_nodes[on.name].walkable then
		pos.y = onpos.y
	end

	local config = self.config
	self.path = minetest.find_path(pos, vector.round(self.target), config.distance, config.jump,
			config.fall, config.algorithm)

	if self.path ~= nil then
		for k, v in pairs(self.path) do
			minetest.add_particle({
				pos = v,
				velocity = vector.new(),
				acceleration = vector.new(),
				expirationtime = 3,
				size = 3,
				collisiondetection = false,
				vertical = false,
				texture = "wool_white.png",
				playername = nil
			})
		end
	end

	return self.path ~= nil
end

function Path:step(dtime)
	local curspd = self.object:getvelocity()
	local pos = self.object:getpos()
	-- if jumping, let jump finish before making more adjustments
	if curspd.y <= 0.2 and curspd.y >= 0 then
		local i, v = next(self.path, nil)
		if not i then
			return false
		end
		if vector.distance(pos, v) < 0.3 then
			-- remove one
			--FIXME shouldn't return here
			local j = i
			local i, v = next(self.path, i)
			if not v then
				return false
			end
		end
		-- prune path more?
		local ii, vv = next(self.path, i)
		local iii, vvv = next(self.path, ii)
		if vv and vvv and vvv.y == v.y and vector.distance(vv,v) < 2 then
			-- prune one
			self.path[ii] = nil
		end
		-- done pruning
		minetest.add_particle({
			pos = {x = v.x, y = v.y + 0.2, z = v.z},
			velocity = vector.new(),
			acceleration = vector.new(),
			expirationtime = 1,
			size = 2,
			collisiondetection = false,
			vertical = false,
			texture = "wool_yellow.png",
			playername = nil
		})
		local vo = {x = v.x, y = v.y - 0.5, z = v.z}
		local vec = vector.subtract(vo, pos)
		local len = vector.length(vec)
		local vdif = vec.y
		vec.y = 0
		local dir = vector.normalize(vec)
		local spd = vector.multiply(dir, 2.0)-- vel
		-- don't jump from too far away
		if vdif > 0.1 and len < 1.5 then
			-- jump
			spd = {x = spd.x/10, y = 5, z = spd.z/10}
			self.object:setvelocity(spd)
		elseif vdif < 0 and len <= 1.1 then
			-- drop one path node just to be sure
			self.path[i] = nil
			-- falling down, just let if fall
		else
			spd.y = self.object:getvelocity().y
			-- don't change yaw when jumping
			self.object:setyaw(dir_to_yaw(spd))
			self.object:setvelocity(spd)
		end
	end

	return true
end

function Path:distance()
	if not self.path then
		return 0
	end

	return vector.distance(self.object:getpos(), self.target)
end

function Path:length()
	if not self.path then
		return 0
	end

	return #self.path
end

function Path:get_config()
	return self.config
end

function Path:set_config(conf)
	self.config = conf
end

