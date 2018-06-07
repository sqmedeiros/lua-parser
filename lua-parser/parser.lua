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
local T = lpeg.T

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
local dummyBlock = { tag = "Block", pos = 0, } 
local dummyForRange = { tag = "Forin", pos = 0, [1] = {}, [2] = dummyEList, [3] = dummyBlock }


-- error message auxiliary functions

local labels = {
  ErrExtra         = { msg = "unexpected character(s), expected EOF",  ast = nil,
                       rec = nil, flw = -any, locflw = -any },
  ErrInvalidStat   = { msg = "unexpected token, invalid start of statement", ast = nil,
                       rec = sync(P"\n" + ";"), flw = firstStmt, flw2 = ident, locflw = firstStmt },

  ErrEndIf         = { msg = "expected 'end' to close the if statement", ast = nil,
                       rec = sync(P"\n" + ";"),  flw = firstBlock, locflw = firstBlock }, 
  ErrExprIf        = { msg = "expected a condition after 'if'",  ast = dummyExpr,
                       rec = sync(kw2"then" + "\n" + kw2"end"), flw = flwExp, locflw = kw2"then"  },
  ErrThenIf        = { msg = "expected 'then' after the condition", ast = nil,
                       rec = sync(idStart + "\n"), flw = firstBlock + kw2'end', locflw = firstBlock + kw2'end' },
  ErrExprEIf       = { msg = "expected a condition after 'elseif'", ast = dummyExpr,
                       rec = sync(kw2"then" + "\n" + kw2"end"), flw = flwExp, locflw = kw2'then' },
  ErrThenEIf       = { msg = "expected 'then' after the condition", ast = nil,
                       rec = sync(idStart + "\n"), flw = firstBlock + kw2'end', locflw = firstBlock + kw2'end' },

  ErrEndDo         = { msg = "expected 'end' to close the do block", ast = nil,
                       rec = sync(P"\n" + ";"), flw = firstBlock, locflw = firstBlock },
  ErrExprWhile     = { msg = "expected a condition after 'while'", ast = dummyExpr,
                       rec = sync(kw2"do" + "\n" + kw2"end"), flw = flwExp, locflw = kw2'do' }, 
  ErrDoWhile       = { msg = "expected 'do' after the condition", ast = nil,
                       rec = sync(P"\n" + kw2"end"), flw = firstBlock + kw2'end', locflw = firstBlock + kw2'end' },
  ErrEndWhile      = { msg = "expected 'end' to close the while loop", ast = nil,
                       rec = sync(P"\n" + ";"), flw = firstBlock, locflw = firstBlock },
  ErrUntilRep      = { msg = "expected 'until' at the end of the repeat loop", ast = nil,
                       rec = sync(P"\n" + digit + ident + ";"), flw = firstExp, locflw = firstExp },
  ErrExprRep       = { msg = "expected a condition after 'until'", ast = dummyExpr, 
                       rec = sync(P"\n"), flw = flwExp, locflw = flwExp },

  ErrForRange      = { msg = "expected a numeric or generic range after 'for'", ast = dummyForRange, 
                       rec = sync(kw2"end"), flw = kw2'end', locflw = kw2'end' },  
  ErrEndFor        = { msg = "expected 'end' to close the for loop", ast = nil,
                       rec = sync(P"\n" + ";"), flw = firstBlock, locflw = firstBlock },
  ErrExprFor1      = { msg = "expected a starting expression for the numeric range", ast = dummyNum,
                       rec = sync(kw2"do" + "," + "\n"), flw = flwExp, locflw = P',' },
  ErrCommaFor      = { msg = "expected ',' to split the start and end of the range", ast = nil, 
                       rec = sync(kw2"do" + "," + "\n" + digit), flw = firstExp, locflw = firstExp },
  ErrExprFor2      = { msg = "expected an ending expression for the numeric range", ast = dummyNum,
                       rec = sync(kw2"do" + "\n"), flw = flwExp, locflw = P',' + kw2'do' },
  ErrExprFor3      = { msg = "expected a step expression for the numeric range after ','", ast = nil,
                       rec = sync(kw2"do" + "\n"), flw = flwExp, locflw = kw2'do' },
  ErrInFor         = { msg = "expected '=' or 'in' after the variable(s)", ast = nil,
                       rec = sync(kw2"in" + kw2"do" + "\n" + ";" + "=", (#(kw2"in") * P(2) + #P"=" * any)^-1, #P";" * ";"), flw = firstExp, locflw = firstExp },
  ErrEListFor      = { msg = "expected one or more expressions after 'in'", ast = dummyEList,  
                       rec = sync(kw2"do" + "\n"), flw = flwExprList, locflw = kw2'do' },
  ErrDoFor         = { msg = "expected 'do' after the range of the for loop", ast = nil, 
                       rec = sync(kw2"end" + kw2"do" + "\n", (#(kw2"do") * P(2))^-1), flw = firstBlock + kw2'end', locflw = firstBlock + kw2'end' },

  ErrDefLocal      = { msg = "expected a function definition or assignment after 'local'", ast = nil,
                       rec = sync(kw2"end" + P"\n" + ";"), flw = firstBlock, locflw = firstBlock },
  ErrNameLFunc     = { msg = "expected a function name after 'function'", ast = dummyId,  
                       rec = sync(kw2"end" + "("+ "\n"), flw = flwName, locflw = P'(' },
  ErrEListLAssign  = { msg = "expected one or more expressions after '='", ast = dummyEList,  
                       rec = sync(P"\n"), flw = flwExprList, locflw = firstBlock },
  ErrEListAssign   = { msg = "expected one or more expressions after '='", ast = dummyEList,  
                       rec = sync(P"\n"), flw = flwExprList, locflw = firstBlock },

  ErrFuncName      = { msg = "expected a function name after 'function'", ast = dummyId, 
                       rec = sync(P"(" + "\n"), flw = P"(", locflw = P'(' },
  ErrNameFunc1     = { msg = "expected a function name after '.'", ast = dummyStr, 
                       rec = sync(P"(" + "\n"), flw = flwName, locflw = S'.:(' },
  ErrNameFunc2     = { msg = "expected a method name after ':'", ast = dummyStr, 
                       rec = sync(P"(" + "\n"), flw = flwName, locflw = P'(' },
  ErrOParenPList   = { msg = "expected '(' for the parameter list", ast = nil,
                       rec = sync(P"(" + ")" + "\n", (#P"(" * any)^-1 ), flw = P')' + ident, locflw = P')' + ident  },
  ErrCParenPList   = { msg = "expected ')' to close the parameter list", ast = nil,
                       rec = sync(P")" + "\n" + kw2"end", (#P")" * any)^-1), flw = firstBlock + kw2'end', locflw = firstBlock + kw2'end' },
  ErrEndFunc       = { msg = "expected 'end' to close the function body", ast = nil,
                       rec = sync(P""), flw = firstBlock, locflw = firstBlock },
  ErrParList       = { msg = "expected a variable name or '...' after ','", ast = dummyId,
                       rec = sync(P")" + "\n"), flw = P')', locflw = P')' },

  ErrLabel         = { msg = "expected a label name after '::'", ast = nil,
                       rec = sync(P"::" + "\n"), flw = flwName, locflw = P"::" },
  ErrCloseLabel    = { msg = "expected '::' after the label", ast = nil,
                       rec = P"", flw = firstBlock, locflw = firstBlock },
  ErrGoto          = { msg = "expected a label after 'goto'", ast = nil,
                       rec = sync(P"\n" + ";"), flw = flwName, locflw = firstBlock },
  ErrRetList       = { msg = "expected an expression after ',' in the return statement", ast = dummyExpr,
                       rec = sync(P"\n"), flw = flwExp, locflw = P';' + flwBlock  },

  ErrVarList       = { msg = "expected a variable name after ','", ast = dummyId,
                       rec = sync(P"\n" + "="), flw = P"=", locflw = P'='  },
  ErrExprList      = { msg = "expected an expression after ','", ast = dummyExpr,
                       rec = P"", flw = flwExp, locflw = firstBlock },

  ErrOrExpr        = { msg = "expected an expression after 'or'", ast = dummyNum,
                       rec = psyncExp, flw = flwExp, locflw = flwExp },
  ErrAndExpr       = { msg = "expected an expression after 'and'", ast = dummyNum,
                       rec = psyncExp, flw = flwExp, locflw = flwExp },
  ErrRelExpr       = { msg = "expected an expression after the relational operator", ast = dummyNum,
                       rec = psyncExp, flw = flwExp, locflw = flwExp },
  ErrBOrExpr       = { msg = "expected an expression after '|'", ast = dummyNum,
                       rec = psyncExp, flw = flwExp, locflw = flwExp },
  ErrBXorExpr      = { msg = "expected an expression after '~'", ast = dummyNum,  
                       rec = psyncExp, flw = flwExp, locflw = flwExp },
  ErrBAndExpr      = { msg = "expected an expression after '&'", ast = dummyNum,
                       rec = psyncExp, flw = flwExp, locflw = flwExp },
  ErrShiftExpr     = { msg = "expected an expression after the bit shift", ast = dummyNum, 
                       rec = psyncExp, flw = flwExp, locflw = flwExp },
  ErrConcatExpr    = { msg = "expected an expression after '..'", ast = dummyStr,
                       rec = psyncExp, flw = flwExp, locflw = flwExp },
	--TODO: could sync also with ",", to build a better AST
  ErrAddExpr       = { msg = "expected an expression after the additive operator", ast = dummyNum,
                       rec = psyncExp, flw = flwExp, locflw = flwExp }, 
  ErrMulExpr       = { msg = "expected an expression after the multiplicative operator", ast = dummyNum,
                       rec = psyncExp, flw = flwExp, locflw = flwExp },
  ErrUnaryExpr     = { msg = "expected an expression after the unary operator", ast = dummyNum,
                       rec = psyncExp, flw = flwExp, locflw = flwExp },
  ErrPowExpr       = { msg = "expected an expression after '^'", ast = dummyNum,
                       rec = psyncExp, flw = flwExp, locflw = flwExp },

  ErrExprParen     = { msg = "expected an expression after '('", ast = dummyExpr,
                       rec = sync(P")" + "\n"), flw = flwExp, locflw = P")" },
  ErrCParenExpr    = { msg = "expected ')' to close the expression", ast = nil,
                       rec = P"", flw = flwExp, locflw = flwExp },
  ErrNameIndex     = { msg = "expected a field name after '.'", ast = dummyId,
                       rec = sync(P"\n" + "("), flw = flwName, locflw = flwExp + S'.[:(' },
  ErrExprIndex     = { msg = "expected an expression after '['", ast = dummyId,
                       rec = psyncExp, flw = flwExp, locflw = P']' },
  ErrCBracketIndex = { msg = "expected ']' to close the indexing expression",
                       rec = P"", flw = flwExp, locflw = flwExp },
  ErrNameMeth      = { msg =  "expected a method name after ':'", ast = dummyId,
                       rec = sync(P"\n" + "(" + "{" + "\""), flw = flwName, locflw = S([['"{(]]) },
  -- TODO: synchronize with all reserved words?
  ErrMethArgs      = { msg = "expected some arguments for the method call (or '()')", ast = nil,
                       rec = sync(kw2"do" + "\n" + ";" + ")" + kw2"then"), flw = flwExp, locflw = flwExp },

  ErrArgList       = { msg = "expected an expression after ',' in the argument list", ast = dummyExpr,
                       rec = sync(P"\n" + ")"), flw = flwExp, locflw = P')' },
  ErrCParenArgs    = { msg = "expected ')' to close the argument list", ast = nil,
                       rec = P"", flw = flwExp, locflw = flwExp },

  ErrCBraceTable   = { msg = "expected '}' to close the table constructor", ast = nil,
                       rec = P"", flw = flwExp, locflw = flwExp  },
  ErrEqField       = { msg = "expected '=' after the table key", ast = nil,
                       rec = sync(P"}" + "\n" + "," + digit + idStart + "=", (#P"=" * "=")^-1), flw = firstExp, locflw = firstExp },
  ErrExprField     = { msg = "expected an expression after '='", ast = dummyId,
                       rec = sync(P"}" + "\n" + ","), flw = flwExp, locflw = S'},;' },
  ErrExprFKey      = { msg = "expected an expression after '[' for the table key", ast = dummyId,
                       rec = sync(P"\n" + "]"), flw = flwExp, locflw = P']'},
  ErrCBracketFKey  = { msg = "expected ']' to close the table key", ast = nil,
                       rec = P"", flw = P"=", locflw = P'=' },

  ErrDigitHex      = { msg = "expected one or more hexadecimal digits after '0x'", ast = nil,
                       rec = sync(P"\n" + ")"), flw = flwExp, locflw = flwExp },
  ErrDigitDeci     = { msg = "expected one or more digits after the decimal point",
                       rec = sync(P"\n" + ")"), flw = flwExp + S"eE", locflw = flwExp + S"eE" },
  ErrDigitExpo     = { msg = "expected one or more digits for the exponent",
                       rec = sync(P"\n" + ")"), flw = flwExp, locflw = flwExp },

  ErrQuote         = { msg = "unclosed string", ast = nil,
                       rec = P"", flw = flwExp, locflw = flwExp },
  ErrHexEsc        = { msg = "expected exactly two hexadecimal digits after '\\x'", ast = "00",
                       rec = sync(P"\n" + ")" + "\""), flw = P"", locflw = P''}, --followed by .
  ErrOBraceUEsc    = { msg = "expected '{' after '\\u'",
                       rec = P"", flw = xdigit, locflw = xdigit },
  ErrDigitUEsc     = { msg = "expected one or more hexadecimal digits for the UTF-8 code point", ast =  "0",
                       rec = sync(P"\n" + "}" + "\""), flw = P"}", locflw = P'}' },
  ErrCBraceUEsc    = { msg = "expected '}' after the code point", ast = nil,
                       rec = P"", flw = P"'" + P'"', locflw = S[['"]] },
  ErrEscSeq        = { msg = "invalid escape sequence", ast = "0", 
                       rec = sync(P"\n" + "\""), flw = P"'" + P'"', locflw = S[['"]] },
  ErrCloseLStr     = { msg = "unclosed long string", ast = nil,
                       rec = P"", flw = flwExp, locflw = flwExp },
}

local function throw(label)
  label = "Err" .. label
  if not labels[label] then
    error("Label not found: " .. label)
  end
  return T(label)
end

local function expect (patt, label)
  return patt + throw(label)
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
	table.insert(syntaxerrs, { pos = pos, line = line, col = col, lab = lab, error = labels[lab].msg })
end

function record (lab)
	return (Cp() * Cc(lab)) / recorderror
end

local function buildRecG (g, flw)
  local grec = {}
  for k, v in pairs(g) do
		grec[k] = v
	end

  local skip = grec["Space"] + grec['Comment'] 
	--local skipLine = (#(P"," + ";") * 1)^-1 * (-(P",\n" + "\n" + ";" + "end") * 1)^0 * skip
	local skipLine = P(1)^0 

	for k, v in pairs(labels) do
		local prec = skipLine
		if flw == "flw" and v.flw2 then 
	  	prec = sync(v.flw, nil, v.flw2)
		elseif flw == "flw" then
      prec = sync(v.flw)
    elseif flw == "locflw" and v.flw2 then
      prec = sync(v.locflw, nil, v.flw2)
		elseif flw == "locflw" then
      prec = sync(v.locflw)
    elseif v.rec then
			prec = v.rec
		end
		if v.ast then
			grec[k] = record(k) * prec * Cc(v.ast)
		else
			grec[k] = record(k) * prec
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
