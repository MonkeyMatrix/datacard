local S = minetest.get_translator("datacard")

local function determine_size(obj)
	local objtype = type(obj)
	if objtype == "function" or objtype == "userdata" then
		return 1e100
	elseif objtype == "nil" then
		return 1
	elseif objtype == "table" then
		local size = 2 -- Table init with 2 size elem
		for x,y in pairs(obj) do
			size = size + 1 -- every key-value pair: 1 size elem
			size = size + determine_size(x) + determine_size(y)
		end
		return size
	end
	return #(tostring(obj))
end

local cards = {
	{"mk1",S("Datacard Mk1"),200},
	{"mk2",S("Datacard Mk2"),400},
	{"mk3",S("Datacard Mk3"),800},
}
for _,y in pairs(cards) do
	minetest.register_craftitem("datacard:datacard_" .. y[1],{
		description = y[2],
		inventory_image = "datacard_" .. y[1] .. ".png",
		groups = { datacard_capacity = y[3] },
		on_drop = function() end,
		stack_max = 1,
	})
end

local function store_data(itemstack,data)
	local name = itemstack:get_name()
	local datasize = determine_size(data)
	local capacity = minetest.get_item_group(name, "datacard_capacity")
	local item_description = minetest.registered_items[name] and minetest.registered_items[name].description or "Unknown Datacard"

	if datasize > capacity then
		return false, "TOO_BIG"
	end

	local serialized_data = minetest.serialize(data)
	if data then -- check
		local check_data = minetest.deserialize(serialized_data)
		if not check_data then
			return false, "ERR_SERIALIZE"
		end
	end

	local meta = itemstack:get_meta()
	meta:set_string("data",serialized_data)
	meta:set_int("size",datasize)
	meta:set_string("description",S("@1 (@2/@3 Datablock used)",item_description,datasize,capacity))
	return true, itemstack
end

local function read_data(itemstack)
	local meta = itemstack:get_meta()
	local serialized_data = meta:get_string("data")
	if serialized_data == "" then
		return nil
	end
	return minetest.deserialize(serialized_data,true)
end

local function get_size(itemstack)
	local name = itemstack:get_name()
	local meta = itemstack:get_meta()
	local datasize = meta:get_int("size")
	local capacity = minetest.get_item_group(name, "datacard_capacity")
	return datasize, capacity
end

-- Diskdrive
local function on_construct(pos)
	local meta = minetest.get_meta(pos)
	local inv = meta:get_inventory()
	inv:set_size("disk",1)
	meta:set_string("formspec","field[channel;Channel;${channel}]")
	meta:set_string("infotext",S("Empty Datacard Diskdrive"))
end
local function on_punch(pos, node, puncher, pointed_thing)
	local meta = minetest.get_meta(pos)
	local channel = meta:get_string("channel")
	local inv = meta:get_inventory()
	local stack = puncher:get_wielded_item()
	local puncher_inv = puncher:get_inventory()
	local itemname = stack:get_name()

	local orig_in_drive = inv:get_stack("disk",1)
	if orig_in_drive:get_count() ~= 0 and puncher_inv:room_for_item("main",orig_in_drive) then
		puncher_inv:add_item("main",orig_in_drive)
		inv:set_stack("disk",1,"")
		if channel ~= "" then
			digilines.receptor_send(pos, digilines.rules.default, channel, {
				response_type = "eject",
			})
		end
		minetest.swap_node(pos,{name="datacard:diskdrive_empty"})
		meta:set_string("infotext",S("Empty Datacard Diskdrive"))
	end

	if orig_in_drive:get_count() == 0 and minetest.get_item_group(itemname, "datacard_capacity") ~= 0 then
		local disk = stack:take_item(1)
		puncher:set_wielded_item(stack)
		inv:set_stack("disk",1,disk)
		if channel ~= "" then
			digilines.receptor_send(pos, digilines.rules.default, channel, {
				response_type = "inject",
			})
		end
		minetest.swap_node(pos,{name="datacard:diskdrive_working"})
		meta:set_string("infotext",S("Working Datacard Diskdrive"))
	end
end
local function on_receive_fields(pos, _, fields, sender)
	local name = sender:get_player_name()
	if minetest.is_protected(pos, name) and not minetest.check_player_privs(name, {protection_bypass=true}) then
		minetest.record_protection_violation(pos, name)
		return
	end
	if (fields.channel) then
		minetest.get_meta(pos):set_string("channel", fields.channel)
	end
