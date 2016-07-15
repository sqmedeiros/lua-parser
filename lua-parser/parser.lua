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

local parser = {}

local lpeg = require "lpeglabel"
local scope = require "lua-parser.scope"

lpeg.locale(lpeg)

local P, S, V = lpeg.P, lpeg.S, lpeg.V
local C, Carg, Cb, Cc = lpeg.C, lpeg.Carg, lpeg.Cb, lpeg.Cc
local Cf, Cg, Cmt, Cp, Ct = lpeg.Cf, lpeg.Cg, lpeg.Cmt, lpeg.Cp, lpeg.Ct
local Lc, T = lpeg.Lc, lpeg.T

local alpha, digit, alnum = lpeg.alpha, lpeg.digit, lpeg.alnum
local xdigit = lpeg.xdigit
local space = lpeg.space

local lineno = scope.lineno
local new_scope, end_scope = scope.new_scope, scope.end_scope
local new_function, end_function = scope.new_function, scope.end_function
local begin_loop, end_loop = scope.begin_loop, scope.end_loop
local insideloop = scope.insideloop

-- error message auxiliary functions

local labels = {
  { "ExpExprIf", "expected a condition after 'if'" },
  { "ExpThenIf", "expected 'then' after the condition" },
  { "ExpExprEIf", "expected a condition after 'elseif'" },
  { "ExpThenEIf", "expected 'then' after the condition" },
  { "ExpEndIf", "expected 'end' to close the if statement" },
  { "ExpEndDo", "expected 'end' to close the do block" },
  { "ExpExprWhile", "expected a condition after 'while'" },
  { "ExpDoWhile", "expected 'do' after the condition" },
  { "ExpEndWhile", "expected 'end' to close the while loop" },
  { "ExpUntilRep", "expected 'until' after the condition" },
  { "ExpExprRep", "expected a condition after 'until'" },

  { "ExpForRange", "expected a numeric or generic range after 'for'" },
  { "ExpEndFor", "expected 'end' to close the for loop" },
  { "ExpExprFor1", "expected a starting expression for the numeric range " },
  { "ExpCommaFor", "expected a comma to split the start and end of the range" },
  { "ExpExprFor2", "expected an ending expression for the numeric range" },
  { "ExpExprFor3", "expected a step expression for the numeric range after the comma" },
  { "ExpInFor", "expected 'in' after the variable names" },
  { "ExpEListFor", "expected one or more expressions after 'in'" },
  { "ExpDoFor", "expected 'do' after the range of the for loop" },

  { "ExpDefLocal", "expected a function definition or assignment after 'local'" },
  { "ExpNameLFunc", "expected an identifier after 'function'" },
  { "ExpEListLAssign", "expected one or more expressions after '='" },
  { "ExpFuncName", "expected a function name after 'function'" },
  { "ExpNameFunc1", "expected an identifier after the dot" },
  { "ExpNameFunc2", "expected an identifier after the colon" },
  { "ExpOpenParenParams", "expected opening '(' for the parameter list" },
  { "MisCloseParenParams", "missing closing ')' to end the parameter list" },
  { "ExpEndFunc", "expected 'end' to close the function body" },

  { "ExpLHSComma", "expected a variable or table field after the comma" },
  { "ExpEListAssign", "expected one or more expressions after '='" },
  { "ExpLabelName", "expected a label name after '::'" },
  { "MisCloseLabel", "missing closing '::' after the label" },
  { "ExpLabel", "expected a label name after 'goto'" },
  { "ExpExprCommaRet", "expected an expression after the comma" },
  { "ExpNameNList", "expected an identifier after the comma" },
  { "ExpExprEList", "expected an expression after the comma" },

  { "ExpExprSub1", "expected an expression after the 'or' operator" },
  { "ExpExprSub2", "expected an expression after the 'and' operator" },
  { "ExpExprSub3", "expected an expression after the relational operator" },
  { "ExpExprSub4", "expected an expression after the '|' operator" },
  { "ExpExprSub5", "expected an expression after the '~' operator" },
  { "ExpExprSub6", "expected an expression after the '&' operator" },
  { "ExpExprSub7", "expected an expression after the bitshift operator" },
  { "ExpExprSub8", "expected an expression after the '..' operator" },
  { "ExpExprSub9", "expected an expression after the additive operator" },
  { "ExpExprSub10", "expected an expression after the multiplicative operator" },
  { "ExpExprSub11", "expected an expression after the unary operator" },
  { "ExpExprSub12", "expected an expression after the '^' operator" },

  { "ExpNameDot", "expected a field name after the dot" },
  { "MisCloseBracketIndex", "missing closing ']' in the table indexing" },
  { "ExpNameColon", "expected an identifier after the colon" },
  { "ExpFuncArgs", "expected at least one argument in the method call" },
  { "ExpExprParen", "expected an expression after '('" },
  { "MisCloseParenExpr", "missing closing ')' in the parenthesized expression" },

  { "ExpExprArgs", "expected an expression after the comma in the argument list" },
  { "MisCloseParenArgs", "expected closing ')' to end the argument list" },

  { "MisCloseBrace", "missing closing '}' for the table constructor" },
  { "MisCloseBracket", "missing closing ']' in the key" },
  { "ExpEqField1", "expected '=' after the key" },
  { "ExpExprField1", "expected an expression after '='" },
  { "ExpEqField2", "expected '=' after the field name" },
  { "ExpExprField2", "expected an expression after '='" },

  { "ExpDigitsHex", "expected one or more hexadecimal digits" },
  { "ExpDigitsPoint", "expected one or more digits after the decimal point" },
  { "ExpDigitsExpo", "expected one or more digits for the exponent" },
  { "MisTermDQuote", "missing terminating double quote for the string" },
  { "MisTermSQuote", "missing terminating single quote for the string" },
  { "MisTermLStr", "missing closing delimiter for the multi-line string (must have same '='s)" },
}

