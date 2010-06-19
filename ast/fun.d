module ast.fun;

import ast.namespace, ast.base, ast.scopes, ast.variable, asmfile, ast.types;

class Function : Namespace, Tree {
  string name;
  FunctionType type;
  Scope _scope;
  bool extern_c = false;
  string toString() { return Format("fun ", name, " <- ", sup); }
  // add parameters to namespace
  int _framestart;
  FunCall mkCall() { return new FunCall; }
  int fixup() {
    // cdecl: 0 old ebp, 4 return address, 8 parameters .. I think.
    add(new Variable(Single!(SizeT), "__old_ebp", 0));
    add(new Variable(Single!(SizeT), "__fun_ret", 4));
    int cur = _framestart = 8;
    // TODO: alignment
    foreach (param; type.params) {
      if (param._1) {
        _framestart += param._0.size;
        add(new Variable(param._0, param._1, cur));
      }
      cur += param._0.size;
    }
    return cur;
  }
  string mangleSelf() {
    if (extern_c || name == "main")
      return name;
    else
      return sup.mangle(name, type);
  }
  int framestart() {
    return _framestart;
  }
  override {
    string mangle(string name, Type type) {
      return mangleSelf() ~ "_" ~ name;
    }
    void emitAsm(AsmFile af) {
      af.put(".globl "~mangleSelf);
      af.put(".type "~mangleSelf~", @function");
      af.put(mangleSelf~": ");
      af.put("pushl %ebp");
      af.put("movl %esp, %ebp");
      withTLS(namespace, this, _scope.emitAsm(af));
      af.put("movl %ebp, %esp");
      af.put("popl %ebp");
      af.put("ret");
    }
    Stuple!(Type, string, int)[] stackframe() {
      Stuple!(Type, string, int)[] res;
      foreach (obj; field)
        if (auto var = cast(Variable) obj._1)
          res ~= stuple(var.type, var.name, var.baseOffset);
      return res;
    }
  }
}

class FunCall : Expr {
  Expr[] params;
  Function fun;
  override void emitAsm(AsmFile af) {
    callFunction(fun, params, af);
  }
  override Type valueType() {
    return fun.type.ret;
  }
}

import tools.log;
void callFunction(Function fun, Expr[] params, AsmFile dest) {
  // dest.put("int $3");
  assert(fun.type.ret.size == 4 || cast(Void) fun.type.ret, Format("Can't return ", fun.type, "!"));
  dest.comment("Begin call to ", fun);
  if (params.length) {
    foreach_reverse (param; params) {
      dest.comment("Push ", param);
      param.emitAsm(dest);
    }
  }
  dest.put("call "~fun.mangleSelf);
  foreach (param; params) {
    dest.sfree(param.valueType().size);
  }
  if (!cast(Void) fun.type.ret) {
    dest.pushStack("%eax", fun.type.ret);
  }
}

class FunctionType : Type {
  Type ret;
  Stuple!(Type, string)[] params;
  override int size() { assert(false); }
  override {
    string mangle() {
      string res = "function_to_"~ret.mangle();
      if (!params.length) return res;
      foreach (i, param; params) {
        if (!i) res ~= "_of_";
        else res ~= "_and_";
        res ~= param._0.mangle();
      }
      return res;
    }
    string toString() { return Format("Function of ", params, " => ", ret); }
  }
}

import parseBase;
// generalized to reuse for nested funs
Object gotGenericFunDef(T)(T fun, Namespace sup_override, ref string text, ParseCb cont, ParseCb rest) {
  Type ptype;
  auto t2 = text;
  New(fun.type);
  string parname;
  error = null;
  auto ns = namespace();
  assert(ns);
  if (test(fun.type.ret = cast(Type) rest(t2, "type")) &&
      t2.gotIdentifier(fun.name) &&
      t2.accept("(") &&
      // TODO: function parameters belong on the stackframe
      t2.bjoin(
        test(ptype = cast(Type) rest(t2, "type")) && (t2.gotIdentifier(parname) || ((parname = null), true)),
        t2.accept(","),
        { fun.type.params ~= stuple(ptype, parname); }
      ) &&
      t2.accept(")")
    )
  {
    fun.fixup;
    auto backup = namespace();
    scope(exit) namespace.set(backup);
    namespace.set(fun);
    ns.add(fun);
    fun.sup = sup_override?sup_override:ns;
    text = t2;
    if (rest(text, "tree.scope", &fun._scope)) return fun;
    else throw new Exception("Couldn't parse function scope at '"~text.next_text()~"'");
  } else return null;
}

Object gotFunDef(ref string text, ParseCb cont, ParseCb rest) {
  auto fun = new Function;
  return gotGenericFunDef(fun, cast(Namespace) null, text, cont, rest);
}

mixin DefaultParser!(gotFunDef, "tree.fundef");

import ast.parse, ast.static_arrays;
Object gotCallExpr(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  return lhs_partial.using = delegate Object(Function fun) {
    auto fc = fun.mkCall();
    fc.fun = fun;
    Expr ex;
    int param_offset;
    if (t2.accept("(") &&
        t2.bjoin(
          !!rest(t2, "tree.expr", &ex, (Expr ex) {
            if (param_offset !< fun.type.params.length)
              throw new Exception(Format(
                "Extraneous parameter for ", fun, ": ", ex
              ));
            if (cast(Variadic) fun.type.params[param_offset]._0) {
              // why are you using static arrays as parameters anyway?
              return !cast(StaticArray) ex.valueType();
            } else {
              // logln("Try ", ex.valueType(), " into ", fun.type.params[param_offset]._0);
              if (ex.valueType() != fun.type.params[param_offset]._0)
                // TODO: set error
                return false;
              param_offset ++;
              return true;
            }
          }),
          t2.accept(","),
          { fc.params ~= ex; },
          true
        ))
    {
      if (fun.type.params.length &&
        cast(Variadic) fun.type.params[$-1]._0
      ) {
        param_offset ++;
      }
      
      if (param_offset < fun.type.params.length) {
        throw new Exception(Format(
          "Not enough parameters for ", fc, ": ",
          fc.params, " at ", t2.next_text(), "!"
        ));
      }
      if (!t2.accept(")"))
        throw new Exception("Missing closing bracket at "~t2.next_text());
      text = t2;
      return fc;
    }
    else throw new Exception("While parsing arguments for call to "~fun.toString()~": "~t2.next_text());
  };
}
mixin DefaultParser!(gotCallExpr, "tree.rhs_partial.funcall", null, true);