end
local function on_digiline_receive(pos, _, channel, msg)
	local meta = minetest.get_meta(pos)
	local inv = meta:get_inventory()
	local setchan = meta:get_string("channel")
	if setchan ~= channel then return end

	if type(msg) ~= "table" then return end
	local msgtype = string.lower(msg.type or "")
	if msgtype == "read" then
		local disk = inv:get_stack("disk",1)
		if disk:get_count() ~= 0 then
			local data = read_data(disk)
			local used, capacity = get_size(disk)
			digilines.receptor_send(pos, digilines.rules.default, channel, {
				response_type = msg.type,
				status = true,
				data = data,
				used = used,
				capacity = capacity
			})
		else
			digilines.receptor_send(pos, digilines.rules.default, channel, {
				response_type = msg.type,
				success = false,
				error = "NO_DISK"
			})
		end
	elseif msgtype == "write" then
		local disk = inv:get_stack("disk",1)
		if disk:get_count() ~= 0 then
			local status, stack = store_data(disk,msg.data)
			if status then
				inv:set_stack("disk",1,stack)
				local used, capacity = get_size(stack)
				digilines.receptor_send(pos, digilines.rules.default, channel, {
					response_type = msg.type,
					success = true,
					used = used,
					capacity = capacity
				})
			else
				digilines.receptor_send(pos, digilines.rules.default, channel, {
					response_type = msg.type,
					success = false,
					error = stack
				})
			end
		else
			digilines.receptor_send(pos, digilines.rules.default, channel, {
				response_type = msg.type,
				success = false,
				error = "NO_DISK"
			})
		end
	else
		digilines.receptor_send(pos, digilines.rules.default, channel, {
			response_type = msg.type,
			success = false,
			error = "UNKNOWN_CMD"
		})
	end
end
local function can_dig(pos,player)
	local meta = minetest.get_meta(pos)
	local inv = meta:get_inventory()
	return inv:is_empty("disk")
end
local function on_place(itemstack, placer, pointed_thing)
	return minetest.rotate_and_place(itemstack, placer, pointed_thing, false, "force_floor")
end


minetest.register_node("datacard:diskdrive_empty",{
	description = S("Datacard Diskdrive"),
	tiles = { -- +Y, -Y, +X, -X, +Z, -Z
		"device_terminal_top.png","device_terminal_top.png",
		"device_computer_side.png","device_computer_side.png",
		"device_computer_side.png","device_diskdrive_front_on_1.png"
	},
	on_construct = on_construct,
	on_punch = on_punch,
	on_receive_fields = on_receive_fields,
	digilines = {
		receptor = {},
		effector = {
			action = on_digiline_receive
		},
	},
	groups = {cracky = 1, level = 2},
	sounds = default.node_sound_metal_defaults(),
	can_dig = can_dig,
	on_place = on_place,
	paramtype2 = "facedir",
})

minetest.register_node("datacard:diskdrive_working",{
	description = S("Datacard Diskdrive") .. " (You Hacker You!)",
	tiles = { -- +Y, -Y, +X, -X, +Z, -Z
		"device_terminal_top.png","device_terminal_top.png",
		"device_computer_side.png","device_computer_side.png",
		"device_computer_side.png","device_diskdrive_front_on_2.png"
	},
	on_construct = on_construct,
	on_punch = on_punch,
	on_receive_fields = on_receive_fields,
	digilines = {
		receptor = {},
		effector = {
			action = on_digiline_receive
		},
	},
	groups = {cracky = 1, level = 2, not_in_creative_inventory = 1 },
	drop = "datacard:diskdrive_empty",
	sounds = default.node_sound_metal_defaults(),
	can_dig = can_dig,
	on_place = on_place,
	paramtype2 = "facedir",
})

-- Crafting
if minetest.get_modpath("technic") then
	minetest.register_craft({
		recipe = {
			{"default:tin_ingot","","default:tin_ingot"},
			{"default:tin_ingot","technic:control_logic_unit","default:tin_ingot"},
			{"default:tin_ingot","digilines:wire_std_00000000","default:tin_ingot"},
		},
		output = "datacard:datacard_mk1"
	})
	minetest.register_craft({
		type = "shapeless",
		recipe = {"datacard:datacard_mk1","datacard:datacard_mk1"},
		output = "datacard:datacard_mk2"
	})
	minetest.register_craft({
		type = "shapeless",
		recipe = {"datacard:datacard_mk2","datacard:datacard_mk2"},
		output = "datacard:datacard_mk3"
	})
	minetest.register_craft({
		type = "shapeless",
		recipe = {"datacard:datacard_mk1","datacard:datacard_mk1","datacard:datacard_mk1","datacard:datacard_mk1"},
		output = "datacard:datacard_mk3"
	})

	for _,y in ipairs({"mesecons_luacontroller:luacontroller0000","mesecons_microcontroller:microcontroller0000"}) do
		if minetest.registered_nodes[y] then
			local groups = table.copy(minetest.registered_nodes[y].groups or {})
			groups.datacard_craft_controller = 1
			minetest.override_item(y,{groups=groups})
		end
	end

	minetest.register_craft({
		recipe = {
			{"default:tin_ingot","","default:tin_ingot"},
			{"default:tin_ingot","group:datacard_craft_controller","default:tin_ingot"},
			{"default:tin_ingot","digilines:wire_std_00000000","default:tin_ingot"},
		},
		output = "datacard:diskdrive_empty"
	})
end
