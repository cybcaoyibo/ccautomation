--a routing system for computercraft automation with openperipherals
--depend on request.lua and json.lua

--Author: cybcaoyibo
--2014/1

--task = {id, dmg, qty, dir}
--dijkstra_info = {dist, marked, [prev] = {"name", "dir"}}

local interval = 10;
local redclock_out = "left"
local redclock_in = "front"

local machines = {
	router_1 = {
		peri = "container_dropper_1",
		type = "router",
		outputs = {{"west", "saw_supplier_1", 1}}
	}
}

print("base.lua by cybcaoyibo")

local logistics = (loadfile "request.lua")()
local json = (loadfile "json.lua")()

--print peripheral methods(for debugging)
local args = {...};
if(args[1] ~= nil and args[1] == "p") then
	for i, j in pairs(peripheral.wrap(args[2])) do print(i) end
	return
end
if(args[1] ~= nil and args[1] == "i") then
	for i, j in pairs(peripheral.wrap(args[2]).getAllStacks()) do
		if(j ~= nil) then
			print(i .. "," .. j.id .. "(" .. j.rawName .. ")" .. "," .. j.dmg .. "," .. j.qty);
		end
	end
	return
end

local global_state

function load_state()
	if not fs.exists("base.dat") then
		if fs.exists("base.old") then
			fs.move("base.tmp", "base.dat")
		else
			return false
		end
	end
	local fp = io.open("base.dat", "r")
	local data = fp:read("*a")
	fp:close()
	local root = json.decode(data)
	global_state = root.global
	for k, v in pairs(root.machines) do
		machines[k].state = v
	end
	return true
end

function save_state()
	local root = {machines = {}}
	for k, v in pairs(machines) do
		root.machines[k] = v.state
	end
	root.global = global_state
	local data = json.encode(root)
	local fp_tmp = io.open("base.tmp", "w")
	fp_tmp:write(data)
	fp_tmp:close()
	if(fs.exists("base.dat")) then
		if(fs.exists("base.old")) then
			fs.delete("base.old")
		end
		fs.move("base.dat", "base.old")
	end
	fs.move("base.tmp", "base.dat")
end

--load state or start a new state
if((args[1] ~= nil and args[1] == "new") or not load_state()) then
	global_state = {}
	for k, v in pairs(machines) do
		v.state = {};
		if(v.type == "router") then
			v.state.tasks = {};
		elseif(v.type == "dummy") then
		else
			error("unknown machine type: " .. k);
		end
	end
	save_state()
end

local function dijkstra(name)
	local info = {};
	local pending = {};
	local function add_to_pending(nam)
		local pos = nil;
		for i = 1, #pending do
			if(info[pending[i]].dist >= info[nam].dist) then
				pos = i;
				break;
			end
		end
		if(pos == nil) then
			table.insert(pending, nam);
		else
			table.insert(pending, pos, nam);
		end
	end
	local function remove_from_pending(nam)
		for i = 1, #pending do
			if(pending[i] == nam) then
				table.remove(pending, i);
				break;
			end
		end
	end
	info[name] = {};
	info[name].dist = 0;
	info[name].marked = true;
	if machines[name].outputs ~= nil then
		for k, v in pairs(machines[name].outputs) do
			if(info[v[2]] == nil) then
				info[v[2]] = {};
				info[v[2]].dist = v[3];
				info[v[2]].marked = false;
				info[v[2]].prev = {name, v[1]};
				add_to_pending(v[2]);
			else --multiple path between two machines
				if(info[v[2]].dist > v[3]) then
					info[v[2]].dist = v[3];
					info[v[2]].prev = {name, v[1]};
					remove_from_pending(v[2]);
					add_to_pending(v[2]);
				end
			end
		end
	end
	while #pending > 0 do
		local now = pending[1];
		remove_from_pending(now);
		info[now].marked = true;
		if machines[now].outputs ~= nil then
			for k, v in pairs(machines[now].outputs) do
				if(info[v[2]] == nil) then
					info[v[2]] = {};
					info[v[2]].dist = info[now].dist + v[3];
					info[v[2]].marked = false;
					info[v[2]].prev = {now, v[1]};
					add_to_pending(v[2]);
				elseif(not info[v[2]].marked) then
					if(info[v[2]].dist > info[now].dist + v[3]) then
						info[v[2]].dist = info[now].dist + v[3];
						info[v[2]].prev = {now, v[1]};
						remove_from_pending(v[2]);
						add_to_pending(v[2]);
					end
				end
			end
		end
	end
	for k, v in pairs(info) do
		machines[k].state.dijkstra_info = v;
	end
