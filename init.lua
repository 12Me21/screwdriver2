if not minetest.raycast then
	minetest.log("error", "screwdriver2 requires minetest version 5.0 or newer")
	return
end

local function disp(...)
	for _, x in ipairs({...}) do
		minetest.chat_send_all(dump(x))
	end
end

screwdriver2 = {}

-- Some mods may rely on screwdiver.ROTATE_FACE/ROTATE_AXIS existing in their
-- on_rotate functions, not expecting on_rotate to be called if screwdriver
-- is not installed.
if not screwdriver then
	screwdriver = {
		ROTATE_FACE = 1,
		ROTATE_AXIS = 2,
	}
end
-- Override old rotate_simple function with a safer/better one
-- Should have the same result in all normal cases
function screwdriver2.rotate_simple(_, _, _, _, new_param2)
	if new_param2 > 3 then return false end
end
screwdriver.rotate_simple = screwdriver2.rotate_simple

local view_bobbing_distance = (minetest.settings:get("view_bobbing_amount") or 1) * -0.05

-- Get the start and end points for the raycaster
local function get_look_dir(player)
	local placer_pos = player:get_pos()
	placer_pos.y = placer_pos.y + player:get_properties().eye_height
	return placer_pos, vector.multiply(player:get_look_dir(), 20)
end

-- Get the point the player is looking at
local function get_point(player, pointed_thing)
	local pos, look_dir = get_look_dir(player)
	local pos2 = pos
	-- Because of the view bobbing animation, the player's eye position can vary slightly
	-- This isn't too bad most of the time, but it can result in the raycaster finding the wrong node/face
	-- if you are pointing close to the edge of a surface.
	-- To avoid this, we check to make sure the ray collidied with the correct node face.
	-- and if not, try again at a lower point.
	-- I'm not exactly sure how much the camera moves but -0.05 seems to be just past the maximum
	-- I've been able to break this, but only by jumping around and clicking randomly...
	for i = 0, view_bobbing_distance, view_bobbing_distance / 10 do
		local raycast = minetest.raycast(pos2, vector.add(pos2, look_dir), false)
		local pointed = raycast:next()
		if
			pointed and pointed.type == "node" and -- Ray collided with node
			vector.equals(pointed.under, pointed_thing.under) and -- position is correct
			vector.equals(pointed.above, pointed_thing.above)
		then
			return pointed.intersection_normal,
				   vector.subtract(pointed.intersection_point, pointed.under),
				   pointed.box_id -- 2 tabs + 7 spaces
		end
		pos2 = vector.add(pos, {x=0, y=i, z=0})
	end
	minetest.log("warning",
		"Screwdriver could not find pointed node at "..
		minetest.pos_to_string(pointed_thing.under)..
		" using the raycaster." -- Even though I tried really hard...
	)
	return {x=0, y=0, z=0}, {x=0, y=0, z=0}, 1
end

-- Functions to choose rotation based on pointed location
local insanity_2 = {xy = 1, yz = 1, zx = 1; zy = -1, yx = -1, xz = -1} -- Don't worry about this
local function push_edge(normal, point)
	local biggest = 0
	local biggest_axis
	local normal_axis
	-- Find the normal axis, and the axis of the with the
	-- greatest magnitude (other than the normal axis)
	for axis in pairs(point) do
		if normal[axis] ~= 0 then
			normal_axis = axis
		elseif math.abs(point[axis])>biggest then
			biggest = math.abs(point[axis])
			biggest_axis = axis
		end
	end
	-- Find the third axis, which is the one to rotate around
	if normal_axis and biggest_axis then
		for axis in pairs(point) do
			if axis ~= normal_axis and axis ~= biggest_axis then
				-- Decide which direction to rotate (+ or -)
				return axis, insanity_2[normal_axis..biggest_axis] * math.sign(normal[normal_axis] * point[biggest_axis])
			end
		end
	end
	return "y", 0
end
local function rotate_face(normal, _)
	-- Find the normal axis
	for axis, value in pairs(normal) do
		if value ~= 0 then
			return axis, math.sign(value)
		end
	end
	return "y", 0
end

-- Numbers taken from https://forum.minetest.net/viewtopic.php?p=73195&sid=1d2d2e4e76ce2ef9c84646481a4b84bc#p73195
-- "How to rotate (clockwise) by axis from any facedir:"
-- "(this will be made into a lua function)"
-- 5 years later...
local facedir_cycles = {
	x = {{12,13,14,15},{16,19,18,17},{ 0, 4,22, 8},{ 1, 5,23, 9},{ 2, 6,20,10},{ 3, 7,21,11}},
	y = {{ 0, 1, 2, 3},{20,23,22,21},{ 4,13,10,19},{ 8,17, 6,15},{12, 9,18, 7},{16, 5,14,11}},
	z = {{ 4, 5, 6, 7},{ 8,11,10, 9},{ 0,16,20,12},{ 1,17,21,13},{ 2,18,22,14},{ 3,19,23,15}},
}
local wallmounted_cycles = {
	x = {0, 4, 1, 5},
	y = {4, 2, 5, 3},
	z = {0, 3, 1, 2},
}
-- Functions to rotate a facedir/wallmounted value around an axis by a certain amount
local rotate = {
	-- Facedir: lower 5 bits used for direction, 0 - 23
	facedir = function(param2, axis, amount)
		local facedir = param2 % 32
		for _, cycle in ipairs(facedir_cycles[axis]) do
			for i, fd in ipairs(cycle) do
				if fd == facedir then
					return param2 - facedir + cycle[1+(i-1 + amount) % 4]
				end
			end
		end
		return param2
	end,
	-- Wallmounted: lower 3 bits used, 0 - 5
	wallmounted = function(param2, axis, amount)
		local wallmounted = param2 % 8
		for i, wm in ipairs(wallmounted_cycles[axis]) do
			if wm == wallmounted then
				return param2 - wallmounted + wallmounted_cycles[axis][1+(i-1 + amount) % 4]
			end
		end
		return param2
	end
}
rotate.colorfacedir = rotate.facedir
rotate.colorwallmounted = rotate.wallmounted
--Todo: maybe support degrotate?

