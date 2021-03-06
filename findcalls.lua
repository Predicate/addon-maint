--[[
Requires OllyDbg 2.x from http://www.ollydbg.de/ and ollydbg2-playtime from https://github.com/mrexodia/ollydbg2-playtime

Upon disassembly of a WoW client executable, this script outputs Lua tables containing all calls to register CVars and CCmds.
Most of these are named with static strings, but a small number have dynamically generated names (by iteration/concatenation).
For diffability, these "dynamic" calls are output in a separate table, in the order they were found.
Additionally, prints all Lua error messages that are generated by C. This includes all of the API "Usage" pseudo-documentation.

Can run within Olly and output to Log window by setting this flag to false:
--]]
local HEADLESS = true

--[[
Or for headless use, put this script in Lua\autoruns directory and run:
ollydbg.exe "C:\path\to\Wow.exe" "-noautolaunch64bit" >console.lua

Under wine, xvfb can be used to suppress the GUI:
xvfb-run wine ollydbg.exe "/path/to/Wow.exe" "-noautolaunch64bit" >console.lua

In headless mode, Olly will automatically exit after scanning is complete.
If an error occurs, processing will stop and Olly will not exit. Error details can be found in the Log window.
--]]

--name = { args, known string, filter_anon }
local searches = {
	CVars = { 9, "hwDetect", true },
	CCmds = { 5, "reloadUI", true },
	Errors = { 2, [[Usage: GetCVar("cvar")]], false },
	Enums = { 2, "LE_ACTIONBAR_STATE_MAIN", false }
}

SuspendAllThreads()
local base, rdata = FindMainModule():CodeBase(), FindMainModule():IATBase()

local printf = HEADLESS and function(...) io.write(string.format(...),"\n") end or function(...) print(string.format(...)) end
local function isMask(a, b) return bit.band(a, b) == b end

local funcs = {}

do --find function offsets by known call args
	local function nextcall(addr)
		local curAddr, t = addr
		repeat
			t = Disasm(curAddr)
			curAddr = curAddr+t.Size
		until isMask(t.CmdType, D_CALL)
		return t
	end

	local function findByArg1(arg)
		local raw = "00"..arg:gsub(".", function(c) return string.format("%02x", string.byte(c)) end).."00"
		local revaddr = string.hex(FindMemory(rdata, raw)+1):gsub("(%x)(%x)", "%2%1"):reverse()
		return nextcall(FindMemory(base, "68"..revaddr)).JmpAddress
	end

	for k, v in pairs(searches) do
		funcs[findByArg1(v[2])] = k
	end
end

local _func = {} --sentinel to mark C function pointers
local buf, maxbuf = {}, 30

local getcallargs do
	local function prevpush(curPtr)
		local pops = 0
		for i = 1, maxbuf do
			local p = math.mod(curPtr+maxbuf-i, maxbuf)
			local t = type(buf[p]) == "table" and buf[p] or Disasm(buf[p])

			if isMask(t.CmdType, D_POP) then
				pops = pops + 1
			elseif isMask(t.CmdType, D_PUSH) then
				if pops == 0 then
					return p, t
				else
					pops = pops - 1
				end
			end
		end
		error("PUSH not found in disasm buffer. Try increasing maxbuf.")
	end

	getcallargs = function (ptr, numArgs)
		local curPtr, t = ptr
		local args = {n = 0}
		for i = 1, numArgs do
			curPtr, t = prevpush(curPtr)
			local op1 = t.Operands[1]
			if isMask(op1.Argument, B_SXTCONST) then
				args[i] = op1.Constant
				args.n = i
			elseif isMask(op1.Argument, B_STRDEST) then
				local info = Memory(op1.Constant)
				if info and info.Base == rdata then
					args[i] = ReadMemoryString(op1.Constant)
				else
					args[i] = _func
				end
				args.n = i
			end
		end
		return args
	end
end

local results = {}

for k,v in pairs(searches) do
	results[k] = {}
	if v[3] then
		results[k.."_anon"] = {}
	end
end

local addr, size, ptr = base, FindMainModule():CodeSize(), 0
while addr < base+size do
	buf[ptr] = addr
	local chunk = LDE(addr)
	if chunk == 5 then
		local t = Disasm(addr)
		buf[ptr] = t
		if isMask(t.CmdType, D_CALL) then
			local name = funcs[t.JmpAddress]
			if name then
				local ret = getcallargs(ptr, searches[name][1])
				if searches[name][3] and not ret[1] then
					table.insert(results[name.."_anon"], ret)
				else
					table.insert(results[name], ret)
				end
			end
		end
	end
	ptr = math.mod(ptr+1, maxbuf)
	addr = addr+chunk
end

local function dump(name, obj, argNum)
	printf("%s = {", name)
	for _, t in ipairs(obj) do
		printf("  {")
		for i = 1, argNum do
			local v = t[i]
			if v == _func then
				printf("    nil, --C function")
			elseif type(v) == "string" then
				printf("    %q,", v)
			elseif v then
				printf("    %s,", v)
			elseif i < t.n then
				printf("    nil,")
			end
		end
		printf("  },")
	end
	printf("}")
end

local function alphabetize(a, b)  return a[1] < b[1] end

table.sort(results.CVars, alphabetize)
table.sort(results.CCmds, alphabetize)

for k, v in pairs(results) do
	dump(k, v, (searches[k] or searches[k:gsub("_anon", "")])[1])
end

if HEADLESS then os.exit(0) end
