-- Copyright Microsoft and CHERIoT Contributors.
-- SPDX-License-Identifier: MIT

-- xmake has started refusing to pass flags that it doesn't recognise, so tell
-- it to stop doing that for now.
set_policy("check.auto_ignore_flags", false)

add_rules("mode.release", "mode.debug")

-- Disallow any modes other than release and debug.  The only difference is the
-- value of the `NDEBUG` macro: We always enable debug info and optimise for
-- size in both modes, most things should use the --debug-{option}= flags for
-- finer-grained control.
set_allowedmodes("release", "debug")

set_allowedarchs("cheriot")

-- More work arounds for xmake's buggy flag detection.
if is_mode("release") then
    add_defines("NDEBUG", {force = true})
end

option("board-mixins")
	set_default("")
	set_description("Comma separated list of board mixin patch files");
	set_showmenu(true)

option("scheduler-accounting")
	set_default(false)
	set_description("Track per-thread cycle counts in the scheduler");
	set_showmenu(true)

option("scheduler-multiwaiter")
	set_default(true)
	set_description("Enable multiwaiter support in the scheduler.  Disabling this can reduce code size if multiwaiters are not used.");
	set_showmenu(true)


option("allocator-rendering")
	set_default(false)
	set_description("Include heap_render() functionality in the allocator")
	set_showmenu(true)

function debugOption(name)
	option("debug-" .. name)
		set_default(false)
		set_description("Enable verbose output and assertions in the " .. name)
		set_showmenu(true)
		set_category("Debugging")
	option_end()
end

function debugLevelOption(name)
	option("debug-" .. name)
		set_default("none")
		set_description("Specify verbose output level (none|information|warning|error|critical) in the " .. name)
		set_showmenu(true)
		set_category("Debugging")
		set_values("none", "information", "warning", "error", "critical")
		before_check(function (option)
			-- For some reason, xmake calls this with a nil option sometimes.
			-- Just pretend it makes sense.
			if option == nil then
				return
			end
			-- Map possible options to the define values that we want:
			local values = {
				none = "None",
				information = "Information",
				warning = "Warning",
				error = "Error",
				critical = "Critical"
			}
			local value = values[tostring(option:value())]
			-- Even though we've specified the allowed values, xmake doesn't
			-- enforce this, so do it ourselves.
			if not value then
				raise("Invalid value " .. tostring(option:value()) .. " for option "..option:name())
			end
		end)
	option_end()
end

debugOption("loader")
debugOption("scheduler")
debugLevelOption("allocator")
debugOption("token_library")

function stackCheckOption(name)
	option("stack-usage-check-" .. name)
		set_default(false)
		set_description("Enable dynamic stack usage checks in " .. name .. ". Do not enable this in debug builds!")
		set_showmenu(true)
		set_category("Debugging")
	option_end()
end

stackCheckOption("allocator")
stackCheckOption("scheduler")

function testCheckOption(name)
	option("testing-" .. name)
		set_default(false)
		set_description("Enable testing feature " .. name .. ". Do not enable this in builds that don't produce a UART log!")
		set_showmenu(true)
		set_category("Debugging")
	option_end()
end

testCheckOption("model-output")

-- Force -Oz irrespective of build config.  At -O0, we blow out our stack and
-- require much stronger alignment.
set_optimize("Oz")

--Capture the directory containing this script for later use.  We need this to
--find the location of the linker scripts and so on.
local scriptdir = os.scriptdir()
-- The directory where we will find the core components
local coredir = path.join(scriptdir, "core")

-- Set up our llvm configuration.
toolchain("cheriot-clang")
	set_kind("standalone")
	set_toolset("cc", "clang")
	set_toolset("cxx", "clang++")
	set_toolset("ld", "ld.lld")
	set_toolset("objdump", "llvm-objdump")
	set_toolset("strip", "llvm-strip")
	set_toolset("as", "clang")

	--Set up the flags that we need.
	on_load(function (toolchain)
		local core_directory = scriptdir
		local include_directory = path.join(core_directory, "include")
		-- Flags used for C/C++ and assembly
		local default_flags = {
			"-target",
			"riscv32cheriot-unknown-unknown",
			"-mcpu=cheriot",
			"-mabi=cheriot",
			"-mxcheri-rvc",
			"-mrelax",
			"-fshort-wchar",
			"-nostdinc",
			"-Oz",
			"-g",
			"-ffunction-sections",
			"-fdata-sections",
			"-fomit-frame-pointer",
			"-fno-builtin-setjmp",
			"-fno-builtin-longjmp",
			"-fno-builtin-printf",
			"-fno-exceptions",
			"-fno-asynchronous-unwind-tables",
			"-fno-c++-static-destructors",
			"-fno-rtti",
			"-I" .. path.join(include_directory, "c++-config"),
			"-I" .. path.join(include_directory, "libc++"),
			"-I" .. include_directory,
		}
		-- C/C++ flags
		toolchain:add("cxflags", default_flags, {force = true})
		toolchain:add("cflags", default_flags)
		toolchain:add("cxxflags", "-std=c++23")
		toolchain:add("cflags", "-std=c23")
		-- Assembly flags
		toolchain:add("asflags", default_flags)
	end)
toolchain_end()


set_defaultarchs("cheriot")
set_defaultplat("cheriot")
set_languages("c23", "cxx23")

