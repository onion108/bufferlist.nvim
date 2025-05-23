-- TODO: think about using letters instead of numbers when listing buffers
local bufferlist = {}
local api = vim.api
local fn = vim.fn
local km = vim.keymap
local cmd = vim.cmd
local bo = vim.bo
local ns_id = api.nvim_create_namespace("BufferListNamespace")
local _, devicons = pcall(require, "nvim-web-devicons")
local signs = { "Error", "Warn", "Info", "Hint" }
local bufferlist_signs = { " ", " ", " ", " " }
local top_border = { "╭", "─", "╮", "│", "", "", "", "│" }
local bottom_border = { "", "", "", "│", "╯", "─", "╰", "│" }
local default_opts = {
	keymap = {
		close_buf_prefix = "c",
		force_close_buf_prefix = "f",
		save_buf = "s",
		visual_close = "d",
		visual_force_close = "f",
		visual_save = "s",
		multi_close_buf = "m",
		multi_save_buf = "w",
		save_all_unsaved = "a",
		close_all_saved = "d0",
		toggle_path = "p",
		close_bufferlist = "q",
	},
	win_keymaps = {},
	bufs_keymaps = {},
	width = 40,
	icons = {
		line = "▎",
		modified = "󰝥",
		prompt = "",
		save_prompt = "󰆓 ",
	},
	top_prompt = true,
	show_path = false,
}

---@param the_scratch_buf number
---@param description string
---@return table
local function km_opts(the_scratch_buf, description)
	return { buffer = the_scratch_buf, silent = true, desc = "BufferList: " .. description }
end

---@param buffer number
---@return table
local function diagnosis(buffer)
	local count = vim.diagnostic.count(buffer)
	local diagnosis_display = {}
	for k, v in pairs(count) do
		local defined_sign = fn.sign_getdefined("DiagnosticSign" .. signs[k])
		local sign_icon = #defined_sign ~= 0 and defined_sign[1].text or bufferlist_signs[k]
		table.insert(diagnosis_display, { tostring(v) .. sign_icon, "DiagnosticSign" .. signs[k] })
	end
	return diagnosis_display
end

---@param listed_bufs table
---@param index number
---@param force boolean?
---@return nil
local function close_buffer(listed_bufs, index, force)
	local bn = listed_bufs[index]
	if (bo[bn].modified or bo[bn].buftype == "terminal") and force ~= true then
		return nil
	end
	local command = (force and "bd! " or "bd ") .. bn
	cmd(command)
	if fn.bufexists(bn) == 1 and bo[bn].buflisted then
		api.nvim_buf_call(bn, function()
			cmd(command)
		end)
	end
end

---@param listed_bufs table
---@param index number
---@param scratch_buffer number
local function save_buffer(listed_bufs, index, scratch_buffer)
	pcall(api.nvim_buf_call, listed_bufs[index], function()
		cmd("w")
		bo[scratch_buffer].modifiable = true
		api.nvim_buf_set_text(scratch_buffer, index - 1, 0, index - 1, 4, { " " })
		bo[scratch_buffer].modifiable = false
	end)
end

