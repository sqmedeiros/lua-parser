--[[
This module implements a parser for Lua 5.3 with LPeg,
and generates an Abstract Syntax Tree in the Metalua format.
For more information about Metalua, please, visit:
https://github.com/fab13n/metalua-parser

block: { stat* }

stat:
    `Do{ stat* }
  | `Set{ {lhs+} {expr+} }                    -- lhs1, lhs2... = e1, e2...
  | `While{ expr block }                      -- while e do b end
  | `Repeat{ block expr }                     -- repeat b until e
  | `If{ (expr block)+ block? }               -- if e1 then b1 [elseif e2 then b2] ... [else bn] end
  | `Fornum{ ident expr expr expr? block }    -- for ident = e, e[, e] do b end
  | `Forin{ {ident+} {expr+} block }          -- for i1, i2... in e1, e2... do b end
  | `Local{ {ident+} {expr+}? }               -- local i1, i2... = e1, e2...
  | `Localrec{ ident expr }                   -- only used for 'local function'
  | `Goto{ <string> }                         -- goto str
  | `Label{ <string> }                        -- ::str::
  | `Return{ <expr*> }                        -- return e1, e2...
  | `Break                                    -- break
  | apply

expr:
    `Nil
  | `Dots
  | `True
  | `False
  | `Number{ <number> }
  | `String{ <string> }
  | `Function{ { `Id{ <string> }* `Dots? } block }
  | `Table{ ( `Pair{ expr expr } | expr )* }
  | `Op{ opid expr expr? }
  | `Paren{ expr }       -- significant to cut multiple values returns
  | apply
  | lhs

