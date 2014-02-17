--This is a reimplement of LogisticsPipes's RequestTree in lua by cybcaoyibo
--You can use this with ComputerCraft to build a logistics system
--To include this file:
--local logistics = (loadfile "request.lua")()

--need to implement:

--function logistics_get_table(crafter)
--return a table associated to the crafter(used to store internal data)

--function logistics_get_providers(destination_crafter, requirement_identifier)
--return: {{crafter, qty}}
--sorted by distance, asc

--function logistics_get_crafters(result_identifier)
--return: {crafting_template}
--(you can add userdata in crafting_template for futher use

--function logistics_allow_nested(machine)
--return: boolean

--function logistics_get_crafter_to_do(machine)
--return: number_of_tasks_pending_of_the_machine

--function logistics_deliver(from, to, identifier, qty)
--this function will be called when calling logistics_action

--function logistics_store(from, identifier, qty)
--this function will be called when calling logistics_action

--[optional]: fuzzy crafting
--{
	--function logistics_test_subtitute(template, requirement_index, other_identifier)
	--test whether other_identifier can supplant the requirement(used for oredict crafting)

	--function logistics_has_subtitute(template, requirement_index)
	--test whether the requirement has subtitutes
	
	--function logistics_get_all_providers(destination_crafter)
	--return: {identifier}
	
	--function logistics_get_all_crafters(destination_crafter)
	--return: {identifier}
--}


--before request: create a empty table for logistics_get_table


--request single item:
--new_request_tree, full_fill

--request multiple item:
--new_request_tree, {new_request_tree as childs, ...}, full_fill

--for failed tree, call recurse_failed_request_tree
--to get items missing, call send_missing_message
--to get items used, call send_used_message

--after request: call logistics_action(tab) //tab = the table returned from logistics_get_table

local logistics = {}

local max_int = 4294967295

local function new_logistics_promise()
	local new = {}
	new.stk = {identifier = "", qty = 0}
	new.sender = nil
	new.type = "logistics_promise"
	new.is_craft_result = false
	new.copy = function(self)
		local new = new_logistics_promise()
		new.stk = {identifier = self.stk.identifier, qty = self.stk.qty}
		new.sender = self.sender
		return new
	end
	return new
end

local function new_logistics_extra_promise()
	local new = new_logistics_promise()
	new.provided = false --currently useless, muse be false
	new.type = "logistics_extra_promise"
	new.copy = function(self)
		local new = new_logistics_extra_promise()
		new.stk = {identifier = self.stk.identifier, qty = self.stk.qty}
		new.sender = self.sender
		new.provided = self.provided
		return new
	end
	return new
end

local function new_crafting_template(result, crafter, priority, machine)
	local new = {}
	new._machine = machine
	new._result = result --{identifier, qty}
	new._crafter = crafter
	new._priority = priority
	new._required = {} --{{identifier, qty, crafter}}
	new._byproduct = {} --{{identifier, qty}}
	new.add_requirement = function(self, stk, crafter)
		for k, v in pairs(self._required) do
			if v.identifier == stk.identifier and v.crafter == crafter then
				v.qty = v.qty + stk.qty
				return
			end
		end
		table.insert(self._required, {identifier = stk.identifier, qty = stk.qty, crafter = crafter})
	end
	new.add_byproduct = function(self, stk)
		for k, v in pairs(self._byproduct) do
			if v.identifier == stk.identifier then
				v.qty = v.qty + stk.qty
				return
			end
		end
		table.insert(self._byproduct, {identifier = stk.identifier, qty = stk.qty})
	end
	new.generate_promise = function(self, count)
		local promise = new_logistics_promise()
		promise.stk.identifier = self._result.identifier
		promise.stk.qty = self._result.qty * count
		promise.sender = self._crafter
		promise.is_craft_result = true
		return promise
	end
	new.get_crafter = function(self) return self._crafter end
	new.get_priority = function(self) return self._priority end
	new.compare_to = function(self, other)
		local c = self._priority - other._priority
		if c < 0 then return -1 end
		if c > 0 then return 1 end
		return 0
	end
	new.can_craft = function(self, identifier)
		return self._result.identifier == identifier
	end
	new.get_result_stack_size = function(self)
		return self._result.qty
	end
	new.get_result_item = function(self)
		return {identifier = self._result.identifier}
	end
	new.get_byproduct = function(self)
		return self._byproduct
	end
	new.get_component_items = function(self, count)
		local rst = {}
		for k, v in pairs(self._required) do
			table.insert(rst, {identifier = v.identifier, qty = v.qty * count, crafter = v.crafter})
		end
		return rst
	end
	return new
end

local active_request_type = {
	provide = 1,
	craft = 2
}

local default_request_flags = bit.bor(active_request_type.provide, active_request_type.craft)

local function new_crafting_sorter_node(crafting_template, max_count, request_tree, tree_node)
	local new = {}
	new.stacks_of_work_requested = 0
	new.set_size = crafting_template:get_result_stack_size()
	new.max_work_sets_available = math.floor((tree_node:get_missing_item_count() + new.set_size - 1) / new.set_size)
	new.request_tree_node = tree_node
	new.crafting_template = crafting_template
	new.original_to_do = logistics.logistics_get_crafter_to_do(crafting_template._machine)
	new.tree_node = tree_node
	new.calculate_max_work = function(self, max_sets_to_craft)
		local n_crafting_sets_needed
		if max_sets_to_craft == 0 then
			n_crafting_sets_needed = math.floor((self.tree_node:get_missing_item_count() + self.set_size - 1) / self.set_size)
		else
			n_crafting_sets_needed = max_sets_to_craft
		end
		if n_crafting_sets_needed == 0 then return 0 end
		local stacks = self.tree_node:get_sub_requests(n_crafting_sets_needed, self.crafting_template)
		return stacks
	end
	new.add_to_work_request = function(self, extra_work)
		local stack_requested = math.floor((extra_work + self.set_size - 1) / self.set_size)
		self.stacks_of_work_requested = self.stacks_of_work_requested + stack_requested
		return stack_requested * self.set_size
	end
	new.add_work_promises_to_tree = function(self)
		local sets_to_craft = math.min(self.stacks_of_work_requested, self.max_work_sets_available)
		local sets_able_to_craft = self:calculate_max_work(sets_to_craft)
		if sets_able_to_craft > 0 then
			local job = self.crafting_template:generate_promise(sets_able_to_craft)
			if job.stk.qty ~= sets_able_to_craft * self.set_size then
				error("generate_promise not creating the promises_promised; this is going to end badly.")
			end
			self.tree_node:add_promise(job)
		end
		local is_done = sets_to_craft == sets_able_to_craft
		self.stacks_of_work_requested = 0
		return is_done
	end
	new.current_to_do = function(self)
		return self.original_to_do + self.stacks_of_work_requested * self.set_size
	end
	new.compare_to = function(self, oth)
		local comp = self:current_to_do() - oth:current_to_do()
		if comp > 0 then return 1
		elseif comp < 0 then return -1
		else return 0 end
	end
	return new
end

local function peek_priority_queue(queue)
	k, v = 1, queue[1]
	for i = 1, #queue do
		if queue[i]:compare_to(v) < 0 then
			k, v = i, queue[i]
		end
	end
	return k, v
end

local function get_subtitutes(template, id)
	local avail = logistics.logistics_get_all_providers()
	local craft = logistics.logistics_get_all_crafters()
	local rst = {}
	for k, v in pairs(avail) do
		if logistics.logistics_test_subtitute(template, id, v) then
			rst[v] = 1
		end
	end
	return rst
end

local function new_request_tree_node(template, stk, requester, parent, flags)
	local new = {}
	new.type = "request_tree"
	new.request = stk --{identifier, qty}
	new.target = requester --crafter
	new.template = template
	new.parent = parent
	new.sub_requests = {}
	new.used_crafters = {}
	new.promises = {}
	new.extra_promises = {}
	new.byproducts = {}
	new.last_crafter_tried = nil
	new.promised_item_count = 0
	new.is_crafter_used = function(self, test)
		local found = false
		for k, v in pairs(self.used_crafters) do
			if v == test._machine then
				found = true
				break
			end
		end
		if found == true then return true end
		if self.parent == nil then return false end
		return self.parent:is_crafter_used(test)
	end
	new.declare_crafter_used = function(self, test)
		if self:is_crafter_used(test) then return false end
		table.insert(self.used_crafters, test._machine)
		return true
	end
	new.get_promise_item_count = function(self) return self.promised_item_count end
	new.get_missing_item_count = function(self) return self.request.qty - self.promised_item_count end
	new.add_promise = function(self, promise)
		if promise.stk.identifier ~= self.request.identifier then error("wrong item") end
		if self:get_missing_item_count() == 0 then error("zero count needed, promises not needed.") end
		if promise.stk.qty > self:get_missing_item_count() then
			local more = promise.stk.qty - self:get_missing_item_count() 
			promise.stk.qty = self:get_missing_item_count() 
			local extra = new_logistics_extra_promise()
			extra.stk.identifier = promise.stk.identifier 
			extra.stk.qty = more
			extra.sender = promise.sender
			table.insert(self.extra_promises, extra)
		end
		if promise.stk.qty <= 0 then error("zero count ... again") end
		table.insert(self.promises, promise)
		self.promised_item_count = self.promised_item_count + promise.stk.qty
		self.root:promise_added(promise)
	end
	new.is_done = function(self) return self:get_missing_item_count() <= 0 end
	new.is_all_done = function(self)
		if not self:is_done() then return false end
		for k, v in pairs(self.sub_requests) do
			if not v:is_done() then return false end
		end
		return true
	end
	new.get_stack_item = function(self) return self.request.identifier end
	new.remove = function(self, sub_node)
		for k, v in pairs(self.sub_requests) do
			if v == sub_node then
				table.remove(self.sub_requests, k)
				break
			end
		end
		sub_node:remove_sub_promises()
	end
	new.remove_sub_promises = function(self)
		for k, v in pairs(self.promises) do
			self.root:promise_removed(v)
		end
		for k, v in pairs(self.sub_requests) do
			v:remove_sub_promises()
		end
	end
	new.check_for_extras = function(self, identifier, extra_map)
		for k, v in pairs(self.extra_promises) do
			if v.stk.identifier == identifier then
				local extras = extra_map[v.sender]
				if extras == nil then
					extras = {}
					extra_map[v.sender] = extras
				end
				table.insert(extras, v:copy())
			end
		end
		for k, v in pairs(self.sub_requests) do
			v:check_for_extras(identifier, extra_map)
		end
	end
	new.remove_used_extras = function(self, identifier, extra_map)
		for k, v in pairs(self.promises) do
			if v.stk.identifier == identifier then
				if v.type == "logistics_extra_promise" then
					if not v.provided then
						local used_count = v.stk.qty
						local extras = extra_map[v.sender]
						if extras ~= nil then
							local need_process = true
							while need_process do
								need_process = false
								for k1, v1 in pairs(extras) do
									if v1.stk.qty > used_count then
										v1.stk.qty = v1.stk.qty - used_count
										used_count = 0
										break
									else
										used_count = used_count - v1.stk.qty
										table.remove(extras, k1)
										need_process = true
										break
									end
								end
							end
						end
					end
				end
			end
		end
		for k, v in pairs(self.sub_requests) do
			v:remove_used_extras(identifier, extra_map)
		end
	end
	new.full_fill = function(self)
		for k, v in pairs(self.sub_requests) do
			v:full_fill()
		end
		for k, v in pairs(self.promises) do
			local tab = logistics.logistics_get_table(v.sender)
			if tab.promises == nil then tab.promises = {} end
			table.insert(tab.promises, {v, self.target})
		end
		for k, v in pairs(self.extra_promises) do
			local tab = logistics.logistics_get_table(v.sender)
			if tab.extras == nil then tab.extras = {} end
			table.insert(tab.extras, v)
		end
		for k, v in pairs(self.byproducts) do
			local tab = logistics.logistics_get_table(v.sender)
			if tab.extras == nil then tab.extras = {} end
			table.insert(tab.extras, v)
		end
	end
	new.build_missing_map = function(self, missing)
		if self:get_missing_item_count() ~= 0 then
			local identifier = self.request.identifier
			local qty = missing[identifier]
			if qty == nil then qty = 0 end
			qty = qty + self:get_missing_item_count()
			missing[identifier] = qty
		end
		for k, v in pairs(self.sub_requests) do
			v:build_missing_map(missing)
		end
	end
	new.build_used_map = function(self, used, missing)
		local used_count = 0
		for k, v in pairs(self.promises) do
			if not v.is_craft_result then
				used_count = used_count + v.stk.qty
			end
		end
		if used_count ~= 0 then
			local identifier = self.request.identifier
			local count = used[identifier]
			if count == nil then count = 0 end
			count = count + used_count
			used[identifier] = count
		end
		if self:get_missing_item_count() ~= 0 then
			local identifier = self.request.identifier
			local count = missing[identifier]
			if(count == nil) then count = 0 end
			count = count + get_missing_item_count()
			missing[identifier] = count
		end
		for k, v in pairs(self.sub_requests) do
			v:build_used_map(used, missing)
		end
	end
	new.check_provider = function(self)
		local providers = logistics.logistics_get_providers(self.target, self:get_stack_item())
		for k, v in pairs(providers) do
			if self:is_done() then break end
			local already_taken = self.root:get_all_promises_for(v.crafter, self:get_stack_item())
			local can_provide = v.qty - already_taken
			if can_provide > 0 then
				local promise = new_logistics_promise()
				promise.stk.identifier = self:get_stack_item()
				promise.stk.qty = math.min(can_provide, self:get_missing_item_count())
				promise.sender = v.crafter
				self:add_promise(promise)
			end
		end
		return self:is_done()
	end
	new.check_extras = function(self)
		local map = self.root:get_extras_for(self:get_stack_item())
		for k, v in pairs(map) do
			if self:is_done() then break end
			if v.stk.qty > 0 then
				v.stk.qty = math.min(v.stk.qty, self:get_missing_item_count())
				self:add_promise(v)
			end
		end
		return self:is_done()
	end
	new.check_crafting = function(self)
		local all_crafters_for_item = logistics.logistics_get_crafters(self:get_stack_item())
		local iter_all_crafters = 1
		local crafters_same_priority = {}
		local crafters_to_balance = {}
		local done = false
		local last_crafter = nil
		local current_priority = 0
		while not done do
			if iter_all_crafters <= #all_crafters_for_item then
				if last_crafter == nil then
					last_crafter = all_crafters_for_item[iter_all_crafters]
					iter_all_crafters = iter_all_crafters + 1
				end
			elseif last_crafter == nil then
				done = true
			end
			local items_needed = self:get_missing_item_count()
			if last_crafter ~= nil and (#crafters_same_priority == 0 or current_priority == last_crafter:get_priority()) then
				current_priority = last_crafter:get_priority()
				local crafter = last_crafter
				last_crafter = nil
				if (not logistics.logistics_allow_nested(crafter._machine)) and self:is_crafter_used(crafter) then
				elseif not crafter:can_craft(self:get_stack_item()) then
				else
					local cn = new_crafting_sorter_node(crafter, items_needed, self.root, self)
					table.insert(crafters_same_priority, cn)
				end
			elseif #crafters_to_balance == 0 and (crafters_same_priority == nil or #crafters_same_priority == 0) then
			else
				if #crafters_same_priority == 1 then
					table.insert(crafters_to_balance, crafters_same_priority[1])
					crafters_same_priority = {}
					crafters_to_balance[1]:add_to_work_request(items_needed)
				else
					if #crafters_same_priority > 0 then
						local k, v = peek_priority_queue(crafters_same_priority)
						table.remove(crafters_same_priority, k)
						table.insert(crafters_to_balance, v)
					end
					while #crafters_to_balance > 0 and items_needed > 0 do
						while #crafters_same_priority > 0 do
							local k, v = peek_priority_queue(crafters_same_priority)
							if v:current_to_do() > crafters_to_balance[1]:current_to_do() then break end
							table.remove(crafters_same_priority, k)
							table.insert(crafters_to_balance, v)
						end
						local cap
						if #crafters_same_priority > 0 then
							local k, v = peek_priority_queue(crafters_same_priority)
							cap = v:current_to_do()
						else
							cap = max_int
						end
						local floor = crafters_to_balance[1]:current_to_do()
						cap = math.min(cap, math.floor(floor + (items_needed + #crafters_to_balance - 1) / #crafters_to_balance))
						for k, v in pairs(crafters_to_balance) do
							local request = math.min(items_needed, cap - floor)
							if request > 0 then
								local crafting_done = v:add_to_work_request(request)
								items_needed = items_needed - crafting_done
							end
						end
					end
				end
				local to_remove = {}
				for k, v in pairs(crafters_to_balance) do
					if v.stacks_of_work_requested > 0 and not v:add_work_promises_to_tree() then
						table.insert(to_remove, k)
					end
				end
				local j = 0
				for i = 1, #to_remove do
					table.remove(crafters_to_balance, to_remove[i] - j)
					j = j + 1
				end
				items_needed = self:get_missing_item_count()
				if items_needed <= 0 then break end
				if #crafters_to_balance > 0 then done = false end
			end
		end
		return self:is_done()
	end
	new.get_sub_requests = function(self, n_crafting_sets, template)
		local failed = false
		local stacks = template:get_component_items(n_crafting_sets)
		local work_sets_available = n_crafting_sets
		local last_nodes = {}
		for k, v in pairs(stacks) do
			if logistics.logistics_has_subtitute ~= nil and logistics.logistics_has_subtitute(template, k) then
				local subs = get_subtitutes(template, k)
				local req = v.qty
				local grp = {total_promise_item_count = 0, nodes = {}}
				for k1, _ in pairs(subs) do
					if req <= 0 then break end
					local node = new_request_tree_node(template, {identifier = k1, qty = req}, v.crafter, self, default_request_flags)
					node:proc()
					req = req - node:get_promise_item_count()
					grp.total_promise_item_count = grp.total_promise_item_count + node:get_promise_item_count()
					table.insert(grp.nodes, node)
				end
				if req > 0 then failed = true end
			else
				local node = new_request_tree_node(template, v, v.crafter, self, default_request_flags)
				node:proc()
				table.insert(last_nodes, {total_promise_item_count = node:get_promise_item_count(), nodes = {node}})
				if not node:is_done() then
					failed = true
				end
			end
		end
		if failed then
			for k, v in pairs(last_nodes) do
				for k1, v1 in pairs(v.nodes) do
					v1:destroy()
				end
			end
			self.last_crafter_tried = template
			for i = 1, #stacks do
				work_sets_available = math.min(work_sets_available, math.floor(last_nodes[i].total_promise_item_count / math.floor(stacks[i].qty / n_crafting_sets)))
			end
			return self:generate_request_tree_for(work_sets_available, template)
		end
		for k, v in pairs(template:get_byproduct()) do
			local extra = new_logistics_extra_promise()
			extra.stk.identifier = v.identifier
			extra.stk.qty = v.qty * work_sets_available
			extra.sender = template:get_crafter()
			extra.provided = false
			table.insert(self.byproducts, extra)
		end
		return work_sets_available
	end
	new.generate_request_tree_for = function(self, work_sets, template)
		local new_children = {}
		if work_sets > 0 then
			local failed = false
			local stacks = template:get_component_items(work_sets)
			for k, v in pairs(stacks) do
				if logistics.logistics_has_subtitute ~= nil and logistics.logistics_has_subtitute(template, k) then
					local subs = get_subtitutes(template, k)
					local req = v.qty
					for k1, _ in pairs(subs) do
						if req <= 0 then break end
						local node = new_request_tree_node(template, {identifier = k1, qty = req}, v.crafter, self, default_request_flags)
						node:proc()
						req = req - node:get_promise_item_count()
						table.insert(new_children, node)
					end
					if req > 0 then failed = true end
				else
					local node = new_request_tree_node(template, v, v.crafter, self, default_request_flags)
					node:proc()
					table.insert(new_children, {total_promise_item_count = node:get_promise_item_count(), nodes = {node}})
					if not node:is_done() then
						failed = true
					end
				end
			end
			if failed then
				for k, v in pairs(new_children) do
					v:destroy()
				end
				return 0
			end
		end
		for k, v in pairs(template:get_byproduct()) do
			local extra = new_logistics_extra_promise()
			extra.stk.identifier = v.identifier
			extra.stk.qty = v.qty * work_sets
			extra.sender = template:get_crafter()
			extra.provided = false
			table.insert(self.byproducts, extra)
		end
		return work_sets
	end
	new.recurse_failed_request_tree = function(self)
		if self:is_done() then return end
		if self.last_crafter_tried == nil then return end
		local template = self.last_crafter_tried
		local n_crafting_sets_needed = math.floor((self:get_missing_item_count() + template:get_result_stack_size() - 1) / template:get_result_stack_size())
		local stacks = template:get_component_items(n_crafting_sets_needed)
		for k, v in pairs(stacks) do
			new_request_tree_node(template, v, v.crafter, self, default_request_flags):proc()
		end
		self:add_promise(template:generate_promise(n_crafting_sets_needed))
		for k, v in pairs(self.sub_requests) do
			v:recurse_failed_request_tree()
		end
	end
	new.log_failed_request_tree = function(self)
		local missing = {}
		for k, v in pairs(self.sub_requests) do
			if v.type == "request_tree" then
				if not v:is_done() then
					v:recurse_failed_request_tree()
					v:build_missing_map(missing)
				end
			end
		end
		return missing
	end
	new.destroy = function(self)
		self.parent:remove(self)
	end
	
	if parent ~= nil then
		table.insert(parent.sub_requests, new)
		new.root = parent.root
	else
		new.root = new
	end
	if template ~= nil and (not logistics.logistics_allow_nested(template._machine)) then
		new:declare_crafter_used(template)
	end
	new.flags = flags
	new.proc = function(self)
		if bit.band(self.flags, active_request_type.provide) ~= 0 and self:check_provider() then return end
		if bit.band(self.flags, active_request_type.craft) ~= 0 and self:check_extras() then return end
		if bit.band(self.flags, active_request_type.craft) ~= 0 and self:check_crafting() then return end
	end
	return new
end

local function new_request_tree(item, requester, parent, flags)
	local new = new_request_tree_node(nil, item, requester, parent, flags)
	new.type = "request_tree"
	new.get_existsing_promises_for = function(self, key)
		if self._promisetotals == nil then self._promisetotals = {} end
		local n
		for k, v in pairs(self._promisetotals) do
			if v[1] == key[1] and v[2] == key[2] then
				n = v[3]
				break
			end
		end
		if n == nil then return 0 end
		return n
	end
	new.get_all_promises_for = function(self, provider, identifier)
		local key = {provider, identifier}
		return self:get_existsing_promises_for(key)
	end
	new.get_extras_for = function(self, identifier)
		local extra_map = {}
		self:check_for_extras(identifier, extra_map)
		self:remove_used_extras(identifier, extra_map)
		local extras = {}
		for k, v in pairs(extra_map) do
			for k1, v1 in pairs(v) do
				table.insert(extras, v1)
			end
		end
		return extras
	end
	new.full_fill_all = function(self) self:full_fill() end
	new.send_missing_message = function(self)
		local missing = {}
		self:build_missing_map(missing)
		return missing
	end
	new.send_used_message = function(self)
		local used = {}
		local missing = {}
		self:build_used_map(used, missing)
		return {used = used, missing = missing}
	end
	new.promise_added = function(self, promise)
		local key = {promise.sender, promise.stk.identifier}
		local found = nil
		for k, v in pairs(self._promisetotals) do
			if v[1] == key[1] and v[2] == key[2] then
				found = v
				break
			end
		end
		if found == nil then
			found = {promise.sender, promise.stk.identifier, promise.stk.qty}
			table.insert(self._promisetotals, found)
		else
			found[3] = found[3] + promise.stk.qty
		end
	end
	new.promise_removed = function(self, promise)
		local key = {promise.sender, promise.stk.identifier}
		local found = nil
		local found_k
		for k, v in pairs(self._promisetotals) do
			if v[1] == key[1] and v[2] == key[2] then
				found = v
				found_k = k
				break
			end
		end
		if found == nil then error("promise_removed: negative promise(1)") end
		found[3] = found[3] - promise.stk.qty
		if found[3] < 0 then error("promise_removed: negative promise(2)")
		elseif found[3] == 0 then table.remove(self._promisetotals, found_k) end
	end
	new._promisetotals = {}
	new:proc()
	return new
end

local function logistics_action(tab)
	if tab.promises == nil then return end
	for k, v in pairs(tab.promises) do
		if v[1].type == "logistics_extra_promise" then
			local id = v[1].stk.identifier
			local qty = v[1].stk.qty
			for k1, v1 in pairs(tab.extras) do
				if qty == 0 then break end
				if v1.stk.identifier == id then
					local consume = math.min(v1.stk.qty, qty)
					qty = qty - consume
					v1.stk.qty = v1.stk.qty - consume
				end
			end
			if qty > 0 then error("not enough extras for extra_promise") end
			logistics.logistics_deliver(v[1].sender, v[2], v[1].stk.identifier, v[1].stk.qty)
		else
			logistics.logistics_deliver(v[1].sender, v[2], v[1].stk.identifier, v[1].stk.qty)
		end
	end
	if tab.extras == nil then return end
	for k, v in pairs(tab.extras) do
		if v.stk.qty > 0 then
			logistics.logistics_store(v.sender, v.stk.identifier, v.stk.qty)
		end
	end
end

logistics.active_request_type = active_request_type;
logistics.default_request_flags = default_request_flags;
logistics.logistics_action = logistics_action;
logistics.new_request_tree = new_request_tree;
logistics.new_logistics_promise = new_logistics_promise;
logistics.new_crafting_template = new_crafting_template;

return logistics