-- Common rules for any CHERI MCU component (library or compartment)
rule("cheriot.component")

	-- Set some default config values for all cheriot components.
	on_load(function (target)
		-- Treat this as a static library, though we will replace the default linking steps.
		target:set("kind", "static")
		-- We don't want a lib prefix or equivalent.
		target:set("prefixname", "")
	end)
	before_build(function (target)
		if not target:get("cheriot.board_file") then
			raise("target " .. target:name() .. " is being built but does not " ..
			"appear to be connected to a firmware image.  Please either use " ..
			"add_deps(\"" .. target:name() .. "\" to add it or use set_default(false) " ..
			"prevent it from being built when not linked")
		end
	end)

	-- Custom link step, link this as a compartment, with the linker script
	-- that will be provided in the specialisation of this rule.
	on_linkcmd(function (target, batchcmds, opt)
		-- Get a specified linker script
		local linkerscript_name = target:get("cheriot.ldscript")
		local linkerscript = path.join(scriptdir, linkerscript_name)
		-- Link using the compartment's linker script.
		batchcmds:show_progress(opt.progress, "linking " .. target:get("cheriot.type") .. ' ' .. target:filename())
		batchcmds:mkdir(target:targetdir())
		batchcmds:vrunv(target:tool("ld"), table.join({"--script=" .. linkerscript, "--compartment", "--gc-sections", "--relax", "-o", target:targetfile()}, target:objectfiles()), opt)
		-- This depends on all of the object files and the linker script.
		batchcmds:add_depfiles(linkerscript)
		batchcmds:add_depfiles(target:objectfiles())
	end)

-- CHERI MCU libraries are currently built as compartments, without a
-- `-cheri-compartment` flag.  They should gain that flag once the compiler
-- supports more than one library.
rule("cheriot.library")
	add_deps("cheriot.component")
	on_load(function (target)
		-- Mark this target as a CHERI MCU library.
		target:set("cheriot.type", "library")
		-- Libraries have a .library extension
		target:set("extension", ".library")
		-- Link with the library linker script, which drops .data* sections.
		target:set("cheriot.ldscript", "library.ldscript")

		target:add("defines", "CHERIOT_NO_AMBIENT_MALLOC")
	end)

-- CHERI MCU compartments have an explicit compartment name passed to the
-- compiler.
rule("cheriot.compartment")
	add_deps("cheriot.component")
	on_load(function (target)
		-- Mark this target as a CHERI MCU compartment.
		target:set("cheriot.type", "compartment")
		target:set("cheriot.ldscript", "compartment.ldscript")
		target:set("extension", ".compartment")
	end)
	-- Add the compartment name flag.  This defaults to the target's name but
	-- can be overridden by setting the cheriot.compartment property.
	after_load(function (target)
		local compartment = target:get("cheriot.compartment") or target:name()
		target:add("cxflags", "-cheri-compartment=" .. compartment, {force=true})
	end)

-- Privileged compartments are built as compartments, but with a slightly
-- different linker script.
rule("cheriot.privileged-compartment")
	add_deps("cheriot.compartment")
	on_load(function (target)
		target:set("cheriot.ldscript", "privileged-compartment.ldscript")
		target:set("cheriot.type", "privileged compartment")
		target:add("defines", "CHERIOT_AVOID_CAPRELOCS")
	end)

rule("cheriot.privileged-library")
	add_deps("cheriot.library")
	on_load(function (target)
		target:set("cheriot.type", "privileged library")
		target:set("cheriot.ldscript", "privileged-compartment.ldscript")
		target:add("defines", "CHERIOT_NO_AMBIENT_MALLOC")
	end)

-- Build the switcher as an object file that we can import into the final
-- linker script.  The switcher is independent of the firmware image
-- configuration and so can be built as a single target.
target("cheriot.switcher")
	set_kind("object")
	add_files(path.join(coredir, "switcher/entry.S"))

-- Build the allocator as a privileged compartment. The allocator is
-- independent of the firmware image configuration and so can be built as a
-- single target.
-- TODO: We should provide a mechanism for firmware images to either opt out of
-- having an allocator (or into providing a different allocator for a
-- particular application)
target("cheriot.allocator")
	add_rules("cheriot.privileged-compartment", "cheriot.component-debug", "cheriot.component-stack-checks")
	add_files(path.join(coredir, "allocator/main.cc"))
	add_deps("locks")
	add_deps("compartment_helpers")
	on_load(function (target)
		target:set("cheriot.compartment", "allocator")
		target:set('cheriot.debug-name', "allocator")
		target:add('defines', "HEAP_RENDER=" .. tostring(get_config("allocator-rendering")))
	end)

target("cheriot.token_library")
	add_rules("cheriot.privileged-library", "cheriot.component-debug")
	add_files(path.join(coredir, "token_library/token_unseal.S"))
	on_load(function (target)
		target:set('cheriot.debug-name', "token_library")
	end)

target("cheriot.software_revoker")
	set_default(false)
	add_files(path.join(coredir, "software_revoker/revoker.cc"))
	add_rules("cheriot.privileged-compartment")
	on_load(function (target)
		target:set("cheriot.compartment", "software_revoker")
		target:set("cheriot.ldscript", "software_revoker.ldscript")
		target:add("defines", "CHERIOT_NO_AMBIENT_MALLOC")
	end)

-- Helper to find a board file given either the name of a board file or a path.
local function board_file_for_name(boardName)
	local boardfile = boardName
	-- The directory containing the board file.
	local boarddir = path.directory(boardfile);
	-- If this isn't a path, look in the boards directory
	if not os.isfile(boardfile) then
		boarddir = path.join(scriptdir, "boards")
		local fullBoardPath = path.join(boarddir, boardfile .. '.json')
		if not os.isfile(fullBoardPath) then
			fullBoardPath = path.join(boarddir, boardfile .. '.patch')
		end
		if not os.isfile(fullBoardPath) then
			print("unable to find board file " .. boardfile .. ".  Try specifying a full path")
			return nil
		end
		boardfile = fullBoardPath
	end
	return boarddir, boardfile
end

-- Helper to get the board file for a given target
local function board_file_for_target(target)
	local boardName = target:values("board")
	if not boardName then
		print("target " .. target:name() .. " does not define a board name")
		return nil
	end
	return board_file_for_name(boardName)
end

-- If a string value is a number, return it as number, otherwise return it
-- in its original form.
local function asNumberIfNumber(value)
	if tostring(tonumber(value)) == value then
		return tonumber(value)
	end
	return value
end

