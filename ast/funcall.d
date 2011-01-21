module ast.funcall;

import ast.fun, ast.base;

class NamedArg : Expr {
  Expr base;
  string name;
  this(string name, Expr base) { this.name = name; this.base = base; }
  override {
    IType valueType() { return base.valueType(); }
    NamedArg dup() { return new NamedArg(name, base.dup); }
    mixin defaultIterate!(base);
    void emitAsm(AsmFile af) {
      logln("Named argument ", name, " could not be assigned to a function call! ");
      fail();
    }
  }
}

Object gotNamedArg(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  string name;
  if (!t2.gotIdentifier(name)) return null;
  if (!t2.accept("=>")) return null;
  Expr base;
  if (!rest(t2, "tree.expr", &base))
    t2.failparse("Could not get base expression for named argument '", name, "'");
  text = t2;
  return new NamedArg(name, base);
}
mixin DefaultParser!(gotNamedArg, "tree.expr.named_arg", "25");

bool matchedCallWith(Expr arg, Stuple!(IType, string)[] params, ref Expr[] res, string info = null, string text = null) {
  Expr[string] nameds;
  void removeNameds(ref Iterable it) {
    if (auto ex = cast(Expr) it) {
      if (auto tup = cast(AstTuple) ex.valueType()) {
        // filter out nameds from the tuple.
        auto exprs = getTupleEntries(ex);
        bool gotNamed;
        foreach (subexpr; exprs) if (auto na = cast(NamedArg) subexpr) {
          gotNamed = true; break;
        }
        if (gotNamed) {
          Expr[] left;
          foreach (subexpr; exprs)
            if (auto na = cast(NamedArg) subexpr)
              nameds[na.name] = na.base;
            else
              left ~= subexpr;
          it = cast(Iterable) mkTupleExpr(left);
        }
      }
    }
  }
  {
    Iterable forble = arg;
    removeNameds(forble);
    arg = cast(Expr) forble;
  }
  
  Expr[] args;
  args ~= arg;
  if (nameds.length) logln("nameds: ", nameds);
  Expr[] flatten(Expr ex) {
    if (cast(AstTuple) ex.valueType())
      return getTupleEntries(ex);
    else
      return null;
  }
  foreach (i, tuple; params) {
    auto type = tuple._0, name = tuple._1;
    type = resolveType(type);
    if (cast(Variadic) type) {
      foreach (ref rest_arg; args)
        if (!gotImplicitCast(rest_arg, (IType it) { return !cast(StaticArray) it; }))
          throw new Exception(Format("Invalid argument to variadic: ", rest_arg));
      res ~= args;
      args = null;
      break;
    }
    IType[] tried;
    if (auto p = name in nameds) {
      auto ex = *p, backup = ex;
      if (!gotImplicitCast(ex, type, (IType it) {
        tried ~= it;
        return test(it == type);
      }))
        text.failparse("Couldn't match named argument ", name, " of ", backup.valueType(), " to function call '", info, "', ", type, "; tried ", tried);
      res ~= ex;
      continue;
    }
    // TODO: default values
    if (!args.length) {
      throw new Exception(Format("Not enough parameters for '", info, "'; left over ", type, "!"));
    }
  retry:
    auto ex = args.take();
    auto backup = ex;
    
    if (!gotImplicitCast(ex, type, (IType it) {
      tried ~= it;
      return test(it == type);
    })) {
      Expr[] list;
      if (gotImplicitCast(ex, (IType it) { return !!cast(Tuple) it; }) && (list = flatten(ex), !!list)) {
        args = list ~ args;
        goto retry;
      } else {
        text.failparse("Couldn't match ", backup.valueType(), " to function call '", info, "', ", params[i], " (", i, "); tried ", tried);
      }
    }
    res ~= ex;
  }
  Expr[] flat;
  void recurse(Expr ex) {
    if (cast(AstTuple) ex.valueType())
      foreach (entry; flatten(ex)) recurse(entry);
    else flat ~= ex;
  }
  foreach (arg2; args) recurse(arg2);
  if (flat.length) {
    // logln("flattened to ", flat);
    // text.failparse("Extraneous parameters to '", info, "' of ", params, ": ", args);
    text.setError("Extraneous parameters to '", info, "' of ", params, ": ", args);
    return false;
  }
  return true;
}

