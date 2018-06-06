#!/usr/bin/env lua

local parser = require "lua-parser.parser"
local os = require 'os'
local e, r, s

local function parse (s)
  local t,m,ast
  local t,m,ast = parser.parse(s,filename)
	if not t then
		print(m)
	end
  return t 
end

local function calcAvg (t)
	local mean = 0
	local n = #t
	for i = 1, n do 
		mean = mean + t[i]	
	end
	return mean / n
end

local function calcStdDev (t, m)
	local res = 0
	n = #t
	for i = 1, n do	
		res = res + (t[i] - m)^2		
	end
	return math.sqrt(res / n)
end

local arg = { ... }

if not arg[1] then
	print("Usage: lua [numberOfRuns] test2.lua inputFile(s)")
	return
end

local n = tonumber(arg[1])
local res = {}

if not n then
	n = 1
else
	for i=1,#arg do
		arg[i] = arg[i+1]
	end
end

for i=1, n do
	local totalTime = 0

	for i, v in ipairs(arg) do
		print(v)
		local f = io.open(v)
		s = f:read("*a")
		local t1 = os.clock()
		local r = parse(s)
		if arg[1] ~= 'alltests.lua' then 
			assert(r ~= nil)
		end
		local t2 = os.clock()
		f:close()
		totalTime = totalTime + (t2 - t1)
		print(t1, t2, totalTime)
	end
	print("Time: ", totalTime)
	table.insert(res, totalTime)
end	

table.sort(res)
local average = calcAvg(res)
local stddev = calcStdDev(res, average)

print("After running " .. n .. " times")
print("Average = ", average)
print("Median = ", res[n//2])
print("Standard deviation = ", stddev)
print("OK")
