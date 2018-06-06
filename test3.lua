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

local arg = { ... }

if not arg[1] then
	print("Usage: lua test2.lua inputFile(s)")
	return
end

local totalTime = 0

for i, v in ipairs(arg) do
	print(v)
	local f = io.open(v)
	s = f:read("*a")
	--print(s)
	local t1 = os.clock()
	local r = parse(s)
	assert(r ~= nil)
	local t2 = os.clock()
	totalTime = totalTime + (t2 - t1)
	print(t1, t2, totalTime)
end

print("Time: ", totalTime)
print("OK")