import ast.properties;
import ast.tuple_access, ast.tuples, ast.casting, ast.fold, ast.tuples: AstTuple = Tuple;
bool matchCall(ref string text, string info, Stuple!(IType, string)[] params, ParseCb rest, ref Expr[] res) {
  Expr arg;
  auto backup_text = text; 
  if (!backup_text.length) return false; // wat
  // speed opt - a call can only begin
  // with one of those separating tokens
  const string valid_call_start_tokens = "( \r\n\t";
  bool token_match;
  foreach (ch; valid_call_start_tokens)
    if (text.startsWith([ch])) { token_match = true; break; }
  if (!token_match) return false;
  
  bool isTuple;
  {
    auto t2 = text;
    if (t2.accept("(")) isTuple = true;
  }
  
  // Only do this if we actually expect a tuple _literal_
  // properties on tuple _variables_ are valid!
  auto backup = *propcfg.ptr();
  scope(exit) *propcfg.ptr() = backup;
  if (isTuple) propcfg().withTuple = false;
    
  if (!rest(text, "tree.expr _tree.expr.arith", &arg)) {
    return false;
  }
  return matchedCallWith(arg, params, res, info, backup_text);
}

Expr buildFunCall(Function fun, Expr arg, string info) {
  auto fc = fun.mkCall();
  if (!matchedCallWith(arg, fun.type.params, fc.params, info))
    return null;
  return fc;
}

import ast.parse, ast.static_arrays;
Object gotCallExpr(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  return lhs_partial.using = delegate Object(Function fun) {
    auto fc = fun.mkCall();
    auto params = fun.getParams();
    resetError();
    if (!matchCall(t2, fun.name, params, rest, fc.params)) {
      if (t2.accept("("))
        text.failparse("Failed to call function: ", error()._1);
      auto t3 = t2;
      // valid call terminators
      if (params.length || !t3.accept(";"))
        return null;
    }
    text = t2;
    return fc;
  };
}
mixin DefaultParser!(gotCallExpr, "tree.rhs_partial.funcall");

class FpCall : Expr {
  Expr fp;
  Expr[] params;
  this() { }
  mixin DefaultDup!();
  mixin defaultIterate!(params);
  override void emitAsm(AsmFile af) {
    auto fntype = cast(FunctionPointer) fp.valueType();
    callFunction(af, fntype.ret, params, fp);
  }
  override IType valueType() {
    return (cast(FunctionPointer) fp.valueType()).ret;
  }
}

Object gotFpCallExpr(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  return lhs_partial.using = delegate Object(Expr ex) {
    auto fptype = cast(FunctionPointer) ex.valueType();
    if (!fptype) return null;
    
    auto fc = new FpCall;
    fc.fp = ex;
    
    if (!matchCall(t2, Format("delegate ", ex), fptype.args, rest, fc.params))
      return null;
    
    text = t2;
    return fc;
  };
}
mixin DefaultParser!(gotFpCallExpr, "tree.rhs_partial.fpcall");

import ast.dg;
class DgCall : Expr {
  Expr dg;
  Expr[] params;
  mixin DefaultDup!();
  mixin defaultIterate!(dg, params);
  override void emitAsm(AsmFile af) {
    auto dgtype = cast(Delegate) dg.valueType();
    callDg(af, dgtype.ret, params, dg);
  }
  override IType valueType() {
    return (cast(Delegate) dg.valueType()).ret;
  }
}

Object gotDgCallExpr(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  return lhs_partial.using = delegate Object(Expr ex) {
    auto dgtype = cast(Delegate) ex.valueType();
    if (!dgtype) return null;
    
    auto dc = new DgCall;
    dc.dg = ex;
    if (!matchCall(t2, Format("delegate ", ex), dgtype.args, rest, dc.params))
      return null;
    text = t2;
    return dc;
  };
}
mixin DefaultParser!(gotDgCallExpr, "tree.rhs_partial.dgcall");
