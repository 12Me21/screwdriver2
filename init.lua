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
screwdriver2.rotate_simple = function(pos, node, user, _, new_param2)
	if new_param2 > 3 then return false end
end

screwdriver.rotate_simple = screwdriver2.rotate_simple

-- Accuracy problems:
-- 1: eye height does not take the walking animation into account, which moves the camera slightly up and down
-- 2: Converting the pitch/yaw angles into a vector then multiplying it by 20 is probably not the most accurate thing to do
-- 3: General innacuracies from all calculations
local function get_point(placer)
	local placer_pos = placer:get_pos()
	placer_pos.y = placer_pos.y + placer:get_properties().eye_height
	local raycast = minetest.raycast(placer_pos, vector.add(placer_pos, vector.multiply(placer:get_look_dir(), 20)), false)
	local pointed = raycast:next()
	if pointed and pointed.type == "node" then
		return pointed.intersection_normal,
		       vector.subtract(pointed.intersection_point,pointed.under),
		       pointed.box_id -- 2 tabs + 7 spaces
	end
end

-- Don't worry about this
local insanity_2 = {
	["xy"] =  1, --xyz
	["yz"] =  1,
	["zx"] =  1,
	["zy"] = -1, --zyx
	["yx"] = -1,
	["xz"] = -1,
}
-- Functions to choose rotation based on pointed location
local function push_edge(normal, point)
	local best = 0
	local biggest_axis
	local normal_axis
	for axis in pairs(point) do
		if normal[axis] ~= 0 then
			point[axis] = 0
			normal_axis = axis
		elseif math.abs(point[axis])>best then
			best = math.abs(point[axis])
			biggest_axis = axis
		end
	end
	if normal_axis and biggest_axis then
		for axis in pairs(point) do
			if axis ~= normal_axis and axis ~= biggest_axis then
				return axis, insanity_2[normal_axis..biggest_axis] * math.sign(normal[normal_axis] * point[biggest_axis])
			end
		end
	end
	return "y", 0
end
local function rotate_face(normal, point)
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

local function use_screwdriver(itemstack, user, pointed_thing, right)
	if pointed_thing.type ~= "node" then return end
	local pos = pointed_thing.under
	-- Check protection
	local player_name = user:get_player_name()
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
	--if def.on_rotate == nil and def.can_dig and not def.can_dig(vector.new(pos), user) then return end
	
	-- Choose rotation function based on paramtype2 (facedir/wallmounted)
	local rotate_function = rotate[def.paramtype2]
	if rotate_function then
		-- Right-click = rotate face
		if right then
			node.param2 = rotate_function(node.param2, rotate_face(get_point(user)))
		-- Left-click = push edge away
		else
			node.param2 = rotate_function(node.param2, push_edge(get_point(user)))
		end
	else
		return
	end
	--Todo: maybe support paramtype2 = "degrotate"?
	
	-- The on_rotate system is not very good...
	-- Passing the rotation mode to on_rotate was a mistake
	-- Mods expect ROTATE_AXIS or ROTATE_FACE, and may not work properly with custom rotation modes
	-- Checking the rotation mode is unsafe and a bad idea.
	-- If you want to disallow certain rotation states, please just
	-- check new_param2.
	-- Here I have hardcoded the mode to ROTATE_AXIS
	local handled
	if type(def.on_rotate) == "function" then
		local result = def.on_rotate(vector.new(pos), table.copy(node), user, screwdriver.ROTATE_AXIS, node.param2)
		if result == false then return end
		if result == true then handled = true end
	end
	
	-- Replace node
	if not handled then minetest.swap_node(pos, node) end -- node.param2 has been changed
	if def.after_rotate then def.after_rotate(pos) end
	
	-- Apply wear if not in creative mode
	if not(creative and creative.is_enabled_for(player_name)) then
		itemstack:add_wear(65535 / 200)
		return itemstack
	end
end

minetest.register_craftitem("screwdriver2:screwdriver",{
	description = "Screwdriver", -- Improve
	inventory_image = "screwdriver2.png",
	on_use = function(itemstack, user, pointed_thing)
		return use_screwdriver(itemstack, user, pointed_thing, false)
	end,
	on_place = function(itemstack, user, pointed_thing)
		return use_screwdriver(itemstack, user, pointed_thing, true)
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