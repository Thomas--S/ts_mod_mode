local priv = minetest.settings:get("ts_mod_mode.priv") or "ban"
if priv == "" then priv = "ban" end

-- Unfortunately, bags and armor don't work yet as they use a more complicated method.
local lists_to_swap = {"main", "craft"}

local default_elevated_privs = "teleport,bring,noclip,fly,fast,basic_privs"
local elevated_privs_string = minetest.settings:get("ts_mod_mode.elevated_privs") or default_elevated_privs
if elevated_privs_string == "" then elevated_privs_string = default_elevated_privs end
local elevated_privs = minetest.string_to_privs(elevated_privs_string)

local discord_webhook = minetest.settings:get("ts_mod_mode.discord_webhook") or nil
if discord_webhook == "" then discord_webhook = nil end

if minetest.global_exists("ts_skins") then
	lists_to_swap[#lists_to_swap+1] = "ts_skins_clothing"
end

local mod_storage = minetest.get_mod_storage()
local http = minetest.request_http_api()

local hud_ids = {}

local function send_discord_message(message)
	if http and discord_webhook then
		http.fetch({
			method = "POST",
			url = discord_webhook,
			extra_headers = {"Content-Type: application/json"},
			timeout = 5,
			data = minetest.write_json({
				content = message,
			}),
		}, function() end)
	end
end

local function serialize_list(list)
	local itemstring_table = {}
	for idx, stack in pairs(list) do
		itemstring_table[idx] = stack:to_string()
	end
	return minetest.serialize(itemstring_table)
end

local function deserialize_list(serialized_data)
	local itemstring_table = minetest.deserialize(serialized_data) or {}
	local stack_table = {}
	for idx, itemstring in pairs(itemstring_table) do
		stack_table[idx] = ItemStack(itemstring)
	end
	return stack_table
end

local function push_list_to_mod_storage(playername, listname, list)
	mod_storage:set_string(playername.."#"..listname, serialize_list(list))
end

local function pop_list_from_mod_storage(playername, listname)
	local list = deserialize_list(mod_storage:get_string(playername.."#"..listname)) or {}
	mod_storage:set_string(playername.."#"..listname, "")
	return list
end

local function swap_list(playername, listname, inv)
	local stored_list = pop_list_from_mod_storage(playername, listname)
	local list_to_store = inv:get_list(listname)
	push_list_to_mod_storage(playername, listname, list_to_store)
	inv:set_list(listname, stored_list)
end

local function swap_lists(playername, inv)
	for _,listname in ipairs(lists_to_swap) do
		swap_list(playername, listname, inv)
	end
	ts_skins.update_skin(playername)
	armor:update_skin(playername)
end

local function enter_moderation_mode(name)
	local player = minetest.get_player_by_name(name)
	if not player then
		return
	end
	local meta = player:get_meta()
	if not meta then
		return
	end
	if meta:get_string("ts_mod_mode") == "on" then
		minetest.chat_send_player(name, minetest.colorize("#f80", "Moderation mode already enabled."))
		return
	end
	local inv = player:get_inventory()
	if not inv then
		return
	end
	meta:set_string("ts_mod_mode", "on")
	hud_ids[name] = player:hud_add({
		hud_elem_type = "text",
		position = {x=0, y=.6},
		offset = {x=10, y=-10},
		name = "",
		alignment = {x=1,y=0},
		scale = {x = 100, y = 100},
		text = 'MODERATION MODE ENABLED.\nUse "/mod_off" to access your private inventory again.',
		number = 0xff8800,
	})
	swap_lists(name, inv)
	minetest.log("action", name.." entered the moderation mode.")
	minetest.chat_send_player(name, minetest.colorize("#f80", "Moderation mode entered.").." Your privs: "..
			minetest.privs_to_string(minetest.get_player_privs(name), ", ")..'. If necessary, use "/elevate_privs" to get more privs.')
end

local function leave_moderation_mode(name)
	local player = minetest.get_player_by_name(name)
	if not player then
		return
	end
	local meta = player:get_meta()
	if not meta then
		return
	end
	if meta:get_string("ts_mod_mode") ~= "on" then
		return
	end
	local inv = player:get_inventory()
	if not inv then
		return
	end
	if hud_ids[name] then
		player:hud_remove(hud_ids[name])
	end
	hud_ids[name] = nil
	swap_lists(name, inv)
	local player_privs = table.copy(minetest.get_player_privs(name))
	for elevated_priv,_ in pairs(elevated_privs) do
		player_privs[elevated_priv] = nil
	end
	minetest.set_player_privs(name, player_privs)
	minetest.log("action", name.." left the moderation mode.")
	if meta:get_string("ts_mod_mode_elevated_privs") == "on" then
		send_discord_message(name.." left the moderation mode and thus lost their elevated privs.")
	end
	meta:set_string("ts_mod_mode_elevated_privs", "")
	meta:set_string("ts_mod_mode", "")
	minetest.chat_send_player(name, minetest.colorize("#f80", "Moderation mode left.").." Your privs: "..
			minetest.privs_to_string(minetest.get_player_privs(name), ", "))
end

local function elevate_privs(name, reason)
	local player = minetest.get_player_by_name(name)
	if not player then
		return
	end
	local meta = player:get_meta()
	if not meta then
		return
	end
	if meta:get_string("ts_mod_mode") ~= "on" then
		minetest.chat_send_player(name, minetest.colorize("#f80", "You can only elevate your privs in moderation mode."))
		return
	end
	if not reason or reason:trim() == "" then
		minetest.chat_send_player(name, minetest.colorize("#f80", "You must submit a reason in order to elevate your privs."))
		return
	end
	meta:set_string("ts_mod_mode_elevated_privs", "on")
	local message = name.." elevated their privs. Reason: "..reason
	minetest.log("action", message)
	send_discord_message(message)
	local player_privs = table.copy(minetest.get_player_privs(name))
	for elevated_priv,_ in pairs(elevated_privs) do
		player_privs[elevated_priv] = true
	end
	minetest.set_player_privs(name, player_privs)
	minetest.chat_send_player(name, minetest.colorize("#f80", "Privileges successfully elevated.").." Your privs: "..
		minetest.privs_to_string(minetest.get_player_privs(name), ", "))
end

minetest.register_chatcommand("mod_on", {
	description = "Enter moderation mode.",
	privs = {[priv] = true},
	func = function(name)
		enter_moderation_mode(name)
	end
})

minetest.register_chatcommand("mod_off", {
	description = "Leave moderation mode.",
	privs = {[priv] = true},
	func = function(name)
		leave_moderation_mode(name)
	end
})

minetest.register_chatcommand("elevate_privs", {
	description = "Grant yourself more privileges for moderation.",
	params = "<Reason>",
	privs = {[priv] = true},
	func = function(name, param)
		elevate_privs(name, param)
	end
})

minetest.register_on_joinplayer(function(player)
	if player then
		local name = player:get_player_name()
		if name then
			leave_moderation_mode(name)
		end
	end
end)

minetest.register_on_leaveplayer(function(player)
	if player then
		local name = player:get_player_name()
		if name then
			leave_moderation_mode(name)
		end
	end
end)