local function expect(patt, label)
  for i, labelinfo in ipairs(labels) do
    if labelinfo[1] == label then
      return patt + T(i)
    end
  end

  error("Label not found: " .. label)
end

-- creates an error message for the input string
local function syntaxerror (errorinfo, pos, msg)
  local l, c = lineno(errorinfo.subject, pos)
  local error_msg = "%s:%d:%d: syntax error, %s"
  return string.format(error_msg, errorinfo.filename, l, c, msg)
end

-- gets the farthest failure position
local function getffp (s, i, t)
  return t.ffp or i, t
end

-- gets the table that contains the error information
local function geterrorinfo ()
  return Cmt(Carg(1), getffp) * (C(V"OneWord") + Cc("EOF")) /
  function (t, u)
    t.unexpected = u
    return t
  end
end

-- creates an errror message using the farthest failure position
local function errormsg ()
  return geterrorinfo() /
  function (t)
    local p = t.ffp or 1
    local msg = "unexpected '%s', expecting %s"
    msg = string.format(msg, t.unexpected, t.expected)
    return nil, syntaxerror(t, p, msg)
  end
end

-- reports a syntactic error
local function report_error ()
  return errormsg()
end

-- sets the farthest failure position and the expected tokens
local function setffp (s, i, t, n)
  if not t.ffp or i > t.ffp then
    t.ffp = i
    t.list = {} ; t.list[n] = n
    t.expected = "'" .. n .. "'"
  elseif i == t.ffp then
    if not t.list[n] then
      t.list[n] = n
      t.expected = "'" .. n .. "', " .. t.expected
    end
  end
  return false
end

local function updateffp (name)
  return Cmt(Carg(1) * Cc(name), setffp)
end

-- regular combinators and auxiliary functions

local function token (pat, name)
  return pat * V"Skip" + updateffp(name) * P(false)
end

local function symb (str)
  return token (P(str), str)
end

local function kw (str)
  return token (P(str) * -V"idRest", str)
end

local function taggedCap (tag, pat)
  return Ct(Cg(Cp(), "pos") * Cg(Cc(tag), "tag") * pat)
end

local function unaryop (op, e)
  return { tag = "Op", pos = e.pos, [1] = op, [2] = e }
end

local function binaryop (e1, op, e2)
  if not op then
    return e1
  elseif op == "add" or
         op == "sub" or
         op == "mul" or
         op == "div" or
         op == "idiv" or
         op == "mod" or
         op == "pow" or
         op == "concat" or
         op == "band" or
         op == "bor" or
         op == "bxor" or
         op == "shl" or
         op == "shr" or
         op == "eq" or
         op == "lt" or
         op == "le" or
         op == "and" or
         op == "or" then
    return { tag = "Op", pos = e1.pos, [1] = op, [2] = e1, [3] = e2 }
  elseif op == "ne" then
    return unaryop ("not", { tag = "Op", pos = e1.pos, [1] = "eq", [2] = e1, [3] = e2 })
  elseif op == "gt" then
    return { tag = "Op", pos = e1.pos, [1] = "lt", [2] = e2, [3] = e1 }
  elseif op == "ge" then
    return { tag = "Op", pos = e1.pos, [1] = "le", [2] = e2, [3] = e1 }
  end