end

local function inventory_to_bill(inv)
	local bill = {};
	for k, v in pairs(inv) do
		if v ~= nil then
			local found = false;
			for k1, v1 in pairs(bill) do
				if(v1.id == v.id and v1.dmg == v.dmg) then
					v1.qty = v1.qty + v.qty;
					found = true;
				end
			end
			if not found then table.insert(bill, {id = v.id, dmg = v.dmg, qty = v.qty}) end
		end
	end
	return bill;
end

--return: {gotten = "items come in", lost = "items gone out"}
local function compare_state(prev_bill, now_bill)
	local gotten, lost = {}, {};
	for k, v in pairs(prev_bill) do
		local found = false
		for k1, v1 in pairs(now_bill) do
			if(v.id == v1.id and v.dmg == v1.dmg) then
				found = true
				if(v.qty > v1.qty) then
					table.insert(lost, {id = v.id, dmg = v.dmg, qty = v.qty - v1.qty});
				elseif(v.qty < v1.qty) then
					table.insert(gotten, {id = v.id, dmg = v.dmg, qty = v1.qty - v.qty});
				end
				break
			end
		end
		if not found then table.insert(lost, {id = v.id, dmg = v.dmg, qty = v.qty}); end
	end
	for k, v in pairs(now_bill) do
		local found = false
		for k1, v1 in pairs(prev_bill) do
			if(v.id == v1.id and v.dmg == v1.dmg) then
				found = true
				break
			end
		end
		if not found then  table.insert(gotten, {id = v.id, dmg = v.dmg, qty = v.qty}); end
	end
	return {gotten = gotten, lost = lost}
end

local function route_item(from, to, id, dmg, qty)
	dijkstra(from)
	local now_prev = to
	while now_prev ~= from do
		local prev = machines[now_prev].state.dijkstra_info.prev
		table.insert(machines[prev[1]].state.tasks, {id = id, dmg = dmg, qty = qty, dir = prev[2]})
		now_prev = prev[1]
	end
end

function from_identifier(identifier)
	local pos = string.find(identifier, ":")
	local id = string.sub(identifier, 1, pos - 1)
	local dmg = string.sub(identifier, pos + 1)
	return tonumber(id), tonumber(dmg)
end

function to_identifier(id, dmg)
	return id .. ":" .. dmg
end

local logistics_tmp
local provider_cache

local function logistics_begin()
	logistics_tmp = {}
	--TODO: build provider_cache
end

local function logistics_end()
	for k, v in pairs(logistics_tmp) do logistics.logistics_action(v) end
end

logistics.logistics_get_table = function(crafter)
	if logistics_tmp[crafter] == nil then logistics_tmp[crafter] = {} end
	return logistics_tmp[crafter]
end

logistics.logistics_deliver = function(from, to, identifier, qty)
	local pos = string.find(from, ":")
	if pos ~= nil then from = string.sub(from, 1, pos - 1) end
	local id, dmg = from_identifier(identifier)
	if from == "TODO" then
		--TODO: take items from storage
		print("take " .. identifier .. "x" .. qty .. " from inventory to " .. to)
		route_item("TODO", to, id, dmg, qty)
	else
		print("send " .. identifier .. "x" .. qty .. " from " .. from .. " to " .. to)
		route_item(from, to, id, dmg, qty)
	end