apply:
    `Call{ expr expr* }
  | `Invoke{ expr `String{ <string> } expr* }

lhs: `Id{ <string> } | `Index{ expr expr }

opid:  -- includes additional operators from Lua 5.3
    'add'  | 'sub' | 'mul'  | 'div'
  | 'idiv' | 'mod' | 'pow'  | 'concat'
  | 'band' | 'bor' | 'bxor' | 'shl' | 'shr'
  | 'eq'   | 'lt'  | 'le'   | 'and' | 'or'
  | 'unm'  | 'len' | 'bnot' | 'not'
]]

local lpeg = require "lpeglabel"
local re = require "relabel"

lpeg.locale(lpeg)

local P, S, V = lpeg.P, lpeg.S, lpeg.V
local C, Carg, Cb, Cc = lpeg.C, lpeg.Carg, lpeg.Cb, lpeg.Cc
local Cf, Cg, Cmt, Cp, Cs, Ct = lpeg.Cf, lpeg.Cg, lpeg.Cmt, lpeg.Cp, lpeg.Cs, lpeg.Ct
local Rec, T = lpeg.Rec, lpeg.T

local alpha, digit, alnum = lpeg.alpha, lpeg.digit, lpeg.alnum
local xdigit = lpeg.xdigit
local space = lpeg.space

local any = P(1)

local cursubject
local syntaxerrs
local nerrors

-- patterns defined here are used for error recovery
local function sync (psync, pend, pinit)
	local p
	if pinit then
		p = pinit^-1 * (-psync * any)^0
	else
		p = (-psync * any)^0
	end	
	if pend then
		p = p * pend
	end
	return p * space^0
end

local blockEnd = space^0 * (P"return" + "end" + "elseif" + "else" + "until" + -1)

local keywords  = P"and" + "break" + "do" + "elseif" + "else" + "end"
                + "false" + "for" + "function" + "goto" + "if" + "in"
                + "local" + "nil" + "not" + "or" + "repeat" + "return"
                + "then" + "true" + "until" + "while"

local idStart   = alpha + P"_"
local idRest    = alnum + P"_"
local ident     = idStart * idRest^0
local reserved  = keywords * -idRest

local function kw2 (str)
  return P(str) * -idRest
end


local firstStmt = kw2'if' + kw2'while' + kw2'do' + kw2'for' + kw2'repeat' + 
                            kw2'local' + kw2'function' + kw2'break' + P"::" * ident * "::"  +
                            ident + kw2'goto' + ';'

local firstBlock = firstStmt + kw2'return'

local flwBlock = -any + kw2'elseif' + kw2'else' + kw2'end' +  kw2'until'

local flwExp = kw2'then' + kw2'do' + firstBlock + ',' + flwBlock +
                 ')' + ']' + '}' +
                'or' + 'and' + '~=' + '==' + '<=' + '>=' + '<' + '>' + '|' + '~' + '&' + '<<' + '>>' + 
                '..' + '+' + '-' + '*' + '//' + '/' + '%' + '^'

local firstExp = kw2'not' + '-' + '#' + '~' + xdigit + '"' + kw2'nil' +
                 kw2'false' + kw2'true' + '...' + kw2'function' + '{' + ident

local flwName = P'(' + ',' + '::' + firstBlock + '=' + 'in' + '.' + ':' + '(' + '[' + '{' + flwExp

local flwExprList = firstBlock

local flwOPar = ident + ')' + '...' + firstExp

local flwCPar = firstBlock + '.' + '[' + ':' + '(' + '{' + '"' + "'" + ']' + 'or' +
                'and' + '~=' + '==' + '<=' + '>=' + '<' + '>' + '|' + '~' + '&' + '<<' + '>>' + 
                '..' + '+' + '-' + '*' + '//' + '/' + '%' + '^' + ')' 
 
local flwEnd = firstBlock + flwExp


local psyncExp = sync(P"\n" + ")" + "]" + ",")

local dummyStr = { tag = "String", pos = 0, [1] = "<Dummy>" }
local dummyId = { tag = "Id", pos = 0, [1] = "<Dummy>" }
local dummyNum = { tag = "Number", pos = 0, [1] = 42 }
local dummyExpr = dummyStr
local dummyEList = { tag = "ExpList", pos = 0, [1] = dummyExpr}
local dummyEList2 = { tag = "ExpList", pos = 44, [1] = dummyNum}
local dummyBlock = { tag = "Block", pos = 0, } 
local dummyVarList = { tag = "Block", pos = 0, } 
local dummyForRange = { tag = "Forin", pos = 0, [1] = {}, [2] = dummyEList, [3] = dummyBlock }


-- error message auxiliary functions

local labels = {
  { "ErrExtra", "unexpected character(s), expected EOF", flw = -any, locflw = -any },
  { "ErrInvalidStat", "unexpected token, invalid start of statement", sync(P"\n" + ";"), flw = firstStmt, flw2 = ident, locflw = firstStmt },

  { "ErrEndIf", "expected 'end' to close the if statement", sync(P"\n" + ";"), flw = firstBlock, locflw = firstBlock }, --TODO: synchronize with "if", "while", "repeat"...
  { "ErrExprIf", "expected a condition after 'if'", sync(kw2"then" + "\n" + kw2"end"), dummyExpr, flw = flwExp, locflw = kw2"then"  },
  --{ "ErrThenIf", "expected 'then' after the condition", sync(P"\n" + kw2"end") }, --TODO: synchronize with the start of a statement
  { "ErrThenIf", "expected 'then' after the condition", sync(idStart + "\n"), flw = firstBlock + kw2'end', locflw = firstBlock + kw2'end'},
  { "ErrExprEIf", "expected a condition after 'elseif'", sync(kw2"then" + "\n" + kw2"end"), flw = flwExp, locflw = kw2'then' },
  --{ "ErrThenEIf", "expected 'then' after the condition", sync(P"\n" + kw2"end")},
  { "ErrThenEIf", "expected 'then' after the condition", sync(idStart + "\n"), flw = firstBlock + kw2'end', locflw = firstBlock + kw2'end' },

  { "ErrEndDo", "expected 'end' to close the do block", sync(P"\n" + ";"), flw = firstBlock, locflw = firstBlock },
  { "ErrExprWhile", "expected a condition after 'while'", sync(kw2"do" + "\n" + kw2"end"), dummyExpr, flw = flwExp, locflw = kw2'do' }, 
  { "ErrDoWhile", "expected 'do' after the condition", sync(P"\n" + kw2"end"), flw = firstBlock + kw2'end', locflw = firstBlock + kw2'end' },
  { "ErrEndWhile", "expected 'end' to close the while loop", sync(P"\n" + ";"), flw = firstBlock, locflw = firstBlock },
  { "ErrUntilRep", "expected 'until' at the end of the repeat loop", sync(P"\n" + digit + ident + ";"), flw = firstExp, locflw = firstExp },
  { "ErrExprRep", "expected a condition after 'until'", sync(P"\n"), dummyExpr, flw = flwExp, locflw = flwExp },

  { "ErrForRange", "expected a numeric or generic range after 'for'", sync(kw2"end"), dummyForRange, flw = kw2'end', locflw = kw2'end' },  -- TODO: sync(kw2"in" + kw2"do" + "\n") },
  { "ErrEndFor", "expected 'end' to close the for loop", sync(P"\n" + ";"), flw = firstBlock, locflw = firstBlock },
  { "ErrExprFor1", "expected a starting expression for the numeric range", sync(kw2"do" + "," + "\n"), dummyNum, flw = flwExp, locflw = P',' },
  { "ErrCommaFor", "expected ',' to split the start and end of the range", sync(kw2"do" + "," + "\n" + digit), flw = firstExp, locflw = firstExp },
  { "ErrExprFor2", "expected an ending expression for the numeric range", sync(kw2"do" + "\n"), dummyNum, flw = flwExp, locflw = P',' + kw2'do' },
  { "ErrExprFor3", "expected a step expression for the numeric range after ','", sync(kw2"do" + "\n"), flw = flwExp, locflw = kw2'do' },
  { "ErrInFor", "expected '=' or 'in' after the variable(s)",
                 sync(kw2"in" + kw2"do" + "\n" + ";" + "=", (#(kw2"in") * P(2) + #P"=" * any)^-1, #P";" * ";"), flw = firstExp, locflw = firstExp },
  { "ErrEListFor", "expected one or more expressions after 'in'", sync(kw2"do" + "\n"), dummyEList, flw = flwExprList, locflw = kw2'do' },
  { "ErrDoFor", "expected 'do' after the range of the for loop", sync(kw2"end" + kw2"do" + "\n", (#(kw2"do") * P(2))^-1), flw = firstBlock + kw2'end', locflw = firstBlock + kw2'end'},

  { "ErrDefLocal", "expected a function definition or assignment after 'local'", sync(kw2"end" + P"\n" + ";"), flw = firstBlock, locflw = firstBlock },
  { "ErrNameLFunc", "expected a function name after 'function'", sync(kw2"end" + "("+ "\n"), dummyId, flw = flwName, locflw = P'(' },
  { "ErrEListLAssign", "expected one or more expressions after '='", sync(P"\n"), dummyEList, flw = flwExprList, locflw = firstBlock },
  { "ErrEListAssign", "expected one or more expressions after '='", sync(P"\n"), dummyEList, flw = flwExprList, locflw = firstBlock },

  { "ErrFuncName", "expected a function name after 'function'", sync(P"(" + "\n"), dummyId, flw = P"(", locflw = P'(' },
  { "ErrNameFunc1", "expected a function name after '.'", sync(P"(" + "\n"), dummyStr, flw = flwName, locflw = S'.:(' },
  { "ErrNameFunc2", "expected a method name after ':'", sync(P"(" + "\n"), dummyStr, flw = flwName, locflw = P'(' },
	{ "ErrOParenPList", "expected '(' for the parameter list", sync(P"(" + ")" + "\n", (#P"(" * any)^-1 ), flw = P')' + ident, locflw = P')' + ident  },
  { "ErrCParenPList", "expected ')' to close the parameter list", sync(P")" + "\n" + kw2"end", (#P")" * any)^-1), flw = firstBlock + kw2'end', locflw = firstBlock + kw2'end' },
  { "ErrEndFunc", "expected 'end' to close the function body", sync(P""), flw = firstBlock, locflw = firstBlock },
  { "ErrParList", "expected a variable name or '...' after ','", sync(P")" + "\n"), dummyId, flw = P')', locflw = P')' },

  { "ErrLabel", "expected a label name after '::'", sync(P"::" + "\n"), flw = flwName, locflw = P"::" },
  { "ErrCloseLabel", "expected '::' after the label", P"", flw = firstBlock, locflw = firstBlock },
  { "ErrGoto", "expected a label after 'goto'", sync(P"\n" + ";"), flw = flwName, locflw = firstBlock },
  { "ErrRetList", "expected an expression after ',' in the return statement", sync(P"\n"), dummyExpr, flw = flwExp, locflw = P';' + flwBlock  },

  { "ErrVarList", "expected a variable name after ','", sync(P"\n" + "="), dummyId, flw = P"=", locflw = P'='  },
  { "ErrExprList", "expected an expression after ','", P"", dummyExpr, flw = flwExp, locflw = firstBlock },

  { "ErrOrExpr", "expected an expression after 'or'", psyncExp, dummyNum, flw = flwExp, locflw = flwExp},
  { "ErrAndExpr", "expected an expression after 'and'", psyncExp, dummyNum, flw = flwExp, locflw = flwExp },
  { "ErrRelExpr", "expected an expression after the relational operator", psyncExp, dummyNum, flw = flwExp, locflw = flwExp},
  { "ErrBOrExpr", "expected an expression after '|'", psyncExp, dummyNum, flw = flwExp, locflw = flwExp},
  { "ErrBXorExpr", "expected an expression after '~'", psyncExp, dummyNum, flw = flwExp, locflw = flwExp },
  { "ErrBAndExpr", "expected an expression after '&'", psyncExp, dummyNum, flw = flwExp, locflw = flwExp },
  { "ErrShiftExpr", "expected an expression after the bit shift", psyncExp, dummyNum, flw = flwExp, locflw = flwExp },
  { "ErrConcatExpr", "expected an expression after '..'", psyncExp, dummyStr, flw = flwExp, locflw = flwExp },
	--TODO: could sync also with ",", to build a better AST
  { "ErrAddExpr", "expected an expression after the additive operator", psyncExp, dummyNum, flw = flwExp, locflw = flwExp }, 
  { "ErrMulExpr", "expected an expression after the multiplicative operator", psyncExp, dummyNum, flw = flwExp, locflw = flwExp },
  { "ErrUnaryExpr", "expected an expression after the unary operator", psyncExp, dummyNum, flw = flwExp, locflw = flwExp },
  { "ErrPowExpr", "expected an expression after '^'", psyncExp, dummyNum, flw = flwExp, locflw = flwExp },

  { "ErrExprParen", "expected an expression after '('", sync(P")" + "\n"), dummyExpr, flw = flwExp, locflw = P")" },
  { "ErrCParenExpr", "expected ')' to close the expression", P"", flw = flwExp, locflw = flwExp },
  { "ErrNameIndex", "expected a field name after '.'", sync(P"\n" + "("), dummyId, flw = flwName, locflw = flwExp + S'.[:(' },
  { "ErrExprIndex", "expected an expression after '['", psyncExp, dummyId, flw = flwExp, locflw = P']' },
  { "ErrCBracketIndex", "expected ']' to close the indexing expression", P"", flw = flwExp, locflw = flwExp },
  { "ErrNameMeth", "expected a method name after ':'", sync(P"\n" + "(" + "{" + "\""), dummyId, flw = flwName, locflw = S([['"{(]]) },
  -- TODO: synchronize with all reserved words?
  { "ErrMethArgs", "expected some arguments for the method call (or '()')", sync(kw2"do" + "\n" + ";" + ")" + kw2"then"), flw = flwExp, locflw = flwExp },

  { "ErrArgList", "expected an expression after ',' in the argument list", sync(P"\n" + ")"), dummyExpr, flw = flwExp, locflw = P')' },
  { "ErrCParenArgs", "expected ')' to close the argument list", P"", flw = flwExp, locflw = flwExp },

  { "ErrCBraceTable", "expected '}' to close the table constructor", P"", flw = flwExp, locflw = flwExp  },
  { "ErrEqField", "expected '=' after the table key", sync(P"}" + "\n" + "," + digit + idStart + "=", (#P"=" * "=")^-1), flw = firstExp, locflw = firstExp },
  { "ErrExprField", "expected an expression after '='", sync(P"}" + "\n" + ","), dummyId, flw = flwExp, locflw = S'},;' },
  { "ErrExprFKey", "expected an expression after '[' for the table key", sync(P"\n" + "]"), dummyId, flw = flwExp, locflw = P']'},
  { "ErrCBracketFKey", "expected ']' to close the table key", P"", flw = P"=", locflw = P'=' },

  { "ErrDigitHex", "expected one or more hexadecimal digits after '0x'", sync(P"\n" + ")"), flw = flwExp, locflw = flwExp },
  { "ErrDigitDeci", "expected one or more digits after the decimal point", sync(P"\n" + ")"), flw = flwExp + S"eE", locflw = flwExp + S"eE" },
  { "ErrDigitExpo", "expected one or more digits for the exponent", sync(P"\n" + ")"), flw = flwExp, locflw = flwExp },

  { "ErrQuote", "unclosed string", P"", flw = flwExp, locflw = flwExp },
  { "ErrHexEsc", "expected exactly two hexadecimal digits after '\\x'", sync(P"\n" + ")" + "\""), "00", flw = P"", locflw = P''}, --followed by .
  { "ErrOBraceUEsc", "expected '{' after '\\u'", P"", flw = xdigit, locflw = xdigit },
  { "ErrDigitUEsc", "expected one or more hexadecimal digits for the UTF-8 code point", sync(P"\n" + "}" + "\""), "0", flw = P"}", locflw = P'}' },
  { "ErrCBraceUEsc", "expected '}' after the code point", P"", flw = P"'" + P'"', locflw = S[['"]] },
  { "ErrEscSeq", "invalid escape sequence", sync(P"\n" + "\""), "0", flw = P"'" + P'"', locflw = S[['"]] },
  { "ErrCloseLStr", "unclosed long string", P"", flw = flwExp, locflw = flwExp },
}

local function throw(label)
  label = "Err" .. label
  for i, labelinfo in ipairs(labels) do
    if labelinfo[1] == label then
      return T(label)
    end
  end

  error("Label not found: " .. label)
end

local function expect (patt, label, dummy)
  local p = patt + throw(label)
	--if dummy then
	--	p = p * dummy
	--end
	return p
end


-- regular combinators and auxiliary functions

local function token (patt)
  return patt * V"Skip"
end

local function sym (str)
  return token(P(str))
end

local function kw (str)
  return token(P(str) * -idRest)
end

local function tagC (tag, patt)
  return Ct(Cg(Cp(), "pos") * Cg(Cc(tag), "tag") * patt)
end

local function unaryOp (op, e)
  return { tag = "Op", pos = e.pos, [1] = op, [2] = e }
end

local function binaryOp (e1, op, e2)
  if not op then
    return e1
  end

  local node = { tag = "Op", pos = e1.pos, [1] = op, [2] = e1, [3] = e2 }

  if op == "ne" then
    node[1] = "eq"
    node = unaryOp("not", node)
  elseif op == "gt" then
    node[1], node[2], node[3] = "lt", e2, e1
  elseif op == "ge" then
    node[1], node[2], node[3] = "le", e2, e1
  end

  return node
end

local function sepBy (patt, sep, label)
  if label then
    return patt * Cg(sep * expect(patt, label))^0
  else
    return patt * Cg(sep * patt)^0
  end
end

local function chainOp (patt, sep, label)
  return Cf(sepBy(patt, sep, label), binaryOp)
end

local function commaSep (patt, label)
  return sepBy(patt, sym(","), label)
end

local function tagDo (block)
  block.tag = "Do"
  return block
end

local function fixFuncStat (func)
  if func[1].is_method then table.insert(func[2][1], 1, { tag = "Id", [1] = "self" }) end
  func[1] = {func[1]}
  func[2] = {func[2]}
  return func
end

local function addDots (params, dots)
  if dots then table.insert(params, dots) end
  return params
end

local function insertIndex (t, index)
	--print("insert", t, t.tag, index)
	if type(index) == "table" then
		--print(index.tag, index[1])
	end
	if not index then return t end
  return { tag = "Index", pos = t.pos, [1] = t, [2] = index }
end

local function markMethod(t, method)
  if method then
    return { tag = "Index", pos = t.pos, is_method = true, [1] = t, [2] = method }
  end
  return t
end

local function makeIndexOrCall (t1, t2)
  if t2.tag == "Call" or t2.tag == "Invoke" then
    local t = { tag = t2.tag, pos = t1.pos, [1] = t1 }
    for k, v in ipairs(t2) do
      table.insert(t, v)
    end
    return t
  end
  return { tag = "Index", pos = t1.pos, [1] = t1, [2] = t2[1] }
end

local function countSyntaxErr ()
	nerrors = #syntaxerrs
	return true
end

-- grammar
local G = { V"Lua",
  Lua      = V"Shebang"^-1 * V"Skip" * V"Block" * expect(P(-1), "Extra");
  --Shebang  = P"#!" * (P(1) - P"\n")^0;
  Shebang  = P"#" * (P(1) - P"\n")^0;

  Block       = tagC("Block", V"Stat"^0 * V"RetStat"^-1);
  Stat        = V"IfStat" + V"DoStat" + V"WhileStat" + V"RepeatStat" + V"ForStat"
              + V"LocalStat" + V"FuncStat" + V"BreakStat" + V"LabelStat" + V"GoToStat"
              + countSyntaxErr * V"FuncCall" + V"Assignment" + sym(";") + -blockEnd * throw("InvalidStat");

  IfStat      = tagC("If", V"IfPart" * V"ElseIfPart"^0 * V"ElsePart"^-1 * expect(kw("end"), "EndIf"));
  IfPart      = kw("if") * expect(V"Expr", "ExprIf") * expect(kw("then"), "ThenIf") * V"Block";
  ElseIfPart  = kw("elseif") * expect(V"Expr", "ExprEIf") * expect(kw("then"), "ThenEIf") * V"Block";
  ElsePart    = kw("else") * V"Block";

  DoStat      = kw("do") * V"Block" * expect(kw("end"), "EndDo") / tagDo;
  WhileStat   = tagC("While", kw("while") * expect(V"Expr", "ExprWhile") * V"WhileBody");
  WhileBody   = expect(kw("do"), "DoWhile") * V"Block" * expect(kw("end"), "EndWhile");
  RepeatStat  = tagC("Repeat", kw("repeat") * V"Block" * expect(kw("until"), "UntilRep") * expect(V"Expr", "ExprRep"));

  --TODO: grammar discards the whole body of "for" when there is an error in the range. Improve this to parse the body
  -- after the error.
  ForStat   = kw("for") * expect(V"ForNum" + V"ForIn", "ForRange") * expect(kw("end"), "EndFor");
  ForNum    = tagC("Fornum", V"Id" * sym("=") * V"NumRange" * V"ForBody");
  NumRange  = expect(V"Expr", "ExprFor1") * expect(sym(","), "CommaFor") *expect(V"Expr", "ExprFor2")
            * (sym(",") * expect(V"Expr", "ExprFor3"))^-1;
  ForIn     = tagC("Forin", V"NameList" * expect(kw("in"), "InFor") * expect(V"ExprList", "EListFor") * V"ForBody");
  ForBody   = expect(kw("do"), "DoFor") * V"Block";

  LocalStat    = kw("local") * expect(V"LocalFunc" + V"LocalAssign", "DefLocal");
  LocalFunc    = tagC("Localrec", kw("function") * expect(V"Id", "NameLFunc") * V"FuncBody") / fixFuncStat;
  LocalAssign  = tagC("Local", V"NameList" * (sym("=") * expect(V"ExprList", "EListLAssign") + Ct(Cc())));
  Assignment   = tagC("Set", V"VarList" * sym("=") * expect(V"ExprList", "EListAssign"));

  FuncStat    = tagC("Set", kw("function") * expect(V"FuncName", "FuncName") * V"FuncBody") / fixFuncStat;
  FuncName    = Cf(V"Id" * (sym(".") * expect(V"StrId", "NameFunc1"))^0, insertIndex)
  --FuncName    = V"Name" * Cf(Cc(dummyId)* (P"." * throw("NameFunc1"))^0, insertIndex)
  --FuncName    = Cf(V"Id" * ((sym(".") / "ponto") * throw("NameFunc1")  )^0, insertIndex)
              * (sym(":") * expect(V"StrId", "NameFunc2"))^-1 / markMethod;
  FuncBody    = tagC("Function", V"FuncParams" * V"Block" * expect(kw("end"), "EndFunc"));
  FuncParams  = expect(sym("("), "OParenPList") * V"ParList" * expect(sym(")"), "CParenPList");
  ParList     = V"NameList" * (sym(",") * expect(tagC("Dots", sym("...")), "ParList"))^-1 / addDots
              + Ct(tagC("Dots", sym("...")))
              + Ct(Cc()); -- Cc({}) generates a bug since the {} would be shared across parses

  LabelStat  = tagC("Label", sym("::") * expect(V"Name", "Label") * expect(sym("::"), "CloseLabel"));
  GoToStat   = tagC("Goto", kw("goto") * expect(V"Name", "Goto"));
  BreakStat  = tagC("Break", kw("break"));
  RetStat    = tagC("Return", kw("return") * commaSep(V"Expr", "RetList")^-1 * sym(";")^-1);

  NameList  = tagC("NameList", commaSep(V"Id"));
  VarList   = tagC("VarList", commaSep(V"VarExpr", "VarList"));
  ExprList  = tagC("ExpList", commaSep(V"Expr", "ExprList"));

  Expr        = V"OrExpr";
  OrExpr      = chainOp(V"AndExpr", V"OrOp", "OrExpr");
  AndExpr     = chainOp(V"RelExpr", V"AndOp", "AndExpr");
  RelExpr     = chainOp(V"BOrExpr", V"RelOp", "RelExpr");
  BOrExpr     = chainOp(V"BXorExpr", V"BOrOp", "BOrExpr");
  BXorExpr    = chainOp(V"BAndExpr", V"BXorOp", "BXorExpr");
  BAndExpr    = chainOp(V"ShiftExpr", V"BAndOp", "BAndExpr");
  ShiftExpr   = chainOp(V"ConcatExpr", V"ShiftOp", "ShiftExpr");
  ConcatExpr  = V"AddExpr" * (V"ConcatOp" * expect(V"ConcatExpr", "ConcatExpr"))^-1 / binaryOp;
  AddExpr     = chainOp(V"MulExpr", V"AddOp", "AddExpr");
  MulExpr     = chainOp(V"UnaryExpr", V"MulOp", "MulExpr");
  UnaryExpr   = V"UnaryOp" * expect(V"UnaryExpr", "UnaryExpr") / unaryOp
              + V"PowExpr";
  PowExpr     = V"SimpleExpr" * (V"PowOp" * expect(V"UnaryExpr", "PowExpr"))^-1 / binaryOp;

  SimpleExpr = tagC("Number", V"Number")
             + tagC("String", V"String")
             + tagC("Nil", kw("nil"))
             + tagC("False", kw("false"))
             + tagC("True", kw("true"))
             + tagC("Dots", sym("..."))
             + V"FuncDef"
             + V"Table"
             + V"SuffixedExpr";

	
  FuncCall  = Cmt(V"SuffixedExpr", function(s, i, exp) 
			local r =  exp.tag == "Call" or exp.tag == "Invoke"
			--print("err = ", r, #syntaxerrs, exp.tag, exp[1], i)
			if not r then
				local n = #syntaxerrs
				for i = nerrors + 1, n do
					syntaxerrs[i] = nil
		 		end
			end 
			return exp.tag == "Call" or exp.tag == "Invoke", exp end);
  VarExpr   = Cmt(V"SuffixedExpr", function(s, i, exp) 
		--lasterr = #syntaxerrs
		return exp.tag == "Id" or exp.tag == "Index", exp end);

  SuffixedExpr  = Cf(V"PrimaryExpr" * (V"Index" + V"Call")^0, makeIndexOrCall);
  PrimaryExpr   = V"Id" + tagC("Paren", sym("(") * expect(V"Expr", "ExprParen") * expect(sym(")"), "CParenExpr"));
  Index         = tagC("DotIndex", sym("." * -P".") * expect(V"StrId", "NameIndex"))
                + tagC("ArrayIndex", sym("[" * -P(S"=[")) * expect(V"Expr", "ExprIndex") * expect(sym("]"), "CBracketIndex"));
  Call          = tagC("Invoke", Cg(sym(":" * -P":") * expect(V"StrId", "NameMeth") * expect(V"FuncArgs", "MethArgs")))
                + tagC("Call", V"FuncArgs");

  FuncDef   = kw("function") * V"FuncBody";
  FuncArgs  = sym("(") * commaSep(V"Expr", "ArgList")^-1 * expect(sym(")"), "CParenArgs")
            + V"Table"
            + tagC("String", V"String");

  Table      = tagC("Table", sym("{") * V"FieldList"^-1 * expect(sym("}"), "CBraceTable"));
  FieldList  = sepBy(V"Field", V"FieldSep") * V"FieldSep"^-1;
  Field      = tagC("Pair", V"FieldKey" * expect(sym("="), "EqField") * expect(V"Expr", "ExprField"))
             + V"Expr";
  FieldKey   = sym("[" * -P(S"=[")) * expect(V"Expr", "ExprFKey") * expect(sym("]"), "CBracketFKey")
             + V"StrId" * #("=" * -P"=");
  FieldSep   = sym(",") + sym(";");

  Id     = tagC("Id", V"Name");
  StrId  = tagC("String", V"Name");

  -- lexer
  Skip     = (V"Space" + V"Comment")^0;
  Space    = space^1;
  Comment  = P"--" * V"LongStr" / function () return end
           + P"--" * (P(1) - P"\n")^0;

  Name      = token(-reserved * C(ident));
  
  Number   = token((V"HexFloat" + V"HexInt" + V"Float" + V"Int") / tonumber);
	HexFloat = (P"0x" + "0X") * (V"HexDecimal" * V"HexExpo"^-1
           + xdigit^1 * V"HexExpo");

  HexInt   = (P"0x" + "0X") * expect(xdigit^1, "DigitHex");
  Float    = V"Decimal" * V"Expo"^-1
           + V"Int" * V"Expo";
  HexDecimal  = xdigit^1 * "." * xdigit^0
           + P"." * -P"." * expect(xdigit^1, "DigitHex");
  Decimal  = digit^1 * "." * digit^0
           + P"." * -P"." * expect(digit^1, "DigitDeci");
  Expo     = S"eE" * S"+-"^-1 * expect(digit^1, "DigitExpo");
  HexExpo     = S"eEpP" * S"+-"^-1 * expect(digit^1, "DigitExpo");
  Int      = digit^1;

  String    = token(V"ShortStr" + V"LongStr");
  ShortStr  = P'"' * Cs((V"EscSeq" + (P(1)-S'"\n'))^0) * expect(P'"', "Quote")
            + P"'" * Cs((V"EscSeq" + (P(1)-S"'\n"))^0) * expect(P"'", "Quote");

  EscSeq = P"\\" / ""  -- remove backslash
         * ( P"a" / "\a"
           + P"b" / "\b"
           + P"f" / "\f"
           + P"n" / "\n"
           + P"r" / "\r"
           + P"t" / "\t"
           + P"v" / "\v"
 
           + P"\n" / "\n"
           + P"\r" / "\n"
 
           + P"\\" / "\\"
           + P"\"" / "\""
           + P"\'" / "\'"

           + P"z" * space^0  / ""

           + digit * digit^-2 / tonumber / string.char
           + P"x" * expect(C(xdigit * xdigit), "HexEsc", "00") * Cc(16) / tonumber / string.char
           + P"u" * expect("{", "OBraceUEsc")
                  * expect(C(xdigit^1), "DigitUEsc", "0") * Cc(16)
                  * expect("}", "CBraceUEsc")
                  / tonumber 
                  / (utf8 and utf8.char or string.char)  -- true max is \u{10FFFF}
                                                         -- utf8.char needs Lua 5.3
                                                         -- string.char works only until \u{FF}

           + throw("EscSeq")
           );

  LongStr  = V"Open" * C((P(1) - V"CloseEq")^0) * expect(V"Close", "CloseLStr") / function (s, eqs) return s end;
  Open     = "[" * Cg(V"Equals", "openEq") * "[" * P"\n"^-1;
  Close    = "]" * C(V"Equals") * "]";
  Equals   = P"="^0;
  CloseEq  = Cmt(V"Close" * Cb("openEq"), function (s, i, closeEq, openEq) return #openEq == #closeEq end);

  OrOp      = kw("or")   / "or";
  AndOp     = kw("and")  / "and";
  RelOp     = sym("~=")  / "ne"
            + sym("==")  / "eq"
            + sym("<=")  / "le"
            + sym(">=")  / "ge"
            + sym("<")   / "lt"
            + sym(">")   / "gt";
  BOrOp     = sym("|")   / "bor";
  BXorOp    = sym("~" * -P"=") / "bxor";
  BAndOp    = sym("&")   / "band";
  ShiftOp   = sym("<<")  / "shl"
            + sym(">>")  / "shr";
  ConcatOp  = sym("..")  / "concat";
  AddOp     = sym("+")   / "add"
            + sym("-")   / "sub";
  MulOp     = sym("*")   / "mul"
            + sym("//")  / "idiv"
            + sym("/")   / "div"
            + sym("%")   / "mod";
  UnaryOp   = kw("not")  / "not"
            + sym("-")   / "unm"
            + sym("#")   / "len"
            + sym("~")   / "bnot";
  PowOp     = sym("^")   / "pow";
}


function recorderror(pos, lab)
	local line, col = re.calcline(cursubject, pos)
	table.insert(syntaxerrs, { pos = pos, line = line, col = col, lab = lab, error = labels[lab][2] })
end

function record (lab)
	return (Cp() * Cc(lab)) / recorderror
end

local function buildRecG (g, flw)
  local grec = {}
  for k, v in pairs(g) do
		grec[k] = v
	end

	local Equals   = P"="^0;
	local Close    = "]" * C(Equals) * "]";
	local CloseEq  = Cmt(Close * Cb("openEq"), function (s, i, closeEq, openEq) return #openEq == #closeEq end);
	local Open     = "[" * Cg(Equals, "openEq") * "[" * P"\n"^-1;
	local LongStr  = Open * C((P(1) - CloseEq)^0) * expect(Close, "CloseLStr") / function (s, eqs) return s end

	local Comment  = P"--" * LongStr / function () return end
                 + P"--" * (P(1) - P"\n")^0;

	local space = grec["Space"]
	
	local skip = space + Comment
	--local skipLine = (#(P"," + ";") * 1)^-1 * (-(P",\n" + "\n" + ";" + "end") * 1)^0 * skip
	local skipLine = P(1)^0 

	for i, v in ipairs(labels) do
    print("v[3]", v[1], flw, v[3])
		local prec = skipLine
		if flw == "flw" and v.flw2 then 
	  	prec = sync(v.flw, nil, v.flw2)
		elseif flw == "flw" then
      prec = sync(v.flw)
    elseif flw == "locflw" and v.flw2 then
      prec = sync(v.locflw, nil, v.flw2)
		elseif flw == "locflw" then
      prec = sync(v.locflw)
    elseif v[3] then
			print("tem v3", v[1])
			prec = v[3]
		end
    --print("here ", v[1])
		if v[4] then
			grec[v[1]] = record(i) * prec * Cc(v[4])
		else
      --print("nao tem v4", v[1])
      if v[1] == "ErrEListAssign" then print("grecc", v[1]) end
			grec[v[1]] = record(i) * prec
		--else
			--grec = Rec(grec, record(i) * prec * Cc(dummyExpr), i)
    end
	end
	return grec
end


local parser = {}

local validator = require("lua-parser.validator")
local validate = validator.validate
local syntaxerror = validator.syntaxerror
local Grec = buildRecG(G)
local Gflw = buildRecG(G, "flw")
local Glocflw = buildRecG(G, "locflw")

function parser.parse (subject, filename, flw)
  local errorinfo = { subject = subject, filename = filename }
  lpeg.setmaxstack(1000)
	cursubject = subject
	syntaxerrs = {}
	local g = Grec
	if flw == 'flw' then
		g = Gflw
  elseif flw == 'locflw' then
    g = Glocflw
	end
  local ast, label, sfail = lpeg.match(g, subject, nil, errorinfo)
	--print(ast, label, #syntaxerrs)
  if #syntaxerrs > 0 then
		local errs = {}
    for i, err in ipairs(syntaxerrs) do
      local errpos = err.pos
      local errmsg = err.error
     	table.insert(errs, syntaxerror(errorinfo, errpos, errmsg))
    end
    return nil, table.concat(errs, "\n"), ast
  end
  local r, msg = validate(ast, errorinfo)
	if r then
		return r
	else
		return r, msg, ast
	end
end

return parser