-- Heuristic to tell a Lua table is probably an array in Lua
-- This is O(n), but n is usually very small, and this happens once per
-- build so this doesn't really matter.
--
-- The generality and minimality of Lua tables results in some subtlety.  While
-- Lua has a notion of "borders" within the integer keys of a table t (values b
-- s.t. "(b == 0 or t[b] ~= nil) and t[b+1] == nil"), atop which it defines a
-- "sequence", a table with only a single border, we mean something stronger: a
-- sequence with only positive integer keys densely packed from 1.
local function isarray(t)
	local border = nil

	-- Iteration order is undefined, even for numeric keys.  Each visited key
	-- has non-nil value.
	for k, _ in pairs(t) do
		-- A non-positive-integral key means this isn't an array
		-- (and since lua integers are finite, exclude anything for which
		-- successor would be ill-defined)
		if type(k) ~= "number" or
		   k <= 0 or
		   k >= math.maxinteger or
		   math.tointeger(k) ~= k then
			return false
		end

		if t[k+1] == nil then
			-- More than one border means this isn't a sequence
			if border ~= nil then return false end
			border = k
		end
	end

	-- An empty table (in which no border will be found) is an array.
	-- Otherwise, t is an array if all of the above and t[1] is populated.
	return (border == nil) or (t[1] ~= nil)
end


local function patch_board(json, base, patches)
	for _, p in ipairs(patches) do
		if not p.op then
			print("missing op in "..json.encode(p))
			return nil
		end
		if not p.path or (type(p.path) ~= "string") then
			print("missing or invalid path in "..json.encode(p))
			return nil
		end

		-- Parse the JSON Pointer into an array of filed names, converting
		-- numbers into Lua numbers if we see them.  This is not quite right,
		-- because it doesn't handle field names with / in them, but we don't
		-- currently use those for anything.  It also assumes that we really do
		-- mean array indexes when we say numbers.  If we have an object with
		-- "3" as the key and try to replace 3, it will currently not do the
		-- right thing.  
		local objectPath = {}
		for entry in string.gmatch(p.path, "/([^/]+)") do
			table.insert(objectPath, asNumberIfNumber(entry))
		end

		if #objectPath < 1 then
			print("invalid path in "..json.encode(p))
			return nil
		end

		-- JSON arrays are indexed from 0, Lua's are from 1.  If someone says
		-- array index 0, we need to map that to 1, and so on.

		-- Last path object is the name of the key we're going to modify.
		local nodeName = table.remove(objectPath)
		-- Walk the path to find the object that we're going to modify.
		local nodeToModify = base
		for _, pathComponent in ipairs(objectPath) do
			if isarray(nodeToModify) then
				if type(pathComponent) ~= "number" then
					print("invalid non-numeric index into array in "..json.encode(p))
					return nil
				end
				pathComponent = pathComponent + 1
			end
			nodeToModify = nodeToModify[pathComponent]
		end

		local isArrayOperation = false
		if isarray(nodeToModify) then
			if type(nodeName) == "number" then
				nodeName = nodeName + 1
				isArrayOperation = true
			elseif p.op == "add" and nodeName == "-" then
				-- The string "-" at the end of an "add"'s path means "append"
				nodeName = #nodeToModify + 1
				isArrayOperation = true
			end
		end

		-- Handle the operation
		if (p.op == "replace") or (p.op == "add") then
			if not p.value then
				print(tostring(p.op).. " requires a value, missing in ", json.encode(p))
				return nil
			end
			if isArrayOperation and p.op == "add" then
				table.insert(nodeToModify, nodeName, p.value)
			else
				nodeToModify[nodeName] = p.value
			end
		elseif p.op == "remove" then
			nodeToModify[nodeName] = nil
		else
			print(tostring(p.op) .. " is not a valid operation in ", json.encode(p))
			return nil
		end
	end
end

-- Helper to load a board file.  This must be passed the json object provided
-- by import("core.base.json") because import does not work in helper
-- functions at the top level.
local function load_board_file_inner(json, boardFile)
	if path.extension(boardFile) == ".json" then
		return json.loadfile(boardFile)
	end
	if path.extension(boardFile) ~= ".patch" then
		print("unknown extension for board file: " .. boardFile)
		return nil
	end
	local patch = json.loadfile(boardFile)
	if not patch.base then
		print("Board file " .. boardFile .. " does not specify a base")
		return nil
	end
	local _, baseFile = board_file_for_name(patch.base)
	local base = load_board_file_inner(json, baseFile)

	patch_board(json, base, patch.patch)

	return base
end

-- Load a board (patch) file (recursively) and then apply the configuration's
-- mixins as well.
local function load_board_file(json, boardFile, xmakeConfig)
	local base = load_board_file_inner(json, boardFile)

	local mixinString = xmakeConfig.get("board-mixins")
	if not mixinString or mixinString == "" then
		return base
	end

	for mixinName in mixinString:gmatch("([^,]*),?") do
		local _, mixinFile = board_file_for_name(mixinName)

		-- XXX this *ought* to return nil, error on error, but it just throws.
		local mixinTree, err = json.loadfile(mixinFile)
		if not mixinTree then
			error ("Could not process mixin %q: %s"):format(mixinName, err)
		end

		print(("Patching board with %q"):format(mixinFile))

		patch_board(json, base, mixinTree)
	end

	return base
end

-- Helper to visit all dependencies of a specified target exactly once and call
-- a callback.
local function visit_all_dependencies_of(target, callback)
	local visited = {}
	local function visit(target)
		if not visited[target:name()] then
			visited[target:name()] = true
			callback(target)
			for _, d in table.orderpairs(target:deps()) do
				visit(d)
			end
		end
	end
	visit(target)
end