---@param win number
---@param height number
---@param listed_buffers table
---@param scratch_buffer number
---@param save_or_close string
---@param list_buffers_func function
local function float_prompt(win, height, listed_buffers, scratch_buffer, save_or_close, list_buffers_func)
	local prompt_ns = api.nvim_create_namespace("BufferListPromptNamespace")
	local prompt_scratch_buf = api.nvim_create_buf(false, true)
	local line_numbers = {}
	local buf_count = #listed_buffers
	local border, row
	if default_opts.top_prompt then
		border = top_border
		row = -2
	else
		border = bottom_border
		row = height
	end
	local prompt_win = api.nvim_open_win(prompt_scratch_buf, true, {
		relative = "win",
		win = win,
		width = default_opts.width,
		height = 1,
		row = row,
		col = -1,
		border = border,
		noautocmd = true,
		style = "minimal",
	})
	vim.wo[prompt_win].statuscolumn = (save_or_close == "save" and default_opts.icons.save_prompt or "")
		.. default_opts.icons.prompt
	cmd("startinsert")

	api.nvim_create_autocmd("TextChangedI", {
		buffer = prompt_scratch_buf,
		callback = function()
			local line = api.nvim_buf_get_lines(0, 0, -1, true)[1]
			local curpos = fn.charcol(".")
			local highlightgroup = curpos == 2 and string.sub(line, 1, 1) == "!" and "BufferListPromptForce"
				or tonumber(string.sub(line, curpos - 1, curpos - 1)) and "BufferListPromptNumber"
				or "BufferListPromptSeperator"
			api.nvim_buf_add_highlight(
				prompt_scratch_buf,
				prompt_ns,
				highlightgroup,
				0,
				curpos == 1 and 0 or curpos - 2,
				curpos - 1
			)
			local recent_numbers = {}
			for line_nr in string.gmatch(line, "%d+") do
				if tonumber(line_nr) <= buf_count and string.sub(line_nr, 1, 1) ~= "0" then
					if not line_numbers[line_nr] then
						local extid = api.nvim_buf_set_extmark(scratch_buffer, prompt_ns, tonumber(line_nr) - 1, 0, {
							line_hl_group = "BufferListPromptMultiSelected",
						})
						line_numbers[line_nr] = extid
					end
					recent_numbers[line_nr] = true
				end
			end
			for key, value in pairs(line_numbers) do
				if not recent_numbers[key] then
					line_numbers[key] = nil
					api.nvim_buf_del_extmark(scratch_buffer, prompt_ns, value)
				end
			end
		end,
	})

	api.nvim_create_autocmd("InsertLeave", {
		buffer = prompt_scratch_buf,
		callback = function()
			cmd("bwipeout")
			api.nvim_buf_clear_namespace(scratch_buffer, prompt_ns, 0, -1)
		end,
	})

	km.set("i", "<cr>", function()
		for key in pairs(line_numbers) do
			if save_or_close == "save" then
				save_buffer(listed_buffers, tonumber(key), scratch_buffer)
			elseif save_or_close == "close" then
				local force = string.sub(api.nvim_buf_get_lines(0, 0, -1, true)[1], 1, 1) == "!"
				close_buffer(listed_buffers, tonumber(key), force)
			end
		end
		cmd("stopinsert")
		cmd("bwipeout " .. prompt_scratch_buf)
		cmd("bwipeout " .. scratch_buffer)
		list_buffers_func()
	end, { buffer = prompt_scratch_buf })
end