local function rect(angle, radius)
	return math.cos(2*math.pi * angle) * radius, math.sin(2*math.pi * angle) * radius
end

-- Generate the screwdriver particle effects
local other_axes = {x = {"y","z"}, y = {"z","x"}, z = {"x","y"}}
local function particle_ring(pos, axis, direction)
	local axis2, axis3 = unpack(other_axes[axis])
	local particle_pos = vector.new()
	local particle_vel = vector.new()
	for i = 0, 0.999, 1/6 do
		particle_pos[axis3], particle_pos[axis2] = rect(i, 0.5^0.5)
		particle_vel[axis3], particle_vel[axis2] = rect(i - 1/4 * direction, 2)
		
		minetest.add_particle({
			pos = vector.add(pos, particle_pos),
			velocity = particle_vel,
			acceleration = vector.multiply(particle_pos, -7),
			expirationtime = 0.25,
			size = 2,
			texture = "screwdriver2.png",
		})
	end
end

-- Main
function screwdriver.use(itemstack, player, pointed_thing, is_right_click)
	if pointed_thing.type ~= "node" then return end
	local pos = pointed_thing.under
	
	-- Check protection
	local player_name = player:get_player_name()
	if minetest.is_protected(pos, player_name) then
		minetest.record_protection_violation(pos, player_name)
		return
	end
	
	-- Get node info
	local node = minetest.get_node_or_nil(pos)
	if not node then return end
	local def = minetest.registered_nodes[node.name]
	if not def then return end -- probably unnessesary
	
	if def.on_rotate == false then return end
	--if def.on_rotate == nil and def.can_dig and not def.can_dig(vector.new(pos), player) then return end
	
	-- Choose rotation function based on paramtype2 (facedir/wallmounted)
	local rotate_function = rotate[def.paramtype2]
	if not rotate_function then return end
	
	-- Choose rotation axis/direction and param2 based on click type and pointed location
	local axis, amount
	local normal, point = get_point(player, pointed_thing)
	if vector.length(normal) == 0 then return end
	
	local control = player:get_player_control()
	if is_right_click then
		axis, amount = rotate_face(normal, point)
		-- This line intentionally left blank.
	else
		axis, amount = push_edge(normal, point)
		if control.sneak then amount = -amount end
	end
	local new_param2 = rotate_function(node.param2, axis, amount)
	
	-- Calculate particle position
	local particle_offset = vector.new()
	particle_offset[axis] = point[axis]--math.sign(normal[axis]) * 0.5
	
	-- Handle node's on_rotate function
	local handled
	if type(def.on_rotate) == "function" then
		local result = def.on_rotate(
			vector.new(pos),
			table.copy(node),
			player,
			is_right_click and 2 or 1,
			new_param2
		)
		if result == false then
			return
		elseif result == true then
			handled = true
		end
	end
	
	-- Draw particles (Todo: check if rotation was actually done)
	particle_ring(vector.add(pos, particle_offset), axis, amount)
	
	-- Replace node
	if not handled then
		node.param2 = new_param2
		minetest.swap_node(pos, node)
	end
	minetest.check_for_falling(pos)
	if def.after_rotate then def.after_rotate(pos) end
	
	-- Apply wear if not in creative mode
	if not(creative and creative.is_enabled_for(player_name)) then
		itemstack:add_wear(65535 / 200)
		return itemstack
	end
end

minetest.register_tool("screwdriver2:screwdriver",{
	description = "Screwdriver (left click = push edge, right click = rotate face)",
	_doc_items_longdesc = "A tool for rotating nodes. Designed to be easier to use than the standard screwdriver.",
	_doc_items_usagehelp = [[
Left clicking a node will "push" its nearest edge away from you. (Hold sneak to reverse the direction.)
Right click rotates the node clockwise around the face you are pointing at.]],
	_doc_items_hidden = false,
	inventory_image = "screwdriver2.png",
	on_use = function(itemstack, player, pointed_thing)
		return screwdriver.use(itemstack, player, pointed_thing, false)
	end,
	on_place = function(itemstack, player, pointed_thing)
		return screwdriver.use(itemstack, player, pointed_thing, true)
	end,
})

-- Override screwdriver:screwdriver recipe:
minetest.clear_craft({
	recipe = {
		{"default:steel_ingot"},
		{"group:stick"},
	},
})
minetest.register_craft({
	output = "screwdriver2:screwdriver",
	recipe = {
		{"default:steel_ingot"},
		{"group:stick"},
	},
})

-- Just in case someone needs the old screwdriver, define a recipe to craft it.
if minetest.get_modpath("screwdriver") then
	minetest.register_craft({
		output = "screwdriver:screwdriver",
		type = "shapeless",
		recipe = {"screwdriver2:screwdriver"},
	})
	minetest.register_craft({
		output = "screwdriver2:screwdriver",
		type = "shapeless",
		recipe = {"screwdriver:screwdriver"},
	})
end