-- Rule for defining a firmware image.
rule("cheriot.firmware")
	on_run(function (target)
		import("core.base.json")
		import("core.project.config")
		local boarddir, boardfile = board_file_for_target(target)
		local board = load_board_file(json, boardfile, config)
		if (not board.run_command) and (not board.simulator) then
			raise("board description " .. boardfile .. " does not define a run command")
		end
		local simulator = board.run_command or board.simulator
		simulator = string.gsub(simulator, "${(%w*)}", { sdk=scriptdir, board=boarddir })
		local firmware = target:targetfile()
		local directory = path.directory(firmware)
		firmware = path.filename(firmware)
		local run = function(simulator)
			local simargs = { firmware }
			os.execv(simulator, simargs, { curdir = directory })
		end
		-- Try executing the simulator from the sdk directory, if it's there.
		local tools_directory = config.get("sdk")
		local simpath = path.join(tools_directory, simulator)
		if os.isexec(simpath) then
			run(simpath)
			return
		end
		simpath = path.join(path.join(tools_directory, "bin"), simulator)
		if os.isexec(simpath) then
			run(simpath)
			return
		end
		-- Otherwise, hope that it's in the path
		run(simulator)
	end)

	-- Set up the thread defines and the information for the linker script.
	-- This must be after load so that dependencies are resolved.
	after_load(function (target)
		import("core.base.json")
		import("core.project.config")

		local function visit_all_dependencies(callback)
			visit_all_dependencies_of(target, callback)
		end

		local boarddir, boardfile = board_file_for_target(target);
		local board = load_board_file(json, boardfile, config)
		print("Board file saved as ", target:targetfile()..".board.json")
		json.savefile(target:targetfile()..".board.json", board)

		-- Add defines to all dependencies.
		local add_defines_each_dependency = function (defines)
			visit_all_dependencies(function (target)
				target:add('defines', defines)
			end)
		end

		-- Add cxflags to all dependencies.
		local add_cxflags = function (cxflags)
			visit_all_dependencies(function (target)
				target:add('cxflags', cxflags, {force = true})
			end)
		end

		local software_revoker = false
		if board.revoker then
			local temporal_defines = { "TEMPORAL_SAFETY" }
			if board.revoker == "software" then
				temporal_defines[#temporal_defines+1] = "SOFTWARE_REVOKER"
				software_revoker = true
				target:add('deps', "cheriot.software_revoker")
			end
			add_defines_each_dependency(temporal_defines)
		end

		-- Check that all dependences have a single board that they're targeting.
		visit_all_dependencies(function (target)
			local targetBoardFile = target:get("cheriot.board_file")
			local targetBoardDir = target:get("cheriot.board_dir")
			if not targetBoardFile and not targetBoardDir then
				target:set("cheriot.board_file", boardfile)
				target:set("cheriot.board_dir", boarddir)
			else
				if targetBoardFile ~= boardfile or targetBoardDir ~= boarddir then
					raise("target " .. target:name() .. " is used in two or more firmware targets with different boards")
				end
			end
		end)

		if board.driver_includes then
			for _, include_path in ipairs(board.driver_includes) do
				-- Allow ${sdk} to refer to the SDK directory, so that external
				-- board includes can include generic platform bits.
				include_path = string.gsub(include_path, "${(%w*)}", { sdk=scriptdir })
				if not path.is_absolute(include_path) then
					include_path = path.join(boarddir, include_path);
				end
				visit_all_dependencies(function (target)
					target:add('includedirs', include_path)
				end)
			end
		end

		-- If this board defines any macros, add them to all targets
		if board.defines then
			add_defines_each_dependency(board.defines)
		end

		local scheduler = target:deps()[target:name() .. ".scheduler"]

		-- If this board defines any cxflags, add them to all targets
		if board.cxflags then
			add_cxflags(board.cxflags)
		end

		add_defines_each_dependency("CPU_TIMER_HZ=" .. math.floor(board.timer_hz))
		add_defines_each_dependency("TICK_RATE_HZ=" .. math.floor(board.tickrate_hz))

		if board.simulation then
			add_defines_each_dependency("SIMULATION")
		end

		local loader = target:deps()['cheriot.loader'];

		if board.stack_high_water_mark then
			add_defines_each_dependency("CONFIG_MSHWM")
		else
			-- If we don't have the stack high watermark, the trusted stack is smaller.
			loader:set('loader_trusted_stack_size', 176)
		end

		-- Build the MMIO space for the board
		local mmio = ""
		local mmio_start = 0xffffffff
		local mmio_end = 0
		-- Add start and end markers for all MMIO devices.
		for name, range in table.orderpairs(board.devices) do
			local start = range.start
			local stop = range["end"]
			if not stop then
				if not range.length then
					raise("Device " .. name .. " does not specify a length or an end)")
				end
				stop = start + range.length
			end
			add_defines_each_dependency("DEVICE_EXISTS_" .. name)
			mmio_start = math.min(mmio_start, start)
			mmio_end = math.max(mmio_end, stop)
			mmio = format("%s__export_mem_%s = 0x%x;\n__export_mem_%s_end = 0x%x;\n",
				mmio, name, start, name, stop);
		end
		-- Provide the range of the MMIO space and the heap.
		mmio = format("__mmio_region_start = 0x%x;\n%s__mmio_region_end = 0x%x;\n__export_mem_heap_end = 0x%x;\n",
			mmio_start, mmio, mmio_end, board.heap["end"])

		local code_start = format("0x%x", board.instruction_memory.start);
		-- Put the data either at the specified address if given, or directly after code
		local data_start = board.data_memory and format("0x%x", board.data_memory.start) or '.';
		local rwdata_ldscript = path.join(config.buildir(), target:name() .. "-firmware.rwdata.ldscript")
		local rocode_ldscript = path.join(config.buildir(), target:name() .. "-firmware.rocode.ldscript")
		if not board.data_memory or (board.instruction_memory.start < board.data_memory.start) then
			-- If we're not explicilty given a data address or it's lower than the code address
			-- then code needs to go first in the linker script.
			firmware_low_ldscript = rocode_ldscript
			firmware_high_ldscript = rwdata_ldscript
		else
			-- Otherwise the data is at a lower address than code (e.g. Sonata with SRAM and hyperram)
			-- so it needs to go first.
			firmware_low_ldscript = rwdata_ldscript;
			firmware_high_ldscript = rocode_ldscript;
		end

		-- Set the start of memory that can be revoked.
		-- By default, this is the start of code memory but it can be
		-- explicitly overwritten.
		local revokable_memory_start = code_start;
		if board.revokable_memory_start then
			revokable_memory_start = format("0x%x", board.revokable_memory_start);
		end
		add_defines_each_dependency("REVOKABLE_MEMORY_START=" .. revokable_memory_start);

		local heap_start = '.'
		if board.heap.start then
			heap_start = format("0x%x", board.heap.start)
		end
		
		if board.interrupts then
			-- The macro used to provide the interrupt enumeration in the public header
			local interruptNames = "CHERIOT_INTERRUPT_NAMES="
			-- Define the macro that's used to initialise the scheduler's interrupt configuration.
			local interruptConfiguration = "CHERIOT_INTERRUPT_CONFIGURATION="
			for _, interrupt in ipairs(board.interrupts) do
				interruptNames = interruptNames .. interrupt.name .. "=" .. math.floor(interrupt.number) .. ", "
				interruptConfiguration = interruptConfiguration .. "{"
					.. math.floor(interrupt.number) .. ","
					.. math.floor(interrupt.priority) .. ","
					.. (interrupt.edge_triggered and "true" or "false")
					.. "},"
			end
			add_defines_each_dependency(interruptNames)
			scheduler:add('defines', interruptConfiguration)
		end

		local loader_stack_size = loader:get('loader_stack_size')
		local loader_trusted_stack_size = loader:get('loader_trusted_stack_size')
		loader:add('defines', "CHERIOT_LOADER_TRUSTED_STACK_SIZE=" .. loader_trusted_stack_size)

		-- Get the threads config and prepare the predefined macros that describe them
		local threads = target:values("threads")

		-- Declare space and start and end symbols for a thread's C stack
		local thread_stack_template =
			"\n\t. = ALIGN(16);" ..
			"\n\t.thread_stack_${thread_id} : CAPALIGN" ..
			"\n\t{" ..
			"\n\t\t.thread_${thread_id}_stack_start = .;" ..
			"\n\t\t. += ${stack_size};" ..
			"\n\t\t.thread_${thread_id}_stack_end = .;" ..
			"\n\t}\n"
		-- Declare space and start and end symbols for a thread's trusted stack
		local thread_trusted_stack_template =
			"\n\t. = ALIGN(8);" ..
			"\n\t.thread_trusted_stack_${thread_id} : CAPALIGN" ..
			"\n\t{" ..
			"\n\t\t.thread_${thread_id}_trusted_stack_start = .;" ..
			"\n\t\t. += ${trusted_stack_size};" ..
			"\n\t\t.thread_${thread_id}_trusted_stack_end = .;" ..
			"\n\t}\n"
		-- Build a `class ThreadConfig` for a thread
		local thread_template =
				"\n\t\tSHORT(${priority});" ..
				"\n\t\tLONG(${mangled_entry_point});" ..
				"\n\t\tLONG(.thread_${thread_id}_stack_start);" ..
				"\n\t\tSHORT(.thread_${thread_id}_stack_end - .thread_${thread_id}_stack_start);" ..
				"\n\t\tLONG(.thread_${thread_id}_trusted_stack_start);" ..
				"\n\t\tSHORT(.thread_${thread_id}_trusted_stack_end - .thread_${thread_id}_trusted_stack_start);" ..
				"\n\n"

		-- Stacks must be less than this size or truncating them in compartment
		-- switch may encounter precision errors.
		local stack_size_limit = 8176

		-- Initial pass through thread sequence to derive values within each
		local thread_priorities_set = {}
		for i, thread in ipairs(threads) do
			thread.mangled_entry_point = string.format("\"__export_%s__Z%d%sv\"", thread.compartment, string.len(thread.entry_point), thread.entry_point)
			thread.thread_id = i
			-- Trusted stack frame is 24 bytes.  If this size is too small, the
			-- loader will fail.  If it is too big, we waste space.
			thread.trusted_stack_size = loader_trusted_stack_size + (24 * thread.trusted_stack_frames)

			if thread.stack_size > stack_size_limit then
				raise("thread " .. i .. " requested a " .. thread.stack_size ..
				" stack.  Stacks over " .. stack_size_limit ..
				" are not yet supported in the compartment switcher.")
			end

			if type(thread.priority) ~= "number" or thread.priority < 0 then
				raise(("thread %d has malformed priority %q"):format(i, thread.priority))
			end
			thread_priorities_set[thread.priority] = true
		end

		-- Repack thread priorities into a contiguous span starting at 0.
		local thread_priorities = {}
		for p, _ in pairs(thread_priorities_set) do
			table.insert(thread_priorities, p)
		end
		table.sort(thread_priorities)
		local thread_priority_remap = {}
		for ix, v in ipairs(thread_priorities) do
			thread_priority_remap[v] = ix - 1
		end
		for i, thread in ipairs(threads) do
			if thread.priority ~= thread_priority_remap[thread.priority] then
				print(("Remapping priority of thread %d from %d to %d"):format(
					i, thread.priority, thread_priority_remap[thread.priority]
				))
				thread.priority = thread_priority_remap[thread.priority]
			end
		end

		-- Second pass through thread sequence, generating linker directives
		local thread_headers = ""
		local thread_trusted_stacks =
			"\n\t. = ALIGN(8);" ..
			"\n\t.loader_trusted_stack : CAPALIGN" ..
			"\n\t{" ..
			"\n\t\tbootTStack = .;" ..
			"\n\t\t. += " .. loader_trusted_stack_size .. ";" ..
			"\n\t}\n"
		local thread_stacks =
			"\n\t. = ALIGN(16);" ..
			"\n\t.loader_stack : CAPALIGN" ..
			"\n\t{" ..
			"\n\t\tbootStack = .;" ..
			"\n\t\t. += " .. loader_stack_size .. ";" ..
			"\n\t}\n"
		for i, thread in ipairs(threads) do
			thread_stacks = thread_stacks .. string.gsub(thread_stack_template, "${([_%w]*)}", thread)
			thread_trusted_stacks = thread_trusted_stacks .. string.gsub(thread_trusted_stack_template, "${([_%w]*)}", thread)
			thread_headers = thread_headers .. string.gsub(thread_template, "${([_%w]*)}", thread)
		end
		scheduler:add('defines', "CONFIG_THREADS_NUM=" .. #(threads))

		-- Next set up the substitutions for the linker scripts.

		-- Templates for parts of the linker script that are instantiated per compartment
		local compartment_templates = {
			compartment_headers =
				"\n\t\tLONG(\".${compartment}_code_start\");" ..
				"\n\t\tSHORT((SIZEOF(.${compartment}_code) + 7) / 8);" ..
				"\n\t\tSHORT(\".${compartment}_imports_end\" - \".${compartment}_code_start\");" ..
				"\n\t\tLONG(\".${compartment}_export_table\");" ..
				"\n\t\tSHORT(\".${compartment}_export_table_end\" - \".${compartment}_export_table\");" ..
				"\n\t\tLONG(\".${compartment}_globals\");" ..
				"\n\t\tSHORT(SIZEOF(.${compartment}_globals));" ..
				"\n\t\tSHORT(\".${compartment}_bss_start\" - \".${compartment}_globals\");" ..
				"\n\t\tLONG(\".${compartment}_cap_relocs_start\");" ..
				"\n\t\tSHORT(\".${compartment}_cap_relocs_end\" - \".${compartment}_cap_relocs_start\");" ..
				"\n\t\tLONG(\".${compartment}_sealed_objects_start\");" ..
				"\n\t\tSHORT(\".${compartment}_sealed_objects_end\" - \".${compartment}_sealed_objects_start\");\n",
			pcc_ld =
				"\n\t\".${compartment}_code\" : CAPALIGN" ..
				"\n\t{" ..
				"\n\t\t\".${compartment}_code_start\" = .;" ..
				"\n\t\t\"${obj}\"(\".compartment_import_table\");" ..
				"\n\t\t\".${compartment}_imports_end\" = .;" ..
				"\n\t\t\"${obj}\"(.text);" ..
				"\n\t\t\"${obj}\"(.init_array);" ..
				"\n\t\t\"${obj}\"(.rodata);" ..
				"\n\t\t. = ALIGN(8);" ..
				"\n\t}\n",
			gdc_ld =
				"\n\t\".${compartment}_globals\" : CAPALIGN" ..
				"\n\t{" ..
				"\n\t\t\".${compartment}_globals\" = .;" ..
				"\n\t\t\"${obj}\"(.data);" ..
				"\n\t\t\".${compartment}_bss_start\" = .;" ..
				"\n\t\t\"${obj}\"(.bss)" ..
				"\n\t}\n",
			compartment_exports =
				"\n\t\t. = ALIGN(8); \".${compartment}_export_table\" = .;" ..
				"\n\t\t\"${obj}\"(.compartment_export_table);" ..
				"\n\t\t\".${compartment}_export_table_end\" = .;\n",
			cap_relocs =
				"\n\t\t\".${compartment}_cap_relocs_start\" = .;" ..
				"\n\t\t\"${obj}\"(__cap_relocs);\n\t\t\".${compartment}_cap_relocs_end\" = .;",
			sealed_objects =
				"\n\t\t\".${compartment}_sealed_objects_start\" = .;" ..
				"\n\t\t\"${obj}\"(.sealed_objects);\n\t\t\".${compartment}_sealed_objects_end\" = .;"
		}
		--Library headers are almost identical to compartment headers, except
		--that they don't have any globals.
		local library_templates = {
			compartment_headers =
				"\n\t\tLONG(\".${compartment}_code_start\");" ..
				"\n\t\tSHORT((SIZEOF(.${compartment}_code) + 7) / 8);" ..
				"\n\t\tSHORT(\".${compartment}_imports_end\" - \".${compartment}_code_start\");" ..
				"\n\t\tLONG(\".${compartment}_export_table\");" ..
				"\n\t\tSHORT(\".${compartment}_export_table_end\" - \".${compartment}_export_table\");" ..
				"\n\t\tLONG(0);" ..
				"\n\t\tSHORT(0);" ..
				"\n\t\tSHORT(0);" ..
				"\n\t\tLONG(\".${compartment}_cap_relocs_start\");" ..
				"\n\t\tSHORT(\".${compartment}_cap_relocs_end\" - \".${compartment}_cap_relocs_start\");" ..
				"\n\t\tLONG(\".${compartment}_sealed_objects_start\");" ..
				"\n\t\tSHORT(\".${compartment}_sealed_objects_end\" - \".${compartment}_sealed_objects_start\");\n",
			pcc_ld = compartment_templates.pcc_ld,
			gdc_ld = "",
			library_exports = compartment_templates.compartment_exports,
			cap_relocs = compartment_templates.cap_relocs,
			sealed_objects = compartment_templates.sealed_objects
		}
		-- The substitutions that we're going to have in the final linker
		-- script.  Initialised as empty strings.
		local ldscript_substitutions = {
			compartment_exports="",
			library_exports="",
			cap_relocs="",
			compartment_headers="",
			pcc_ld="",
			gdc_ld="",
			software_revoker_code="",
			software_revoker_globals="",
			software_revoker_header="",
			sealed_objects="",
			mmio=mmio,
			data_start=data_start,
			code_start=code_start,
			heap_start=heap_start,
			firmware_low_ldscript=firmware_low_ldscript,
			firmware_high_ldscript=firmware_high_ldscript,
			thread_count=#(threads),
			thread_headers=thread_headers,
			thread_trusted_stacks=thread_trusted_stacks,
			thread_stacks=thread_stacks,
			loader_stack_size=loader:get('loader_stack_size'),
			loader_trusted_stack_size=loader:get('loader_trusted_stack_size')
		}
		-- Helper function to add a dependency to the linker script
		local add_dependency = function (name, dep, templates)
			local obj = path.relative(dep:targetfile(), "$(projdir)")
			local obj = dep:targetfile()
			-- Helper to substitute the current compartment name and object file into a template.
			local substitute = function (str)
				return string.gsub(str, "${(%w*)}", { obj=obj, compartment=name })
			end
			for key, template in table.orderpairs(templates) do
				ldscript_substitutions[key] = ldscript_substitutions[key] .. substitute(template)
			end
		end

		-- If this board requires the software revoker, add it as a dependency
		-- and add the relevant bits to the linker script.
		if software_revoker then
			ldscript_substitutions.software_revoker_code =
				"\tsoftware_revoker_code : CAPALIGN\n" ..
				"\t{\n" ..
				"\t\t.software_revoker_start = .;\n" ..
				"\t\t.software_revoker_import_end = .;\n" ..
				"\t\tsoftware_revoker.compartment(.text .text.* .rodata .rodata.* .data.rel.ro);\n" ..
				"\t\t*/cheriot.software_revoker.compartment(.text .text.* .rodata .rodata.* .data.rel.ro);\n" ..
				"\t}\n" ..
				"\t.software_revoker_end = .;\n\n"
			ldscript_substitutions.software_revoker_globals =
				"\n\t.software_revoker_globals : CAPALIGN" ..
				"\n\t{" ..
				"\n\t\t.software_revoker_globals = .;" ..
				"\n\t\t*/cheriot.software_revoker.compartment(.data .data.* .sdata .sdata.*);" ..
				"\n\t\t.software_revoker_bss_start = .;" ..
				"\n\t\t*/cheriot.software_revoker.compartment(.sbss .sbss.* .bss .bss.*)" ..
				"\n\t}" ..
				"\n\t.software_revoker_globals_end = .;\n"
			ldscript_substitutions.compartment_exports =
				"\n\t\t. = ALIGN(8); .software_revoker_export_table = .;" ..
				"\n\t\t*/cheriot.software_revoker.compartment(.compartment_export_table);" ..
				"\n\t\t.software_revoker_export_table_end = .;\n" ..
				ldscript_substitutions.compartment_exports
			ldscript_substitutions.software_revoker_header =
				"\n\t\tLONG(.software_revoker_start);" ..
				"\n\t\tSHORT(.software_revoker_end - .software_revoker_start);" ..
				"\n\t\tLONG(.software_revoker_globals);" ..
				"\n\t\tSHORT(SIZEOF(.software_revoker_globals));" ..
				-- The software revoker has no import table.
				"\n\t\tLONG(0)" ..
				"\n\t\tSHORT(0)" ..
				"\n\t\tLONG(.software_revoker_export_table);" ..
				"\n\t\tSHORT(.software_revoker_export_table_end - .software_revoker_export_table);\n" ..
				"\n\t\tLONG(0);" ..
				"\n\t\tSHORT(0);\n"
		end


		-- Process all of the library dependencies.
		local library_count = 0
		visit_all_dependencies(function (target)
			if target:get("cheriot.type") == "library" then
				library_count = library_count + 1
				add_dependency(target:name(), target, library_templates)
			end
		end)

		-- Process all of the compartment dependencies.
		local compartment_count = 0
		visit_all_dependencies(function (target)
			if target:get("cheriot.type") == "compartment" then
				compartment_count = compartment_count + 1
				add_dependency(target:name(), target, compartment_templates)
			end
		end)

		local shared_objects = {
			-- 32-bit counter for the hazard-pointer epoch.
			allocator_epoch = 4,
			-- Two hazard pointers per thread.
			allocator_hazard_pointers = #(threads) * 8 * 2
			}
		visit_all_dependencies(function (target)
			local globals = target:values("shared_objects")
			if globals then
				for name, size in pairs(globals) do
					if not (name == "__wrap_locked__") then
						if shared_objects[global] and (not (shared_objects[global] == size)) then
							raise("Global " .. global .. " is declared with different sizes.")
						end
						shared_objects[name] = size
					end
				end
			end
		end)
		-- TODO: We should sort pre-shared globals by size to minimise padding.
		-- Each global is emitted as a separate section so that we can use
		-- CAPALIGN and let the linker insert the required padding.
		local shared_objects_template =
			"\n\t\t. = ALIGN(MIN(${size}, 8));" ..
			"\n\t\t__cheriot_shared_object_section_${global} : CAPALIGN" ..
			"\n\t\t{" ..
			"\n\t\t\t__cheriot_shared_object_${global} = .;" ..
			"\n\t\t\t. += ${size};" ..
			"\n\t\t\t__cheriot_shared_object_${global}_end = .;" ..
			"\n\t\t}\n"
		local shared_objects_section = ""
		for global, size in table.orderpairs(shared_objects) do
			shared_objects_section = shared_objects_section .. string.gsub(shared_objects_template, "${([_%w]*)}", {global=global, size=size})
		end
		ldscript_substitutions.shared_objects = shared_objects_section

		-- Add the counts of libraries and compartments to the substitution list.
		ldscript_substitutions.compartment_count = compartment_count
		ldscript_substitutions.library_count = library_count

		-- Set the each of the substitutions.
		for key, value in pairs(ldscript_substitutions) do
			target:set("configvar", key, value)
		end
	end)

	-- Perform the final link step for a firmware image.
	on_linkcmd(function (target, batchcmds, opt)
		import("core.project.config")
		-- Get a specified linker script, or set the default to the compartment
		-- linker script.
		local linkerscript1 = path.join(config.buildir(), target:name() .. "-firmware.ldscript")
		local linkerscript2 = path.join(config.buildir(), target:name() .. "-firmware.rocode.ldscript")
		local linkerscript3 = path.join(config.buildir(), target:name() .. "-firmware.rwdata.ldscript")
		-- Link using the firmware's linker script.
		batchcmds:show_progress(opt.progress, "linking firmware " .. target:targetfile())
		batchcmds:mkdir(target:targetdir())
		local objects = target:objectfiles()
		visit_all_dependencies_of(target, function (dep)
			if (dep:get("cheriot.type") == "library") or
				(dep:get("cheriot.type") == "compartment") or
				(dep:get("cheriot.type") == "privileged compartment") or
				(dep:get("cheriot.type") == "privileged library") then
				table.insert(objects, dep:targetfile())
			end
		end)
		batchcmds:vrunv(target:tool("ld"), table.join({"-n", "--script=" .. linkerscript1, "--relax", "-o", target:targetfile(), "--compartment-report=" .. target:targetfile() .. ".json" }, objects), opt)
		batchcmds:show_progress(opt.progress, "Creating firmware report " .. target:targetfile() .. ".json")
		batchcmds:show_progress(opt.progress, "Creating firmware dump " .. target:targetfile() .. ".dump")
		batchcmds:vexecv(target:tool("objdump"), {"-glxsdrS", "--demangle", target:targetfile()}, table.join(opt, {stdout = target:targetfile() .. ".dump"}))
		batchcmds:add_depfiles(linkerscript1, linkerscript2, linkerscript3)
		batchcmds:add_depfiles(objects)
	end)

-- Rule for conditionally enabling debug for a component.
rule("cheriot.component-debug")
	after_load(function (target)
		local name = target:get("cheriot.debug-name") or target:name()
		local value = get_config("debug-"..name)
		if type(value) == "nil" then
			error ("No debug configuration for %q; missing xmake debugOption()?"):format(name)
		elseif type(value) == "boolean" then
			value = tostring(value)
		else
			-- Initial capital
			value = "DebugLevel::" .. string.sub(value, 1, 1):upper() .. string.sub(value, 2)
		end
		target:add('options', "debug-" .. name)
		target:add('defines', "DEBUG_" .. name:upper() .. "=" .. value);
	end)

-- Rule for conditionally enabling stack checks for a component.
rule("cheriot.component-stack-checks")
	after_load(function (target)
		local name = target:get("cheriot.debug-name") or target:name()
		target:add('options', "stack-usage-check-" .. name)
		target:add('defines', "CHERIOT_STACK_CHECKS_" .. name:upper() .. "=" .. tostring(get_config("stack-usage-check-"..name)))
	end)

-- Rule for making RTOS git revision information available to a build target.
--
-- Because this value is definitionally quite volatile, we jump through some
-- hoops to allow it to be set per file rather than per xmake target, minimizing
-- splash damage (necessitating only recompiling the necessary files and
-- relinking revdepwards to the firmware image).  That is, rather than using
-- add_rules at the target scope, you can add this rule as part of add_files:
--
--   add_files("version.cc", {rules = {"cheriot.define-rtos-git-description"}})
local sdk_git_description = nil
rule("cheriot.define-rtos-git-description")
	before_build_file(function(target, sourcefile, opt)
		sdk_git_description = sdk_git_description or try {
			function()
				return os.iorunv("git", {"-C", scriptdir, "describe", "--always", "--dirty"}):gsub("[\r\n]", "")
			end
		}
		sdk_git_description = sdk_git_description or "unknown"

		local fileconfig = target:fileconfig(sourcefile) or {}
		fileconfig.defines = fileconfig.defines or {}
		table.insert(fileconfig.defines, ("CHERIOT_RTOS_GIT_DESCRIPTION=%q"):format(sdk_git_description))
		target:fileconfig_set(sourcefile, fileconfig)
	end)

-- Build the loader.  The firmware rule will set the flags required for
-- this to create threads.
target("cheriot.loader")
	add_rules("cheriot.component-debug")
	set_kind("object")
	-- FIXME: We should be setting this based on a board config file.
	add_files(path.join(coredir, "loader/boot.S"), path.join(coredir, "loader/boot.cc"),  {force = {cxflags = "-O1"}})
	add_defines("CHERIOT_AVOID_CAPRELOCS")
	on_load(function (target)
		target:set('cheriot.debug-name', "loader")
		local config = {
			-- Size in bytes of the trusted stack.
			loader_trusted_stack_size = 192,
			-- Size in bytes of the loader's stack.
			loader_stack_size = 1024
		}
		target:add('defines', "CHERIOT_LOADER_STACK_SIZE=" .. config.loader_stack_size)
		target:add("defines", "CHERIOT_NO_AMBIENT_MALLOC")
		target:set('cheriot_loader_config', config)
		for k, v in pairs(config) do
			target:set(k, v)
		end
	end)

-- Helper function to define firmware.  Used as `target`.
function firmware(name)
	-- Build the scheduler.  The firmware rule will set the flags required for
	-- this to create threads.
	target(name .. ".scheduler")
		add_rules("cheriot.privileged-compartment", "cheriot.component-debug", "cheriot.component-stack-checks")
		add_deps("locks", "crt", "atomic1")
		add_deps("compartment_helpers")
		on_load(function (target)
			target:set("cheriot.compartment", "scheduler")
			target:set('cheriot.debug-name', "scheduler")
			target:add('defines', "SCHEDULER_ACCOUNTING=" .. tostring(get_config("scheduler-accounting")))
			target:add('defines', "SCHEDULER_MULTIWAITER=" .. tostring(get_config("scheduler-multiwaiter")))
		end)
		add_files(path.join(coredir, "scheduler/main.cc"))

	-- Create the firmware target.  This target remains open on return and so
	-- the caller can add more rules to it.
	target(name)
		set_kind("binary")
		add_rules("cheriot.firmware")
		-- TODO: Make linking the allocator optional.
		add_deps(name .. ".scheduler", "cheriot.loader", "cheriot.switcher", "cheriot.allocator")
		add_deps("cheriot.token_library")
		-- The firmware linker script will be populated based on the set of
		-- compartments.
		add_configfiles(path.join(scriptdir, "firmware.ldscript.in"), {pattern = "@(.-)@", filename = name .. "-firmware.ldscript"})
		add_configfiles(path.join(scriptdir, "firmware.rocode.ldscript.in"), {pattern = "@(.-)@", filename = name .. "-firmware.rocode.ldscript"})
		add_configfiles(path.join(scriptdir, "firmware.rwdata.ldscript.in"), {pattern = "@(.-)@", filename = name .. "-firmware.rwdata.ldscript"})
end

-- Helper to create a library.
function library(name)
	target(name)
		add_rules("cheriot.library")
end

-- Helper to create a compartment.
function compartment(name)
	target(name)
		add_rules("cheriot.compartment")
end

includes("lib/")