end

local function chainl (pat, sep, a)
  return Cf(pat * Cg(sep * pat)^0, binaryop) + a
end

local function chainl1 (pat, sep, label)
  return Cf(pat * Cg(sep * expect(pat, label))^0, binaryop)
end

local function sepby (pat, sep, tag)
  return taggedCap(tag, (pat * (sep * pat)^0)^-1)
end

local function sepby1 (pat, sep, tag)
  return taggedCap(tag, pat * (sep * pat)^0)
end

local function fix_str (str)
  str = string.gsub(str, "\\a", "\a")
  str = string.gsub(str, "\\b", "\b")
  str = string.gsub(str, "\\f", "\f")
  str = string.gsub(str, "\\n", "\n")
  str = string.gsub(str, "\\r", "\r")
  str = string.gsub(str, "\\t", "\t")
  str = string.gsub(str, "\\v", "\v")
  str = string.gsub(str, "\\\n", "\n")
  str = string.gsub(str, "\\\r", "\n")
  str = string.gsub(str, "\\'", "'")
  str = string.gsub(str, '\\"', '"')
  str = string.gsub(str, '\\\\', '\\')
  return str
end

-- grammar

local G = { V"Lua",
  Lua = V"Shebang"^-1 * V"Skip" * V"Chunk" * -1 + report_error();
  -- parser
  Chunk = V"Block";
  StatList = (symb(";") + V"Stat")^0;
  Var = V"Id";
  Id = taggedCap("Id", token(V"Name", "Name"));
  FunctionDef = kw("function") * V"FuncBody";
  FieldSep = symb(",") + symb(";");
  Field = taggedCap("Pair", (symb("[") * V"Expr" * expect(symb("]"), "MisCloseBracket") * expect(symb("="), "ExpEqField1") * expect(V"Expr", "ExpExprField1")) +
                    (taggedCap("String", token(V"Name", "Name")) * expect(symb("="), "ExpEqField2") * expect(V"Expr", "ExpExprField2"))) +
          V"Expr";
  FieldList = (V"Field" * (V"FieldSep" * V"Field")^0 * V"FieldSep"^-1)^-1;
  Constructor = taggedCap("Table", symb("{") * V"FieldList" * expect(symb("}"), "MisCloseBrace"));
  NameList = sepby1(V"Id", symb(","), "NameList");
  ExpList = sepby1(V"Expr", symb(","), "ExpList");
  FuncArgs = symb("(") * (V"Expr" * (symb(",") * V"Expr")^0)^-1 * symb(")") +
             V"Constructor" +
             taggedCap("String", token(V"String", "String"));
  Expr = V"SubExpr_1";
  SubExpr_1 = chainl1(V"SubExpr_2", V"OrOp", "ExpExprSub1");
  SubExpr_2 = chainl1(V"SubExpr_3", V"AndOp", "ExpExprSub2");
  SubExpr_3 = chainl1(V"SubExpr_4", V"RelOp", "ExpExprSub3");
  SubExpr_4 = chainl1(V"SubExpr_5", V"BOrOp", "ExpExprSub4");
  SubExpr_5 = chainl1(V"SubExpr_6", V"BXorOp", "ExpExprSub5");
  SubExpr_6 = chainl1(V"SubExpr_7", V"BAndOp", "ExpExprSub6");
  SubExpr_7 = chainl1(V"SubExpr_8", V"ShiftOp", "ExpExprSub7");
  SubExpr_8 = V"SubExpr_9" * V"ConOp" * expect(V"SubExpr_8", "ExpExprSub8") / binaryop +
              V"SubExpr_9";
  SubExpr_9 = chainl1(V"SubExpr_10", V"AddOp", "ExpExprSub9");
  SubExpr_10 = chainl1(V"SubExpr_11", V"MulOp", "ExpExprSub10");
  SubExpr_11 = V"UnOp" * expect(V"SubExpr_11", "ExpExprSub11") / unaryop +
              V"SubExpr_12";
  SubExpr_12 = V"SimpleExp" * (V"PowOp" * expect(V"SubExpr_11", "ExpExprSub12"))^-1 / binaryop;
  SimpleExp = taggedCap("Number", token(V"Number", "Number")) +
              taggedCap("String", token(V"String", "String")) +
              taggedCap("Nil", kw("nil")) +
              taggedCap("False", kw("false")) +
              taggedCap("True", kw("true")) +
              taggedCap("Dots", symb("...")) +
              V"FunctionDef" +
              V"Constructor" +
              V"SuffixedExp";
  SuffixedExp = Cf(V"PrimaryExp" * (
                  taggedCap("DotIndex", symb(".") * expect(taggedCap("String", token(V"Name", "Name")), "ExpNameDot")) +
                  taggedCap("ArrayIndex", symb("[") * V"Expr" * expect(symb("]"), "MisCloseBracketIndex")) +
                  taggedCap("Invoke", Cg(symb(":") * expect(taggedCap("String", token(V"Name", "Name")), "ExpNameColon") * expect(V"FuncArgs", "ExpFuncArgs"))) +
                  taggedCap("Call", V"FuncArgs")
                )^0, function (t1, t2)
                       if t2 then
                         if t2.tag == "Call" or t2.tag == "Invoke" then
                           local t = {tag = t2.tag, pos = t1.pos, [1] = t1}
                           for k, v in ipairs(t2) do
                             table.insert(t, v)
                           end
                           return t
                         else
                           return {tag = "Index", pos = t1.pos, [1] = t1, [2] = t2[1]}
                         end
                       end
                       return t1
                     end);
  PrimaryExp = V"Var" +
               taggedCap("Paren", symb("(") * expect(V"Expr", "ExpExprParen") * expect(symb(")"), "MisCloseParenExpr"));
  Block = taggedCap("Block", V"StatList" * V"RetStat"^-1);
  IfStat = taggedCap("If",
             kw("if") * expect(V"Expr", "ExpExprIf") * expect(kw("then"), "ExpThenIf") * V"Block" *
             (kw("elseif") * expect(V"Expr", "ExpExprEIf") * expect(kw("then"), "ExpThenEIf") * V"Block")^0 *
             (kw("else") * V"Block")^-1 *
             expect(kw("end"), "ExpEndIf"));
  WhileStat = taggedCap("While", kw("while") * expect(V"Expr", "ExpExprWhile") *
                expect(kw("do"), "ExpDoWhile") * V"Block" * expect(kw("end"), "ExpEndWhile"));
  DoStat = kw("do") * V"Block" * expect(kw("end"), "ExpEndDo") /
           function (t)
             t.tag = "Do"
             return t
           end;
  ForBody = expect(kw("do"), "ExpDoFor") * V"Block";
  ForNum = taggedCap("Fornum",
             V"Id" * symb("=") * expect(V"Expr", "ExpExprFor1") * expect(symb(","), "ExpCommaFor") *
             expect(V"Expr", "ExpExprFor2") * (symb(",") * expect(V"Expr", "ExpExprFor3"))^-1 *
             V"ForBody");
  ForGen = taggedCap("Forin", V"NameList" * expect(kw("in"), "ExpInFor") * expect(V"ExpList", "ExpEListFor") * V"ForBody");
  ForStat = kw("for") * expect(V"ForNum" + V"ForGen", "ExpForRange") * expect(kw("end"), "ExpEndFor");
  RepeatStat = taggedCap("Repeat", kw("repeat") * V"Block" *
                 expect(kw("until"), "ExpUntilRep") * expect(V"Expr", "ExpExprRep"));
  FuncName = Cf(V"Id" * (symb(".") * expect(taggedCap("String", token(V"Name", "Name")), "ExpNameFunc1"))^0,
             function (t1, t2)
               if t2 then
                 return {tag = "Index", pos = t1.pos, [1] = t1, [2] = t2}
               end
               return t1
             end) * (symb(":") * expect(taggedCap("String", token(V"Name", "Name")), "ExpNameFunc2"))^-1 /
             function (t1, t2)
               if t2 then
                 return {tag = "Index", pos = t1.pos, is_method = true, [1] = t1, [2] = t2}
               end
               return t1
             end;
  ParList = V"NameList" * (symb(",") * symb("...") * taggedCap("Dots", Cp()))^-1 /
            function (t, v)
              if v then table.insert(t, v) end
              return t
            end +
            symb("...") * taggedCap("Dots", Cp()) /
            function (v)
              return {v}
            end +
            P(true) / function () return {} end;
  -- Cc({}) generates a strange bug when parsing [[function t:a() end ; function t.a() end]]
  -- the bug is to add the parameter self to the second function definition
  --FuncBody = taggedCap("Function", symb("(") * (V"ParList" + Cc({})) * symb(")") * V"Block" * kw("end"));
  FuncBody = taggedCap("Function", expect(symb("("), "ExpOpenParenParams") * V"ParList" * expect(symb(")"), "MisCloseParenParams") * V"Block" * expect(kw("end"), "ExpEndFunc"));
  FuncStat = taggedCap("Set", kw("function") * expect(V"FuncName", "ExpFuncName") * V"FuncBody") /
             function (t)
               if t[1].is_method then table.insert(t[2][1], 1, {tag = "Id", [1] = "self"}) end
               t[1] = {t[1]}
               t[2] = {t[2]}
               return t
             end;
  LocalFunc = taggedCap("Localrec", kw("function") * expect(V"Id", "ExpNameLFunc") * V"FuncBody") /
              function (t)
                t[1] = {t[1]}
                t[2] = {t[2]}
                return t
              end;
  LocalAssign = taggedCap("Local", V"NameList" * ((symb("=") * expect(V"ExpList", "ExpEListLAssign")) + Ct(Cc())));
  LocalStat = kw("local") * expect(V"LocalFunc" + V"LocalAssign", "ExpDefLocal");
  LabelStat = taggedCap("Label", symb("::") * expect(token(V"Name", "Name"), "ExpLabelName") * expect(symb("::"), "MisCloseLabel"));
  BreakStat = taggedCap("Break", kw("break"));
  GoToStat = taggedCap("Goto", kw("goto") * expect(token(V"Name", "Name"), "ExpLabel"));
  RetStat = taggedCap("Return", kw("return") * (V"Expr" * (symb(",") * expect(V"Expr", "ExpExprCommaRet"))^0)^-1 * symb(";")^-1);
  ExprStat = Cmt(
             (V"SuffixedExp" *
                (Cc(function (...)
                           local vl = {...}
                           local el = vl[#vl]
                           table.remove(vl)
                           for k, v in ipairs(vl) do
                             if v.tag == "Id" or v.tag == "Index" then
                               vl[k] = v
                             else
                               -- invalid assignment
                               return false
                             end
                           end
                           vl.tag = "VarList"
                           vl.pos = vl[1].pos
                           return true, {tag = "Set", pos = vl.pos, [1] = vl, [2] = el}
                         end) * V"Assignment"))
             +
             (V"SuffixedExp" *
                (Cc(function (s)
                           if s.tag == "Call" or
                              s.tag == "Invoke" then
                             return true, s
                           end
                           -- invalid statement
                           return false
                         end)))
             , function (s, i, s1, f, ...) return f(s1, ...) end);
  Assignment = ((symb(",") * expect(V"SuffixedExp", "ExpLHSComma"))^1)^-1 * symb("=") * expect(V"ExpList", "ExpEListAssign");
  Stat = V"IfStat" + V"WhileStat" + V"DoStat" + V"ForStat" +
         V"RepeatStat" + V"FuncStat" + V"LocalStat" + V"LabelStat" +
         V"BreakStat" + V"GoToStat" + V"ExprStat";
  -- lexer
  Space = space^1;
  Equals = P"="^0;
  Open = "[" * Cg(V"Equals", "init") * "[" * P"\n"^-1;
  Close = "]" * C(V"Equals") * "]";
  CloseEQ = Cmt(V"Close" * Cb("init"),
            function (s, i, a, b) return a == b end);
  LongString = V"Open" * C((P(1) - V"CloseEQ")^0) * expect(V"Close", "MisTermLStr") /
               function (s, o) return s end;
  Comment = P"--" * V"LongString" / function () return end +
            P"--" * (P(1) - P"\n")^0;
  Skip = (V"Space" + V"Comment")^0;
  idStart = alpha + P("_");
  idRest = alnum + P("_");
  Keywords = P("and") + "break" + "do" + "elseif" + "else" + "end" +
             "false" + "for" + "function" + "goto" + "if" + "in" +
             "local" + "nil" + "not" + "or" + "repeat" + "return" +
             "then" + "true" + "until" + "while";
  Reserved = V"Keywords" * -V"idRest";
  Identifier = V"idStart" * V"idRest"^0;
  Name = -V"Reserved" * C(V"Identifier") * -V"idRest";
  Hex = (P("0x") + P("0X")) * expect(xdigit^1, "ExpDigitsHex");
  Expo = S("eE") * S("+-")^-1 * expect(digit^1, "ExpDigitsExpo");
  Float = (((digit^1 * P(".") * digit^0) +
          (P(".") * digit^1)) * V"Expo"^-1) +
          (digit^1 * V"Expo");
  Int = digit^1;
  Number = C(V"Hex" + V"Float" + V"Int") /
           function (n) return tonumber(n) end;
  ShortString = P'"' * C(((P'\\' * P(1)) + (P(1) - P'"'))^0) * expect(P'"', "MisTermDQuote") +
                P"'" * C(((P"\\" * P(1)) + (P(1) - P"'"))^0) * expect(P"'", "MisTermSQuote");
  String = V"LongString" + (V"ShortString" / function (s) return fix_str(s) end);
  OrOp = kw("or") / "or";
  AndOp = kw("and") / "and";
  RelOp = symb("~=") / "ne" +
          symb("==") / "eq" +
          symb("<=") / "le" +
          symb(">=") / "ge" +
          symb("<") / "lt" +
          symb(">") / "gt";
  BOrOp = symb("|") / "bor";
  BXorOp = symb("~") / "bxor";
  BAndOp = symb("&") / "band";
  ShiftOp = symb("<<") / "shl" +
            symb(">>") / "shr";
  ConOp = symb("..") / "concat";
  AddOp = symb("+") / "add" +
          symb("-") / "sub";
  MulOp = symb("*") / "mul" +
          symb("//") / "idiv" +
          symb("/") / "div" +
          symb("%") / "mod";
  UnOp = kw("not") / "not" +
         symb("-") / "unm" +
         symb("#") / "len" +
         symb("~") / "bnot";
  PowOp = symb("^") / "pow";
  Shebang = P"#" * (P(1) - P"\n")^0 * P"\n";
  -- for error reporting
  OneWord = V"Name" + V"Number" + V"String" + V"Reserved" + P("...") + P(1);
}

local function exist_label (env, scope, stm)
  local l = stm[1]
  for s=scope, 0, -1 do
    if env[s]["label"][l] then return true end
  end
  return false
end

local function set_label (env, label, pos)
  local scope = env.scope
  local l = env[scope]["label"][label]
  if not l then
    env[scope]["label"][label] = { name = label, pos = pos }
    return true
  else
    local msg = "label '%s' already defined at line %d"
    local line = lineno(env.errorinfo.subject, l.pos)
    msg = string.format(msg, label, line)
    return nil, syntaxerror(env.errorinfo, pos, msg)
  end
end

local function set_pending_goto (env, stm)
  local scope = env.scope
  table.insert(env[scope]["goto"], stm)
  return true
end

local function verify_pending_gotos (env)
  for s=env.maxscope, 0, -1 do
    for k, v in ipairs(env[s]["goto"]) do
      if not exist_label(env, s, v) then
        local msg = "no visible label '%s' for <goto>"
        msg = string.format(msg, v[1])
        return nil, syntaxerror(env.errorinfo, v.pos, msg)
      end
    end
  end
  return true
end

local function set_vararg (env, is_vararg)
  env["function"][env.fscope].is_vararg = is_vararg
end

local traverse_stm, traverse_exp, traverse_var
local traverse_block, traverse_explist, traverse_varlist, traverse_parlist

function traverse_parlist (env, parlist)
  local len = #parlist
  local is_vararg = false
  if len > 0 and parlist[len].tag == "Dots" then
    is_vararg = true
  end
  set_vararg(env, is_vararg)
  return true
end

local function traverse_function (env, exp)
  new_function(env)
  new_scope(env)
  local status, msg = traverse_parlist(env, exp[1])
  if not status then return status, msg end
  status, msg = traverse_block(env, exp[2])
  if not status then return status, msg end
  end_scope(env)
  end_function(env)
  return true
end

local function traverse_op (env, exp)
  local status, msg = traverse_exp(env, exp[2])
  if not status then return status, msg end
  if exp[3] then
    status, msg = traverse_exp(env, exp[3])
    if not status then return status, msg end
  end
  return true
end

local function traverse_paren (env, exp)
  local status, msg = traverse_exp(env, exp[1])
  if not status then return status, msg end
  return true
end

local function traverse_table (env, fieldlist)
  for k, v in ipairs(fieldlist) do
    local tag = v.tag
    if tag == "Pair" then
      local status, msg = traverse_exp(env, v[1])
      if not status then return status, msg end
      status, msg = traverse_exp(env, v[2])
      if not status then return status, msg end
    else
      local status, msg = traverse_exp(env, v)
      if not status then return status, msg end
    end
  end
  return true
end

local function traverse_vararg (env, exp)
  if not env["function"][env.fscope].is_vararg then
    local msg = "cannot use '...' outside a vararg function"
    return nil, syntaxerror(env.errorinfo, exp.pos, msg)
  end
  return true
end

local function traverse_call (env, call)
  local status, msg = traverse_exp(env, call[1])
  if not status then return status, msg end
  for i=2, #call do
    status, msg = traverse_exp(env, call[i])
    if not status then return status, msg end
  end
  return true
end

local function traverse_invoke (env, invoke)
  local status, msg = traverse_exp(env, invoke[1])
  if not status then return status, msg end
  for i=3, #invoke do
    status, msg = traverse_exp(env, invoke[i])
    if not status then return status, msg end
  end
  return true
end

local function traverse_assignment (env, stm)
  local status, msg = traverse_varlist(env, stm[1])
  if not status then return status, msg end
  status, msg = traverse_explist(env, stm[2])
  if not status then return status, msg end
  return true
end

local function traverse_break (env, stm)
  if not insideloop(env) then
    local msg = "<break> not inside a loop"
    return nil, syntaxerror(env.errorinfo, stm.pos, msg)
  end
  return true
end

local function traverse_forin (env, stm)
  begin_loop(env)
  new_scope(env)
  local status, msg = traverse_explist(env, stm[2])
  if not status then return status, msg end
  status, msg = traverse_block(env, stm[3])
  if not status then return status, msg end
  end_scope(env)
  end_loop(env)
  return true
end

local function traverse_fornum (env, stm)
  local status, msg
  begin_loop(env)
  new_scope(env)
  status, msg = traverse_exp(env, stm[2])
  if not status then return status, msg end
  status, msg = traverse_exp(env, stm[3])
  if not status then return status, msg end
  if stm[5] then
    status, msg = traverse_exp(env, stm[4])
    if not status then return status, msg end
    status, msg = traverse_block(env, stm[5])
    if not status then return status, msg end
  else
    status, msg = traverse_block(env, stm[4])
    if not status then return status, msg end
  end
  end_scope(env)
  end_loop(env)
  return true
end

local function traverse_goto (env, stm)
  local status, msg = set_pending_goto(env, stm)
  if not status then return status, msg end
  return true
end

local function traverse_if (env, stm)
  local len = #stm
  if len % 2 == 0 then
    for i=1, len, 2 do
      local status, msg = traverse_exp(env, stm[i])
      if not status then return status, msg end
      status, msg = traverse_block(env, stm[i+1])
      if not status then return status, msg end
    end
  else
    for i=1, len-1, 2 do
      local status, msg = traverse_exp(env, stm[i])
      if not status then return status, msg end
      status, msg = traverse_block(env, stm[i+1])
      if not status then return status, msg end
    end
    local status, msg = traverse_block(env, stm[len])
    if not status then return status, msg end
  end
  return true
end

local function traverse_label (env, stm)
  local status, msg = set_label(env, stm[1], stm.pos)
  if not status then return status, msg end
  return true
end

local function traverse_let (env, stm)
  local status, msg = traverse_explist(env, stm[2])
  if not status then return status, msg end
  return true
end

local function traverse_letrec (env, stm)
  local status, msg = traverse_exp(env, stm[2][1])
  if not status then return status, msg end
  return true
end

local function traverse_repeat (env, stm)
  begin_loop(env)
  local status, msg = traverse_block(env, stm[1])
  if not status then return status, msg end
  status, msg = traverse_exp(env, stm[2])
  if not status then return status, msg end
  end_loop(env)
  return true
end

local function traverse_return (env, stm)
  local status, msg = traverse_explist(env, stm)
  if not status then return status, msg end
  return true
end

local function traverse_while (env, stm)
  begin_loop(env)
  local status, msg = traverse_exp(env, stm[1])
  if not status then return status, msg end
  status, msg = traverse_block(env, stm[2])
  if not status then return status, msg end
  end_loop(env)
  return true
end

function traverse_var (env, var)
  local tag = var.tag
  if tag == "Id" then -- `Id{ <string> }
    return true
  elseif tag == "Index" then -- `Index{ expr expr }
    local status, msg = traverse_exp(env, var[1])
    if not status then return status, msg end
    status, msg = traverse_exp(env, var[2])
    if not status then return status, msg end
    return true
  else
    error("expecting a variable, but got a " .. tag)
  end
end

function traverse_varlist (env, varlist)
  for k, v in ipairs(varlist) do
    local status, msg = traverse_var(env, v)
    if not status then return status, msg end
  end
  return true
end

function traverse_exp (env, exp)
  local tag = exp.tag
  if tag == "Nil" or
     tag == "True" or
     tag == "False" or
     tag == "Number" or -- `Number{ <number> }
     tag == "String" then -- `String{ <string> }
    return true
  elseif tag == "Dots" then
    return traverse_vararg(env, exp)
  elseif tag == "Function" then -- `Function{ { `Id{ <string> }* `Dots? } block }
    return traverse_function(env, exp)
  elseif tag == "Table" then -- `Table{ ( `Pair{ expr expr } | expr )* }
    return traverse_table(env, exp)
  elseif tag == "Op" then -- `Op{ opid expr expr? }
    return traverse_op(env, exp)
  elseif tag == "Paren" then -- `Paren{ expr }
    return traverse_paren(env, exp)
  elseif tag == "Call" then -- `Call{ expr expr* }
    return traverse_call(env, exp)
  elseif tag == "Invoke" then -- `Invoke{ expr `String{ <string> expr* }
    return traverse_invoke(env, exp)
  elseif tag == "Id" or -- `Id{ <string> }
         tag == "Index" then -- `Index{ expr expr }
    return traverse_var(env, exp)
  else
    error("expecting an expression, but got a " .. tag)
  end
end

function traverse_explist (env, explist)
  for k, v in ipairs(explist) do
    local status, msg = traverse_exp(env, v)
    if not status then return status, msg end
  end
  return true
end

function traverse_stm (env, stm)
  local tag = stm.tag
  if tag == "Do" then -- `Do{ stat* }
    return traverse_block(env, stm)
  elseif tag == "Set" then -- `Set{ {lhs+} {expr+} }
    return traverse_assignment(env, stm)
  elseif tag == "While" then -- `While{ expr block }
    return traverse_while(env, stm)
  elseif tag == "Repeat" then -- `Repeat{ block expr }
    return traverse_repeat(env, stm)
  elseif tag == "If" then -- `If{ (expr block)+ block? }
    return traverse_if(env, stm)
  elseif tag == "Fornum" then -- `Fornum{ ident expr expr expr? block }
    return traverse_fornum(env, stm)
  elseif tag == "Forin" then -- `Forin{ {ident+} {expr+} block }
    return traverse_forin(env, stm)
  elseif tag == "Local" then -- `Local{ {ident+} {expr+}? }
    return traverse_let(env, stm)
  elseif tag == "Localrec" then -- `Localrec{ ident expr }
    return traverse_letrec(env, stm)
  elseif tag == "Goto" then -- `Goto{ <string> }
    return traverse_goto(env, stm)
  elseif tag == "Label" then -- `Label{ <string> }
    return traverse_label(env, stm)
  elseif tag == "Return" then -- `Return{ <expr>* }
    return traverse_return(env, stm)
  elseif tag == "Break" then
    return traverse_break(env, stm)
  elseif tag == "Call" then -- `Call{ expr expr* }
    return traverse_call(env, stm)
  elseif tag == "Invoke" then -- `Invoke{ expr `String{ <string> } expr* }
    return traverse_invoke(env, stm)
  else
    error("expecting a statement, but got a " .. tag)
  end
end

function traverse_block (env, block)
  local l = {}
  new_scope(env)
  for k, v in ipairs(block) do
    local status, msg = traverse_stm(env, v)
    if not status then return status, msg end
  end
  end_scope(env)
  return true
end


local function traverse (ast, errorinfo)
  assert(type(ast) == "table")
  assert(type(errorinfo) == "table")
  local env = { errorinfo = errorinfo, ["function"] = {} }
  new_function(env)
  set_vararg(env, true)
  local status, msg = traverse_block(env, ast)
  if not status then return status, msg end
  end_function(env)
  status, msg = verify_pending_gotos(env)
  if not status then return status, msg end
  return ast
end

function parser.parse (subject, filename)
  local errorinfo = { subject = subject, filename = filename }
  lpeg.setmaxstack(1000)
  local ast, error_msg = lpeg.match(G, subject, nil, errorinfo)
  if not ast then return ast, error_msg end
  return traverse(ast, errorinfo)
end

return parser
