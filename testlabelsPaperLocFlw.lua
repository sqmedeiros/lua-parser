#!/usr/bin/env lua

local parser = require "lua-parser.parser"
local pp = require "lua-parser.pp"

-- expected result, result, subject
local e, r, s

local filename = "test.lua"
local path = "./tmpdir"
local count
local label
local all = {}

local function writeFile (s)
	count = count + 1
	local name = label .. count
	local name = path .. "/err" .. name .. ".lua"
	local f, e = io.open(name, "w")
	if not f then print(e) end
	f:write(s)
	f:close() 
  if label ~= 'Extra' and not (label == 'InvalidStat' and count == 7) then 
		all[#all+1] = s
	end
end

local function parse (s)
	writeFile(s)
  local t,m,ast = parser.parse(s, filename, 'locflw')
	local r
  if not t then
    r = m
		--print("Syntax error", ast)
		--print(ast.tag)
		print("--> err" .. label .. count)
		print(s)
		print(pp.tostring(ast))
		print(r)
		print("--------------------------------------\n")
  else
    r = pp.tostring(t)
  end
  return r .. "\n"
end

assert = function (b)
	if not b then
		print("Different recovery for local follow strategy. Label: " .. label)
	end
end

-- ErrExtra
-- After the error the rest of the input is not matched
label = "Extra"
count = 0

s = [=[
return; print("hello")

print("it is already over"
]=]
e = [=[
test.lua:1:9: syntax error, unexpected character(s), expected EOF
]=]

r = parse(s)
assert(r == e)

s = [=[
while foo do if bar then baz() end end end

x = 3

y = + x
]=]
e = [=[
test.lua:1:40: syntax error, unexpected character(s), expected EOF
]=]

r = parse(s)
assert(r == e)

s = [=[
local func f()
  g()
end

x = y

y = + x 
]=]
e = [=[
test.lua:3:1: syntax error, unexpected character(s), expected EOF
]=]

r = parse(s)
assert(r == e)

s = [=[
function qux()
  if false then
    -- do
    return 0
    end
  end
  return 1
end
print(qux())
y = + x
]=]
e = [=[
test.lua:8:1: syntax error, unexpected character(s), expected EOF
]=]

r = parse(s)
assert(r == e)


-- ErrInvalidStat
label = "InvalidStat"
count = 0

s = [=[
find_solution() ? print("yes") : print("no")

x = x + y

x = + y
]=]
e = [=[
test.lua:1:17: syntax error, unexpected token, invalid start of statement
test.lua:5:5: syntax error, expected one or more expressions after '='
]=]

r = parse(s)
assert(r == e)

s = [=[
local i : int = 0

x = x + y

x = + y
]=]
e = [=[
test.lua:1:9: syntax error, unexpected token, invalid start of statement
test.lua:5:5: syntax error, expected one or more expressions after '='
]=]

r = parse(s)
assert(r == e)

s = [=[
local a = 1, b = 2

x = x + y

x = + y
]=]
e = [=[
test.lua:1:16: syntax error, unexpected token, invalid start of statement
test.lua:5:5: syntax error, expected one or more expressions after '='
]=]

r = parse(s)
assert(r == e)

s = [=[
x = -
y = 2
x = x + y

x = + y
]=]
e = [=[
test.lua:2:3: syntax error, unexpected token, invalid start of statement
test.lua:5:5: syntax error, expected one or more expressions after '='
]=]

r = parse(s)
assert(r == e)

s = [=[
obj::hello()

x = x + y

x = + y
]=]
e = [=[
test.lua:1:1: syntax error, unexpected token, invalid start of statement
test.lua:5:5: syntax error, expected one or more expressions after '='
]=]

r = parse(s)
assert(r == e)

s = [=[
while foo() do
  // not a lua comment
  bar()
end

x = x + y

x = + y
]=]
e = [=[
test.lua:2:3: syntax error, unexpected token, invalid start of statement
test.lua:8:5: syntax error, expected one or more expressions after '='
]=]

r = parse(s)
assert(r == e)

-- Recovery: two errors instead of one
s = [=[
repeat:
  action()
until condition
end

x = x + y

x = + y
]=]
e = [=[
test.lua:1:7: syntax error, unexpected token, invalid start of statement
test.lua:4:1: syntax error, unexpected character(s), expected EOF
]=]

r = parse(s)
assert(r == e)

s = [=[
function f(x)
  local result
  ... -- TODO: compute for the next result
  return result
end

x = x + y

x = + y
]=]
e = [=[
test.lua:3:3: syntax error, unexpected token, invalid start of statement
test.lua:9:5: syntax error, expected one or more expressions after '='
]=]

r = parse(s)
assert(r == e)

s = [=[
test
]=]
e = [=[
test.lua:1:1: syntax error, unexpected token, invalid start of statement
]=]

r = parse(s)
assert(r == e)

s = [=[
a, b, c

x = x + y

x = + y
]=]
e = [=[
test.lua:1:1: syntax error, unexpected token, invalid start of statement
test.lua:5:5: syntax error, expected one or more expressions after '='
]=]

r = parse(s)
assert(r == e)

s = [=[
let 

x = 2

x = x + y

x = + y
]=]
e = [=[
test.lua:1:1: syntax error, unexpected token, invalid start of statement
test.lua:7:5: syntax error, expected one or more expressions after '='
]=]

r = parse(s)
assert(r == e)

s = [=[
if p then
  f()
elif q then
  g()
  a = + b
end

x = x + y

x = + y
]=]
e = [=[
test.lua:3:1: syntax error, unexpected token, invalid start of statement
test.lua:5:7: syntax error, expected one or more expressions after '='
test.lua:10:5: syntax error, expected one or more expressions after '='
]=]

r = parse(s)
assert(r == e)

s = [=[
function foo()
  bar()
emd

x = x + y

x = + y
]=]
e = [=[
test.lua:3:1: syntax error, unexpected token, invalid start of statement
test.lua:7:5: syntax error, expected one or more expressions after '='
test.lua:8:1: syntax error, expected 'end' to close the function body
]=]

r = parse(s)
assert(r == e)

-- ErrEndIf
label = "EndIf"
count = 0

s = [=[
if 1 > 2 then print("impossible")
]=]
e = [=[
test.lua:2:1: syntax error, expected 'end' to close the if statement
]=]

r = parse(s)
assert(r == e)

s = [=[
if 1 > 2 then return; print("impossible") end

x = x + y

x = y + 
]=]
e = [=[
test.lua:1:23: syntax error, expected 'end' to close the if statement
test.lua:6:1: syntax error, expected an expression after the additive operator
]=]

r = parse(s)
assert(r == e)

s = [=[
if 1 > 2 then
  return;
  print("impossible")
end

x = x + y

x = + y
]=]
e = [=[
test.lua:3:3: syntax error, expected 'end' to close the if statement
test.lua:4:1: syntax error, unexpected character(s), expected EOF
]=]

r = parse(s)
assert(r == e)


s = [=[
if condA then doThis()
else if condB then doThat() end
]=]
e = [=[
test.lua:3:1: syntax error, expected 'end' to close the if statement
]=]

r = parse(s)
assert(r == e)

-- Recovery: two errors instead of one
s = [=[
if a then
  b()
else
  c()
else
  d()
end

x = x + y

x = + y
]=]
e = [=[
test.lua:5:1: syntax error, expected 'end' to close the if statement
test.lua:7:1: syntax error, unexpected character(s), expected EOF
]=]

r = parse(s)
assert(r == e)

-- ErrExprIf
label = "ExpIf"
count = 0

s = [=[
if then print("that") end
]=]
e = [=[
test.lua:1:4: syntax error, expected a condition after 'if'
]=]

r = parse(s)
assert(r == e)

s = [=[
if !ok then error("fail") end

x = x + y

x = + y
]=]
e = [=[
test.lua:1:4: syntax error, expected a condition after 'if'
test.lua:5:5: syntax error, expected one or more expressions after '='
]=]

r = parse(s)
assert(r == e)

-- ErrThenIf
label = "ThenIf"
count = 0

s = [=[
if age < 18
  print("too young!")
  print("really!")
end
]=]
e = [=[
test.lua:2:3: syntax error, expected 'then' after the condition
]=]

r = parse(s)
assert(r == e)

-- ErrExprEIf
label = "ExpEIf"
count = 0

s = [=[
if age < 18 then print("too young!")
elseif then print("too old") end
]=]
e = [=[
test.lua:2:8: syntax error, expected a condition after 'elseif'
]=]

r = parse(s)
assert(r == e)

-- ErrThenEIf
label = "ThenEIf"
count = 0

s = [=[
if not result then error("fail")
elseif result > 0:
  process(result)
end
]=]
e = [=[
test.lua:2:18: syntax error, expected 'then' after the condition
]=]

r = parse(s)
assert(r == e)

-- ErrEndDo
label = "EndDo"
count = 0

s = [=[
do something()
]=]
e = [=[
test.lua:2:1: syntax error, expected 'end' to close the do block
]=]

r = parse(s)
assert(r == e)

s = [=[
do
  return arr[i]
  i = i + 1
end
]=]
e = [=[
test.lua:3:3: syntax error, expected 'end' to close the do block
test.lua:4:1: syntax error, unexpected character(s), expected EOF
]=]

r = parse(s)
assert(r == e)

-- ErrExprWhile
label = "ExpWhile"
count = 0

s = [=[
while !done do done = work() end

x = + y
]=]
e = [=[
test.lua:1:7: syntax error, expected a condition after 'while'
test.lua:3:5: syntax error, expected one or more expressions after '='
]=]

r = parse(s)
assert(r == e)

s = [=[
while do print("hello again!") end
]=]
e = [=[
test.lua:1:7: syntax error, expected a condition after 'while'
]=]

r = parse(s)
assert(r == e)

-- ErrDoWhile
label = "DoWhile"
count = 0

s = [=[
while not done then work() end
]=]
e = [=[
test.lua:1:16: syntax error, expected 'do' after the condition
]=]

r = parse(s)
assert(r == e)

s = [=[
while not done
  work()
  work2()
  x = + y
end
]=]
e = [=[
test.lua:2:3: syntax error, expected 'do' after the condition
test.lua:4:7: syntax error, expected one or more expressions after '='
]=]

r = parse(s)
assert(r == e)

-- ErrEndWhile
label = "EndWhile"
count = 0

s = [=[
while not found do i = i + 1
]=]
e = [=[
test.lua:2:1: syntax error, expected 'end' to close the while loop
]=]

r = parse(s)
assert(r == e)

s = [=[
while i < #arr do
  if arr[i] == target then break
  i = i +1
end
]=]
e = [=[
test.lua:5:1: syntax error, expected 'end' to close the while loop
]=]

r = parse(s)
assert(r == e)

-- ErrUntilRep
-- Recovery: two errors instead of one
label = "UntilRep"
count = 0

s = [=[
repeat play_song()
]=]
e = [=[
test.lua:2:1: syntax error, expected 'until' at the end of the repeat loop
test.lua:2:1: syntax error, expected a condition after 'until'
]=]

r = parse(s)
assert(r == e)

-- Recovery: test only in RecoveryChoice
s = [=[
repeat play_song()
  while on_repeat
    x = x + 1
]=]
e = [=[
test.lua:3:5: syntax error, expected 'do' after the condition
test.lua:4:1: syntax error, expected 'end' to close the while loop
test.lua:4:1: syntax error, expected 'until' at the end of the repeat loop
test.lua:4:1: syntax error, expected a condition after 'until'
]=]

r = parse(s)
assert(r == e)


-- ErrExprRep
label = "ExprRep"
count = 0

s = [=[
repeat film() until end
]=]
e = [=[
test.lua:1:21: syntax error, expected a condition after 'until'
]=]

r = parse(s)
assert(r == e)

-- ErrForRange
label = "ForRange"
count = 0

s = [=[
for (key, val) in obj do
  print(key .. " -> " .. val)
  x = + y
end

x = x + y
]=]
e = [=[
test.lua:1:5: syntax error, expected a numeric or generic range after 'for'
]=]

r = parse(s)
assert(r == e)

-- ErrEndFor
label = "EndFor"
count = 0

s = [=[
for i = 1,10 do print(i)
]=]
e = [=[
test.lua:2:1: syntax error, expected 'end' to close the for loop
]=]

r = parse(s)
assert(r == e)

-- ErrExprFor1
label = "ExprFor1"
count = 0

s = [=[
for i = ,10 do print(i) end

while 1 do x = x + 1 end
]=]
e = [=[
test.lua:1:9: syntax error, expected a starting expression for the numeric range
]=]

r = parse(s)
assert(r == e)

-- ErrCommaFor
label = "CommaFor"
count = 0

s = [=[
for i = 1 to 10 do print(i) end
]=]
e = [=[
test.lua:1:11: syntax error, expected ',' to split the start and end of the range
]=]

r = parse(s)
assert(r == e)

-- ErrExprFor2
label = "ExprFor2"
count = 0

s = [=[
for i = 1, do print(i) end

while 1 do x = x + 1 end
]=]
e = [=[
test.lua:1:12: syntax error, expected an ending expression for the numeric range
]=]

r = parse(s)
assert(r == e)

-- ErrExprFor3
label = "ExprFor3"
count = 0

s = [=[
for i = 1,10, do print(i) end

while 1 do x = x + 1 end
]=]
e = [=[
test.lua:1:15: syntax error, expected a step expression for the numeric range after ','
]=]

r = parse(s)
assert(r == e)

-- ErrInFor
label = "InFor"
count = 0

s = [=[
for arr do print(arr[i]) end
]=]
e = [=[
test.lua:1:9: syntax error, expected '=' or 'in' after the variable(s)
test.lua:1:9: syntax error, expected one or more expressions after 'in'
]=]

r = parse(s)
assert(r == e)

s = [=[
for nums := 1,10 do print(i) end
]=]
e = [=[
test.lua:1:10: syntax error, expected '=' or 'in' after the variable(s)
]=]

r = parse(s)
assert(r == e)

-- ErrEListFor
label = "EListFor"
count = 0

s = [=[
for i in ? do print(i) end
]=]
e = [=[
test.lua:1:10: syntax error, expected one or more expressions after 'in'
]=]

r = parse(s)
assert(r == e)

-- ErrDoFor
label = "DoFor"
count = 0

s = [=[
for i = 1,10 doo print(i) x = x + 1 end
]=]
e = [=[
test.lua:1:14: syntax error, expected 'do' after the range of the for loop
]=]

r = parse(s)
assert(r == e)

s = [=[
for _, elem in ipairs(list)
  print(elem)
  print(_)
end
]=]
e = [=[
test.lua:2:3: syntax error, expected 'do' after the range of the for loop
]=]

r = parse(s)
assert(r == e)

-- ErrDefLocal
label = "DefLocal"
count = 0

s = [=[
local
]=]
e = [=[
test.lua:2:1: syntax error, expected a function definition or assignment after 'local'
]=]

r = parse(s)
assert(r == e)

s = [=[
local; x = 2
]=]
e = [=[
test.lua:1:6: syntax error, expected a function definition or assignment after 'local'
]=]

r = parse(s)
assert(r == e)

s = [=[
local *p = nil

x = x + 1
]=]
e = [=[
test.lua:1:7: syntax error, expected a function definition or assignment after 'local'
]=]

r = parse(s)
assert(r == e)

-- ErrNameLFunc
label = "NameLFunc"
count = 0

s = [=[
local function() return 0 end
]=]
e = [=[
test.lua:1:15: syntax error, expected a function name after 'function'
]=]

r = parse(s)
assert(r == e)

s = [=[
local function 3dprint(x, y, z) end
]=]
e = [=[
test.lua:1:16: syntax error, expected a function name after 'function'
]=]

r = parse(s)
assert(r == e)

s = [=[
local function repeat(f, ntimes) for i = 1,ntimes do f() end end
]=]
e = [=[
test.lua:1:16: syntax error, expected a function name after 'function'
]=]

r = parse(s)
assert(r == e)

-- ErrEListLAssign
label = "EListLAssign"
count = 0

s = [=[
local x = ? 3
]=]
e = [=[
test.lua:1:11: syntax error, expected one or more expressions after '='
]=]

r = parse(s)
assert(r == e)

-- ErrEListAssign
label = "EListAssign"
count = 0

s = [=[
x = 
]=]
e = [=[
test.lua:2:1: syntax error, expected one or more expressions after '='
]=]

r = parse(s)
assert(r == e)

-- ErrFuncName
label = "FuncName"
count = 0

s = [=[
function() return 0 end
]=]
e = [=[
test.lua:1:9: syntax error, expected a function name after 'function'
]=]

r = parse(s)
assert(r == e)

s = [=[
function 3dprint(x, y, z) end
]=]
e = [=[
test.lua:1:10: syntax error, expected a function name after 'function'
]=]

r = parse(s)
assert(r == e)

s = [=[
function repeat(f, ntimes) for i = 1,ntimes do f() end end
]=]
e = [=[
test.lua:1:10: syntax error, expected a function name after 'function'
]=]

r = parse(s)
assert(r == e)

-- ErrNameFunc1
-- TODO: it is generating an empty capture before the capture
-- associated with the recovery pattern
-- It seems the "nil" capture is generated by "throw",
-- since the following pattern generates a "nil" after "ponto"
-- and before the capture associated with the recovery pattern
-- Cf(V"Id" * ((sym(".") / "ponto") * throw("NameFunc1")  )^0,
-- Strange... 
-- Partial solution was to add a condition in "insertIndex"
label = "NameFunc1"
count = 0

s = [=[
function foo.() end
x = 2
y = 3
]=]
e = [=[
test.lua:1:14: syntax error, expected a function name after '.'
]=]

r = parse(s)
assert(r == e)

s = [=[
function foo.1() end
]=]
e = [=[
test.lua:1:14: syntax error, expected a function name after '.'
]=]

r = parse(s)
assert(r == e)

-- ErrNameFunc2
label = "NameFunc2"
count = 0

s = [=[
function foo:() end
]=]
e = [=[
test.lua:1:14: syntax error, expected a method name after ':'
]=]

r = parse(s)
assert(r == e)

s = [=[
function foo:1() end
]=]
e = [=[
test.lua:1:14: syntax error, expected a method name after ':'
]=]

r = parse(s)
assert(r == e)

-- ErrOParenPList
label = "OParenPList"
count = 0

s = [=[
function foo
  bar = 42
  b = bar + 1
  y = y + 2
  return bar
end
]=]
e = [=[
test.lua:2:3: syntax error, expected '(' for the parameter list
test.lua:3:5: syntax error, expected ')' to close the parameter list
]=]

r = parse(s)
assert(r == e)

s = [=[
function foo?(bar)
  return bar
end
]=]
e = [=[
test.lua:1:13: syntax error, expected '(' for the parameter list
]=]

r = parse(s)
assert(r == e)

-- ErrCParenPList
label = "CParenPList"
count = 0

s = [=[
function foo(bar
  return bar
end
]=]
e = [=[
test.lua:2:3: syntax error, expected ')' to close the parameter list
]=]

r = parse(s)
assert(r == e)

s = [=[
function foo(bar; baz)
  return bar
end
]=]
e = [=[
test.lua:1:17: syntax error, expected ')' to close the parameter list
]=]

r = parse(s)
assert(r == e)

s = [=[
function foo(a, b, ...rest) return 42 end
]=]
e = [=[
test.lua:1:23: syntax error, expected ')' to close the parameter list
]=]

r = parse(s)
assert(r == e)

-- ErrEndFunc
label = "EndFunc"
count = 0

s = [=[
function foo(bar)
  return bar
]=]
e = [=[
test.lua:3:1: syntax error, expected 'end' to close the function body
]=]

r = parse(s)
assert(r == e)

s = [=[
function foo() do
  bar()
end
]=]
e = [=[
test.lua:4:1: syntax error, expected 'end' to close the function body
]=]

r = parse(s)
assert(r == e)

-- ErrParList
label = "ParList"
count = 0

s = [=[
function foo(bar, baz,)
  return bar
end
]=]
e = [=[
test.lua:1:23: syntax error, expected a variable name or '...' after ','
]=]

r = parse(s)
assert(r == e)

-- ErrLabel
label = "Label"
count = 0

s = [=[
::1::

x = x + 1
]=]
e = [=[
test.lua:1:3: syntax error, expected a label name after '::'
]=]

r = parse(s)
assert(r == e)

-- ErrCloseLabel
label = "CloseLabel"
count = 0

s = [=[
::loop

x = x + 1
]=]
e = [=[
test.lua:3:1: syntax error, expected '::' after the label
]=]

r = parse(s)
assert(r == e)

-- ErrGoto
label = "Goto"
count = 0

s = [=[
goto; x = x + 1
]=]
e = [=[
test.lua:1:5: syntax error, expected a label after 'goto'
]=]

r = parse(s)
assert(r == e)

s = [=[
goto 1
x = x + 1
]=]
e = [=[
test.lua:1:6: syntax error, expected a label after 'goto'
]=]

r = parse(s)
assert(r == e)

-- ErrRetList
label = "RetList"
count = 0

s = [=[
return a, b, 
]=]
e = [=[
test.lua:2:1: syntax error, expected an expression after ',' in the return statement
]=]

r = parse(s)
assert(r == e)

s = [=[
function f ()
  return a, b, 
end
x = x + 1
y = y + 2
]=]
e = [=[
test.lua:3:1: syntax error, expected an expression after ',' in the return statement
test.lua:4:1: syntax error, expected 'end' to close the function body
]=]

r = parse(s)
assert(r == e)

-- ErrVarList
label = "VarList"
count = 0

s = [=[
x, y, = 0, 0
]=]
e = [=[
test.lua:1:7: syntax error, expected a variable name after ','
]=]

r = parse(s)
assert(r == e)

-- ErrExprList
label = "ExprList"
count = 0

s = [=[
x, y = 0, 0,
]=]
e = [=[
test.lua:2:1: syntax error, expected an expression after ','
]=]

r = parse(s)
assert(r == e)

-- ErrOrExpr
label = "OrExpr"
count = 0

s = [=[
foo(a or)
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after 'or'
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a or $b
]=]
e = [=[
test.lua:1:10: syntax error, expected an expression after 'or'
]=]

r = parse(s)
assert(r == e)

-- ErrAndExpr
label = "AndExpr"
count = 0

s = [=[
foo(a and)
]=]
e = [=[
test.lua:1:10: syntax error, expected an expression after 'and'
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a and $b
]=]
e = [=[
test.lua:1:11: syntax error, expected an expression after 'and'
]=]

r = parse(s)
assert(r == e)

-- ErrRelExpr
label = "RelExpr"
count = 0

s = [=[
foo(a <)
]=]
e = [=[
test.lua:1:8: syntax error, expected an expression after the relational operator
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a < $b
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after the relational operator
]=]

r = parse(s)
assert(r == e)

s = [=[
foo(a <=)
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after the relational operator
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a <= $b
]=]
e = [=[
test.lua:1:10: syntax error, expected an expression after the relational operator
]=]

r = parse(s)
assert(r == e)

s = [=[
foo(a >)
]=]
e = [=[
test.lua:1:8: syntax error, expected an expression after the relational operator
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a > $b
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after the relational operator
]=]

r = parse(s)
assert(r == e)

s = [=[
foo(a >=)
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after the relational operator
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a >= $b
]=]
e = [=[
test.lua:1:10: syntax error, expected an expression after the relational operator
]=]

r = parse(s)
assert(r == e)

s = [=[
foo(a ==)
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after the relational operator
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a == $b
]=]
e = [=[
test.lua:1:10: syntax error, expected an expression after the relational operator
]=]

r = parse(s)
assert(r == e)

s = [=[
foo(a ~=)
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after the relational operator
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a ~= $b
]=]
e = [=[
test.lua:1:10: syntax error, expected an expression after the relational operator
]=]

r = parse(s)
assert(r == e)

-- ErrBOrExpr
label = "BOrExpr"
count = 0

s = [=[
foo(a |)
]=]
e = [=[
test.lua:1:8: syntax error, expected an expression after '|'
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a | $b
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after '|'
]=]

r = parse(s)
assert(r == e)

-- ErrBXorExpr
label = "BXorExpr"
count = 0

s = [=[
foo(a ~)
]=]
e = [=[
test.lua:1:8: syntax error, expected an expression after '~'
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a ~ $b
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after '~'
]=]

r = parse(s)
assert(r == e)

-- ErrBAndExpr
label = "BAndExpr"
count = 0

s = [=[
foo(a &)
]=]
e = [=[
test.lua:1:8: syntax error, expected an expression after '&'
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a & $b
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after '&'
]=]

r = parse(s)
assert(r == e)

-- ErrShiftExpr
label = "ShiftExpr"
count = 0

s = [=[
foo(a >>)
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after the bit shift
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a >> $b
]=]
e = [=[
test.lua:1:10: syntax error, expected an expression after the bit shift
]=]

r = parse(s)
assert(r == e)

s = [=[
foo(a <<)
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after the bit shift
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a >> $b
]=]
e = [=[
test.lua:1:10: syntax error, expected an expression after the bit shift
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a >>> b
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after the bit shift
]=]

r = parse(s)
assert(r == e)

-- ErrConcatExpr
label = "ConcatExpr"
count = 0

s = [=[
foo(a ..)
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after '..'
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a .. $b
]=]
e = [=[
test.lua:1:10: syntax error, expected an expression after '..'
]=]

r = parse(s)
assert(r == e)

-- ErrAddExpr
label = "AddExpr"
count = 0

s = [=[
foo(a +, b)
]=]
e = [=[
test.lua:1:8: syntax error, expected an expression after the additive operator
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a + $b
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after the additive operator
]=]

r = parse(s)
assert(r == e)

s = [=[
foo(a -, b)
]=]
e = [=[
test.lua:1:8: syntax error, expected an expression after the additive operator
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a - $b
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after the additive operator
]=]

r = parse(s)
assert(r == e)

--TODO: study this example
-- the error is thrown, the parser backtracks, the same error is thrown, grammar backtracks
-- and then a different error is thrown
-- FIXED: reset 'syntaxerr' in the match time capture of FuncCall and VarExpr 
-- Recovery: two errors instead of one
s = [=[
arr[i++]
]=]
e = [=[
test.lua:1:7: syntax error, expected an expression after the additive operator
test.lua:1:1: syntax error, unexpected token, invalid start of statement
]=]

r = parse(s)
assert(r == e)

-- ErrMulExpr
label = "MulExpr"
count = 0

s = [=[
foo(b, a *)
]=]
e = [=[
test.lua:1:11: syntax error, expected an expression after the multiplicative operator
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a * $b
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after the multiplicative operator
]=]

r = parse(s)
assert(r == e)

s = [=[
foo(b, a /)
]=]
e = [=[
test.lua:1:11: syntax error, expected an expression after the multiplicative operator
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a / $b
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after the multiplicative operator
]=]

r = parse(s)
assert(r == e)

s = [=[
foo(b, a //)
]=]
e = [=[
test.lua:1:12: syntax error, expected an expression after the multiplicative operator
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a // $b
]=]
e = [=[
test.lua:1:10: syntax error, expected an expression after the multiplicative operator
]=]

r = parse(s)
assert(r == e)

s = [=[
foo(b, a %)
]=]
e = [=[
test.lua:1:11: syntax error, expected an expression after the multiplicative operator
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a % $b
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after the multiplicative operator
]=]

r = parse(s)
assert(r == e)

-- ErrUnaryExpr
label = "UnaryExpr"
count = 0

s = [=[
x, y = a + not, b
]=]
e = [=[
test.lua:1:15: syntax error, expected an expression after the unary operator
]=]

r = parse(s)
assert(r == e)

s = [=[
x, y = a + -, b
]=]
e = [=[
test.lua:1:13: syntax error, expected an expression after the unary operator
]=]

r = parse(s)
assert(r == e)

s = [=[
x, y = a + #, b
]=]
e = [=[
test.lua:1:13: syntax error, expected an expression after the unary operator
]=]

r = parse(s)
assert(r == e)

s = [=[
x, y = a + ~, b
]=]
e = [=[
test.lua:1:13: syntax error, expected an expression after the unary operator
]=]

r = parse(s)
assert(r == e)

-- ErrPowExpr
label = "PowExpr"
count = 0

s = [=[
foo(a ^)
]=]
e = [=[
test.lua:1:8: syntax error, expected an expression after '^'
]=]

r = parse(s)
assert(r == e)

s = [=[
foo(b, a ^)
]=]
e = [=[
test.lua:1:11: syntax error, expected an expression after '^'
]=]

r = parse(s)
assert(r == e)

s = [=[
x = a ^ $b
]=]
e = [=[
test.lua:1:9: syntax error, expected an expression after '^'
]=]

r = parse(s)
assert(r == e)


-- ErrExprParen
label = "ExprParen"
count = 0

s = [=[
x = ()
]=]
e = [=[
test.lua:1:6: syntax error, expected an expression after '('
]=]

r = parse(s)
assert(r == e)

s = [=[
y = (???)
]=]
e = [=[
test.lua:1:6: syntax error, expected an expression after '('
]=]

r = parse(s)
assert(r == e)

-- ErrCParenExpr
label = "CParenExpr"
count = 0

s = [=[
z = a*(b+c
]=]
e = [=[
test.lua:2:1: syntax error, expected ')' to close the expression
]=]

r = parse(s)
assert(r == e)

-- Recovery: two errors instead of one
s = [=[
w = (0xBV)

x = x + 1
]=]
e = [=[
test.lua:1:9: syntax error, expected ')' to close the expression
test.lua:1:9: syntax error, unexpected token, invalid start of statement
]=]

r = parse(s)
assert(r == e)

s = [=[
ans = 2^(m*(n-1)
]=]
e = [=[
test.lua:2:1: syntax error, expected ')' to close the expression
]=]

r = parse(s)
assert(r == e)

-- ErrNameIndex
label = "NameIndex"
count = 0

s = [=[
f = t.
]=]
e = [=[
test.lua:2:1: syntax error, expected a field name after '.'
]=]

r = parse(s)
assert(r == e)

s = [=[
f = t.['f']
]=]
e = [=[
test.lua:1:7: syntax error, expected a field name after '.'
]=]

r = parse(s)
assert(r == e)

--TODO: error similar to the example 
--s = [=[
--arr[i++]
--]=]
-- see also "analisar.txt"
-- FIXED
-- Recovery: two errors instead of one
s = [=[
x.
]=]

e = [=[
test.lua:2:1: syntax error, expected a field name after '.'
test.lua:1:1: syntax error, unexpected token, invalid start of statement
]=]

r = parse(s)
assert(r == e)

-- ErrExprIndex
label = "ExprIndex"
count = 0

s = [=[
f = t[]
]=]
e = [=[
test.lua:1:7: syntax error, expected an expression after '['
]=]

r = parse(s)
assert(r == e)

s = [=[
f = t[?]
]=]
e = [=[
test.lua:1:7: syntax error, expected an expression after '['
]=]

r = parse(s)
assert(r == e)

-- ErrCBracketIndex
label = "CBracketIndex"
count = 0

s = [=[
f = t[x[y]

x = x + 1
]=]
e = [=[
test.lua:3:1: syntax error, expected ']' to close the indexing expression
]=]

r = parse(s)
assert(r == e)

-- Recovery: two errors instead of one
s = [=[
f = t[x,y]

x = x + 1
]=]
e = [=[
test.lua:1:8: syntax error, expected ']' to close the indexing expression
test.lua:1:10: syntax error, unexpected token, invalid start of statement
]=]

r = parse(s)
assert(r == e)

-- TODO: see example arr[i++]
-- FIXED
-- Recovery: two errors instead of one 
s = [=[
arr[i--]

x = y + 1
]=]
e = [=[
test.lua:3:1: syntax error, expected ']' to close the indexing expression
test.lua:1:1: syntax error, unexpected token, invalid start of statement
]=]

r = parse(s)
assert(r == e)

-- ErrNameMeth
label = "NameMeth"
count = 0

-- Recovery: two errors instead of one 
s = [=[
x = obj:
]=]
e = [=[
test.lua:2:1: syntax error, expected a method name after ':'
test.lua:2:1: syntax error, expected some arguments for the method call (or '()')
]=]

r = parse(s)
assert(r == e)

-- Recovery: two errors instead of one 
s = [=[
x := 0
x = x + 1
y = y * 2
]=]
e = [=[
test.lua:1:4: syntax error, expected a method name after ':'
test.lua:2:1: syntax error, expected some arguments for the method call (or '()')
]=]

r = parse(s)
assert(r == e)

-- ErrMethArgs
label = "MethArgs"
count = 0

s = [=[
cow:moo
]=]
e = [=[
test.lua:2:1: syntax error, expected some arguments for the method call (or '()')
]=]

r = parse(s)
assert(r == e)

s = [=[
dog:bark msg
]=]
e = [=[
test.lua:1:10: syntax error, expected some arguments for the method call (or '()')
]=]

r = parse(s)
assert(r == e)

s = [=[
duck:quack[4]
x = x + 1
]=]
e = [=[
test.lua:1:11: syntax error, expected some arguments for the method call (or '()')
]=]

r = parse(s)
assert(r == e)

s = [=[
local t = {
  x = X:
  y = Y;
}
z = z + 1
]=]
e = [=[
test.lua:3:5: syntax error, expected some arguments for the method call (or '()')
]=]

r = parse(s)
assert(r == e)

-- ErrArgList
label = "ArgList"
count = 0

s = [=[
foo(a, b, )
]=]
e = [=[
test.lua:1:11: syntax error, expected an expression after ',' in the argument list
]=]

r = parse(s)
assert(r == e)

s = [=[
foo(a, b, ..)
]=]
e = [=[
test.lua:1:11: syntax error, expected an expression after ',' in the argument list
]=]

r = parse(s)
assert(r == e)

-- ErrCParenArgs
label = "CParenArgs"
count = 0

s = [=[
foo(a + (b - c)
]=]
e = [=[
test.lua:2:1: syntax error, expected ')' to close the argument list
]=]

r = parse(s)
assert(r == e)

-- Recovery: two errors instead of one
s = [=[
foo(arg1 arg2)
x = x + 1
y = y * 2
]=]
e = [=[
test.lua:1:10: syntax error, expected ')' to close the argument list
test.lua:1:10: syntax error, unexpected token, invalid start of statement
]=]

r = parse(s)
assert(r == e)

-- ErrCBraceTable
label = "CBraceTable"
count = 0

-- Recovery: two errors instead of one
s = [=[
nums = {1, 2, 3]
]=]
e = [=[
test.lua:1:16: syntax error, expected '}' to close the table constructor
test.lua:1:16: syntax error, unexpected token, invalid start of statement
]=]

r = parse(s)
assert(r == e)

-- Recovery: three errors instead of one
s = [=[
t = { , }
x = x + 1
y = y + 2
]=]
e = [=[
test.lua:1:7: syntax error, expected '}' to close the table constructor
test.lua:1:9: syntax error, expected an expression after ','
test.lua:1:9: syntax error, unexpected token, invalid start of statement
]=]

r = parse(s)
assert(r == e)


-- Recovery: two errors instead of one
s = [=[
nums = {
  one = 1;
  two = 2
  three = 3;
  four = 4
}
]=]
e = [=[
test.lua:4:3: syntax error, expected '}' to close the table constructor
test.lua:6:1: syntax error, unexpected token, invalid start of statement
]=]

r = parse(s)
assert(r == e)

-- ErrEqField
label = "EqField"
count = 0

s = [=[
words2nums = { ['one'] -> 1 }
]=]
e = [=[
test.lua:1:24: syntax error, expected '=' after the table key
]=]

r = parse(s)
assert(r == e)

-- ErrExprField
label = "ExprField"
count = 0

s = [=[
words2nums = { ['one'] => 2 }
x = x + 1
]=]
e = [=[
test.lua:1:25: syntax error, expected an expression after '='
]=]

r = parse(s)
assert(r == e)

-- ErrExprFKey
label = "ExprFKey"
count = 0

s = [=[
table = { [] = value }
]=]
e = [=[
test.lua:1:12: syntax error, expected an expression after '[' for the table key
]=]

r = parse(s)
assert(r == e)

-- ErrCBracketFKey
label = "CBracketFKey"
count = 0

s = [=[
table = { [key = value }
]=]
e = [=[
test.lua:1:16: syntax error, expected ']' to close the table key
]=]

r = parse(s)
assert(r == e)


-- ErrDigitHex
label = "DigitHex"
count = 0

s = [=[
print(0x)
]=]
e = [=[
test.lua:1:9: syntax error, expected one or more hexadecimal digits after '0x'
]=]

r = parse(s)
assert(r == e)

s = [=[
print(0xGG)
]=]
e = [=[
test.lua:1:9: syntax error, expected one or more hexadecimal digits after '0x'
]=]

r = parse(s)
assert(r == e)

-- ErrDigitDeci
label = "DigitDeci"
count = 0

s = [=[
print(1 + . 0625)
]=]
e = [=[
test.lua:1:12: syntax error, expected one or more digits after the decimal point
]=]

r = parse(s)
assert(r == e)

s = [=[
print(.)
]=]
e = [=[
test.lua:1:8: syntax error, expected one or more digits after the decimal point
]=]

r = parse(s)
assert(r == e)

-- ErrDigitExpo
label = "DigitExpo"
count = 0

s = [=[
print(1.0E)
]=]
e = [=[
test.lua:1:11: syntax error, expected one or more digits for the exponent
]=]

r = parse(s)
assert(r == e)

s = [=[
print(3E)
]=]
e = [=[
test.lua:1:9: syntax error, expected one or more digits for the exponent
]=]

r = parse(s)
assert(r == e)

-- ErrQuote
label = "Quote"
count = 0

s = [=[
local message = "Hello
]=]
e = [=[
test.lua:2:1: syntax error, unclosed string
]=]

r = parse(s)
assert(r == e)

s = [=[
local message = "*******
Welcome
*******"
x = x + 1
y = y + 2
]=]
e = [=[
test.lua:2:1: syntax error, unclosed string
test.lua:2:1: syntax error, unexpected token, invalid start of statement
test.lua:3:1: syntax error, unexpected token, invalid start of statement
]=]

r = parse(s)
assert(r == e)

s = [=[
local message = 'Hello
]=]
e = [=[
test.lua:2:1: syntax error, unclosed string
]=]

r = parse(s)
assert(r == e)

s = [=[
local message = '*******
Welcome
*******'
x = x + 1
y = y + 2
]=]
e = [=[
test.lua:2:1: syntax error, unclosed string
test.lua:2:1: syntax error, unexpected token, invalid start of statement
test.lua:3:1: syntax error, unexpected token, invalid start of statement
]=]

r = parse(s)
assert(r == e)

-- ErrHexEsc
label = "HexEsc"
count = 0

s = [=[
print("\x")
]=]
e = [=[
test.lua:1:10: syntax error, expected exactly two hexadecimal digits after '\x'
]=]

r = parse(s)
assert(r == e)

s = [=[
print("\xF")
]=]
e = [=[
test.lua:1:10: syntax error, expected exactly two hexadecimal digits after '\x'
]=]

r = parse(s)
assert(r == e)

s = [=[
print("\xG")
]=]
e = [=[
test.lua:1:10: syntax error, expected exactly two hexadecimal digits after '\x'
]=]

r = parse(s)
assert(r == e)

-- ErrOBraceUEsc
label = "OBraceUEsc"
count = 0

--FIXED: put an extra condition in buildRecG to not capture anything
--when this label is thrown (update: does not need an extra condition,
-- some labels do not capture anything)
s = [=[
print("\u3D")
]=]
e = [=[
test.lua:1:10: syntax error, expected '{' after '\u'
test.lua:1:12: syntax error, expected '}' after the code point
]=]

r = parse(s)
assert(r == e)

-- ErrDigitUEsc
label = "DigitUEsc"
count = 0

s = [=[
print("\u{}")
]=]
e = [=[
test.lua:1:11: syntax error, expected one or more hexadecimal digits for the UTF-8 code point
]=]

r = parse(s)
assert(r == e)

s = [=[
print("\u{XD}")
]=]
e = [=[
test.lua:1:11: syntax error, expected one or more hexadecimal digits for the UTF-8 code point
]=]

r = parse(s)
assert(r == e)

-- ErrCBraceUEsc
label = "CBraceUEsc"
count = 0

s = [=[
print("\u{0x3D}")
x = x + 1
]=]
e = [=[
test.lua:1:12: syntax error, expected '}' after the code point
]=]

r = parse(s)
assert(r == e)

s = [=[
print("\u{FFFF Hi")
x = x + 1
]=]
e = [=[
test.lua:1:15: syntax error, expected '}' after the code point
]=]

r = parse(s)
assert(r == e)

-- ErrEscSeq
label = "EscSeq"
count = 0

s = [=[
print("\m")
]=]
e = [=[
test.lua:1:9: syntax error, invalid escape sequence
]=]

r = parse(s)
assert(r == e)

-- ErrCloseLStr
label = "CloseLStr"
count = 0

s = [===[
local message = [==[
    *******
    WELCOME
    *******
]=]
]===]
e = [=[
test.lua:6:1: syntax error, unclosed long string
]=]

r = parse(s)
assert(r == e)



print("> testing lexer...")

-- unfinished comments
s = [=[
--[[ testing
unfinished
comment
]=]
e = [=[
test.lua:4:1: syntax error, unclosed long string
]=]

r = parse(s)
assert(r == e)


print("> testing parser...")

label = "Misc"
count = 0
-- syntax error

-- anonymous functions

-- Recovery: two errors instead of one
s = [=[
if a then
  return a
elseif b then
  return b
elseif

end
]=]
e = [=[
test.lua:7:1: syntax error, expected a condition after 'elseif'
test.lua:7:1: syntax error, expected 'then' after the condition
]=]

r = parse(s)
assert(r == e)

local f, e = io.open("alltests.lua", "w")
if not f then print(e) end
f:write(table.concat(all, "\n"))
f:close() 

print("OK")