end

logistics.logistics_store = function(from, identifier, qty)
	logistics.logistics_deliver(from, "TODO", identifier, qty)
end

logistics.logistics_get_providers = function(destination_crafter, requirement_identifier)
	local qty = 0
	for k, v in pairs(provider_cache) do
		if v.identifier == requirement_identifier then
			qty = qty + v.qty
		end
	end
	if qty > 0 then return {{crafter = "TODO", qty = qty}}
	else return {} end
end

logistics.logistics_allow_nested = function(machine)
	return true
end

logistics.logistics_get_crafters = function(result_identifier)
	local rst = {}
	--TODO
	return rst
end

logistics.logistics_get_crafter_to_do = function(crafter)
	--TODO
end

local function fast_request(items, to)
	logistics_begin()
	local root = logistics.new_request_tree({identifier = "", qty = 0}, to, nil, logistics.default_request_flags)
	local ok = true
	for k1, v1 in pairs(items) do
		local node = logistics.new_request_tree({identifier = to_identifier(v1.id, v1.dmg), qty = v1.qty}, to, root, logistics.default_request_flags)
		if not node:is_done() then ok = false end
	end
	if ok then
		root:full_fill_all()
		if v.pending == nil then v.pending = {} end
		print(to .. " fast request ok")
	else
		print(to .. " fast request failed")
		local missing = root:log_failed_request_tree()
		for k, v in pairs(missing) do
			print("missing " .. k .. " x " .. v)
		end
	end
	logistics_end()
end

--on_timer
local function on_timer()
	print("tick: " .. os.time())
	for k, v in pairs(machines) do
		local p = peripheral.wrap(v.peri);
		if(v.type == "router") then
			for task_id, task in pairs(v.state.tasks) do
				print(k .. " job: " .. task.id .. ":" .. task.dmg .. "x" .. task.qty .. " to " .. task.dir)
			end
			local need_process = true;
			while need_process do
				need_process = false;
				local items = p.getAllStacks();
				for slot_id, slot_item in pairs(items) do
					local found = false
					for task_id, task in pairs(v.state.tasks) do
						if task.id == slot_item.id and task.dmg == slot_item.dmg then
							found = true
							local pos = string.find(task.dir, ":")
							local transferred
							if pos == nil then
								function try_push()
									return p.pushItem(task.dir, slot_id, task.qty)
								end
								local no_err
								no_err, transferred = pcall(try_push)
								if not no_err or transferred == -1 then
									transferred = p.pushItemIntoSlot(task.dir, slot_id, task.qty, 1);
								end
							else
								local new_dir = string.sub(task.dir, 1, pos - 1)
								local new_slot = tonumber(string.sub(task.dir, pos + 1))
								transferred = p.pushItemIntoSlot(new_dir, slot_id, task.qty, new_slot);
							end
							if(transferred > 0) then
								task.qty = task.qty - transferred;
								if(task.qty < 0) then print(k .. ": qty < 0")
								elseif(task.qty == 0) then table.remove(v.state.tasks, task_id) end
								need_process = true;
								break;
							end
						end
						if(need_process) then break end;
					end
					if not found then print(k .. ": got unexpected item: " .. slot_item.id) end
					if(need_process) then break end
				end
			end --while need_process
		end
	end
	save_state()
	print("tick end")
end

rs.setOutput(redclock_out, false)
local rs_prev = true
os.queueEvent("redstone")
while(true) do
	local evt, arg1, arg2, arg3 = os.pullEvent();
	if(evt == "char" and string.lower(arg1) == "t") then
		break
	elseif(evt == "redstone") then
		local rs_now = rs.getInput(redclock_in)
		if rs_now then
			if not rs_prev then on_timer(); end
			rs.setOutput(redclock_out, false)
		else
			rs.setOutput(redclock_out, true)
		end
		rs_prev = rs_now
	end
end