---@param the_relative_paths table
---@param static table
local function toggle_path(the_relative_paths, static)
	local the_scratch_buf, the_current_buf_line, the_current_extid, current_length =
		static[1], static[2], static[3], static[4]
	vim.bo[the_scratch_buf].modifiable = true
	for index, value in ipairs(the_relative_paths) do
		local byteidx = fn.byteidx(api.nvim_buf_get_text(the_scratch_buf, index - 1, 0, index - 1, -1, {})[1], 5)
		if not default_opts.show_path then
			api.nvim_buf_set_text(the_scratch_buf, index - 1, byteidx, index - 1, byteidx, { value .. "/" })
			api.nvim_buf_add_highlight(
				the_scratch_buf,
				ns_id,
				"BufferListPath",
				index - 1,
				byteidx,
				byteidx + 1 + #value
			)
		else
			api.nvim_buf_set_text(the_scratch_buf, index - 1, byteidx, index - 1, byteidx + #value + 1, {})
		end
	end

	if not default_opts.show_path and the_current_extid then
		local byteidx = fn.byteidx(
			api.nvim_buf_get_text(the_scratch_buf, the_current_buf_line - 1, 0, the_current_buf_line - 1, -1, {})[1],
			5
		)
		api.nvim_buf_set_extmark(the_scratch_buf, ns_id, the_current_buf_line - 1, byteidx, {
			id = the_current_extid,
			end_col = current_length + #the_relative_paths[the_current_buf_line] + 1,
			hl_group = "BufferListCurrentBuffer",
		})
	end

	default_opts.show_path = not default_opts.show_path
	vim.bo[the_scratch_buf].modifiable = false
end

---@param fun function
---@param third_arg boolean|integer
---@param the_listed_bufs table
---@param win number
---@param refresh_fn function
local function multi_visual(fun, third_arg, the_listed_bufs, win, refresh_fn)
	local start = fn.line("v", win)
	local theEnd = fn.line(".", win)
	if start > theEnd then
		start, theEnd = theEnd, start
	end
	for i = start, theEnd do
		fun(the_listed_bufs, i, third_arg)
	end
	if refresh_fn ~= nil then
		refresh_fn()
		fn.setcursorcharpos(start, 6)
	end
end

local function list_buffers()
	local b = api.nvim_list_bufs()
	local scratch_buf = api.nvim_create_buf(false, true)
	local current_buf = api.nvim_get_current_buf()
	local bufs_names = {}
	local current_buf_line
	local current_extid
	local icon_colors = {}
	local diagnostics = {}
	local listed_bufs = {}
	local relative_paths = {}
	local line_byteidx = fn.byteidx(default_opts.icons.line, 1)
	local modified_byteidx = fn.byteidx(default_opts.icons.modified, 1)

	local function refresh()
		cmd("bwipeout")
		list_buffers()
	end

	for i = 1, #b do
		if bo[b[i]].buflisted then
			local bufname = vim.fs.basename(fn.bufname(b[i]))
			local icon, color = devicons.get_icon_color(bufname)
			icon = icon or ""
			bufname = bufname == "" and "[No Name]" or bufname
			local line = (bo[b[i]].modified and default_opts.icons.modified or " ")
				.. " "
				.. default_opts.icons.line
				.. icon
				.. " "
				.. bufname
			table.insert(bufs_names, line)
			table.insert(listed_bufs, b[i])
			current_buf_line = b[i] == current_buf and #bufs_names or current_buf_line
			table.insert(icon_colors, color or false)

			local diagnosis_count = diagnosis(b[i])
			if #diagnosis_count > 0 then
				table.insert(diagnostics, #bufs_names, diagnosis_count)
			end

			local len = #bufs_names
			local desc_bufname = " " .. icon .. " " .. bufname

			km.set("n", tostring(len), function()
				cmd("bwipeout | buffer " .. listed_bufs[len])
			end, km_opts(scratch_buf, "switch to buffer:" .. desc_bufname))

			km.set("n", default_opts.keymap.close_buf_prefix .. tostring(len), function()
				close_buffer(listed_bufs, len)
				if not bo[listed_bufs[len]].modified then
					refresh()
				end
			end, km_opts(scratch_buf, "close buffer:" .. desc_bufname))

			km.set("n", default_opts.keymap.force_close_buf_prefix .. tostring(len), function()
				close_buffer(listed_bufs, len, true)
				refresh()
			end, km_opts(scratch_buf, "force close buffer:" .. desc_bufname))

			km.set("n", default_opts.keymap.save_buf .. tostring(len), function()
				save_buffer(listed_bufs, len, scratch_buf)
			end, km_opts(scratch_buf, "save buffer:" .. desc_bufname))

			for index = 1, #default_opts.bufs_keymaps do
				local bkm = vim.deepcopy(default_opts.bufs_keymaps[index], true)
				local keymap_opts = bkm[3]
				keymap_opts.buffer = scratch_buf
				keymap_opts.desc = keymap_opts.desc and keymap_opts.desc .. desc_bufname
					or "BufferList: custom user defined buffers keymap for" .. desc_bufname
				km.set("n", bkm[1] .. tostring(len), function()
					bkm[2]({
						bl_buf = scratch_buf,
						buffers = listed_bufs,
						line_number = len,
						open_bufferlist = list_buffers,
					})
				end, keymap_opts)
			end
		end
	end

	api.nvim_buf_set_lines(scratch_buf, 0, 1, true, bufs_names)

	for i = 1, #bufs_names do
		local byteidx = 2
		if bo[listed_bufs[i]].modified then
			byteidx = modified_byteidx + 1
			api.nvim_buf_add_highlight(scratch_buf, ns_id, "BufferListModifiedIcon", i - 1, 0, byteidx)
		end
		api.nvim_buf_add_highlight(scratch_buf, ns_id, "BufferListLine", i - 1, byteidx, byteidx + line_byteidx)
		if icon_colors[i] then
			local hl_group = "BufferListIcon" .. tostring(i)
			api.nvim_buf_add_highlight(
				scratch_buf,
				ns_id,
				hl_group,
				i - 1,
				byteidx + line_byteidx,
				byteidx + line_byteidx + 4
			)
			cmd("hi " .. hl_group .. " guifg=" .. icon_colors[i])
		end
	end

	if current_buf_line then
		local byteidx = 5 + line_byteidx + (bo[listed_bufs[current_buf_line]].modified and modified_byteidx or 1)
		current_extid = api.nvim_buf_set_extmark(scratch_buf, ns_id, current_buf_line - 1, byteidx, {
			end_col = #bufs_names[current_buf_line],
			hl_group = "BufferListCurrentBuffer",
		})
	end

	local tpso = { scratch_buf, current_buf_line, current_extid, current_extid and #bufs_names[current_buf_line] }

	---@param the_relative_paths table
	local function path_toggle(the_relative_paths)
		default_opts.show_path = false
		vim.schedule(function()
			toggle_path(the_relative_paths, tpso)
		end)
	end

	-- PERF: the previous ugly approch is probably more performant than this.
	vim.schedule(function()
		for i = 1, #bufs_names do
			if fn.executable("realpath") == 1 then
				vim.system(
					{ "realpath", "--relative-to", vim.uv.cwd(), vim.fn.expand("#" .. listed_bufs[i] .. ":p:h") },
					{ text = true },
					function(out)
						local res = string.gsub(out.stdout, "\n", "")
						relative_paths[i] = res
						if i == #bufs_names and default_opts.show_path then
							path_toggle(relative_paths)
						end
					end
				)
			else
				relative_paths[i] = fn.expand("#" .. listed_bufs[i] .. ":~:.:h")
				if i == #bufs_names and default_opts.show_path then
					path_toggle(relative_paths)
				end
			end
		end
	end)

	for k, v in pairs(diagnostics) do
		api.nvim_buf_set_extmark(scratch_buf, ns_id, k - 1, 0, { virt_text = v })
	end

	local height = #bufs_names
	local row = math.floor((vim.go.lines - height) / 2)
	local column = math.floor((vim.go.columns - default_opts.width) / 2)

	if height == 0 then
		-- Cleanup buffer on exit
		api.nvim_buf_delete(scratch_buf, { force = true })
		return
	end

	local win = api.nvim_open_win(scratch_buf, true, {
		relative = "editor",
		width = default_opts.width,
		height = height,
		row = row,
		col = column,
		title = "Buffer List",
		title_pos = "center",
		border = "rounded",
		style = "minimal",
		noautocmd = true,
	})

	vim.wo[win].number = true
	bo[scratch_buf].modifiable = false

	fn.setcursorcharpos(1, 6)

	km.set("n", default_opts.keymap.close_bufferlist, function()
		cmd("bwipeout")
	end, km_opts(scratch_buf, "exit"))

	for _, value in ipairs({
		{ "multi_save_buf", "save", "save multiple buffers" },
		{ "multi_close_buf", "close", "close multiple buffers" },
	}) do
		km.set("n", default_opts.keymap[value[1]], function()
			float_prompt(win, height, listed_bufs, scratch_buf, value[2], list_buffers)
		end, km_opts(scratch_buf, value[3]))
	end

	km.set("n", default_opts.keymap.save_all_unsaved, function()
		for index = 1, #listed_bufs do
			if bo[listed_bufs[index]].modified then
				save_buffer(listed_bufs, index, scratch_buf)
			end
		end
	end, km_opts(scratch_buf, "save all buffers"))

	km.set("n", default_opts.keymap.close_all_saved, function()
		for index = 1, #listed_bufs do
			close_buffer(listed_bufs, index)
		end
		refresh()
	end, km_opts(scratch_buf, "close all saved buffers"))

	km.set("n", default_opts.keymap.toggle_path, function()
		toggle_path(relative_paths, tpso)
	end, km_opts(scratch_buf, "toggle path"))

	for index = 1, #default_opts.win_keymaps do
		local wkm = default_opts.win_keymaps[index]
		local keymap_opts = wkm[3]
		keymap_opts.buffer = scratch_buf
		keymap_opts.desc = keymap_opts.desc or "BufferList: custom user defined keymap"
		km.set("n", wkm[1], function()
			wkm[2]({ bl_buf = scratch_buf, buffers = listed_bufs, winid = win, open_bufferlist = list_buffers })
		end, keymap_opts)
	end

	km.set("n", "v", "V", km_opts(scratch_buf, "start visual lines mode"))

	--Visual save
	km.set("v", default_opts.keymap.visual_save, function()
		multi_visual(save_buffer, scratch_buf, listed_bufs, win)
	end, km_opts(scratch_buf, "multi-save visual lines"))

	-- Visual close
	km.set("v", default_opts.keymap.visual_close, function()
		multi_visual(close_buffer, false, listed_bufs, win, refresh)
	end, km_opts(scratch_buf, "multi-close visual lines"))

	-- Visual force close
	km.set("v", default_opts.keymap.visual_force_close, function()
		multi_visual(close_buffer, true, listed_bufs, win, refresh)
	end, km_opts(scratch_buf, "force multi-close visual lines"))
end

---@param opts table
function bufferlist.setup(opts)
	default_opts = vim.tbl_deep_extend("force", default_opts, opts or {})
	api.nvim_create_user_command("BufferList", function()
		list_buffers()
	end, { desc = "Open BufferList" })

	vim.cmd(
		[[hi link BufferListCurrentBuffer Question | hi link BufferListModifiedIcon Macro | hi link BufferListLine MoreMsg | hi BufferListPromptNumber guifg=#118197 gui=bold | hi BufferListPromptSeperator guifg=#912771 guibg=#912771 gui=bold | hi link BufferListPromptForce WarningMsg | hi link BufferListPromptMultiSelected Visual | hi link BufferListPath Directory]]
	)
end
return bufferlist
