module ast.structfuns;

import ast.fun, ast.nestfun, ast.base, ast.structure, ast.variable,
  ast.properties, ast.pointer, ast.dg, ast.namespace, tools.base: This,
  This_fn, rmSpace;

import ast.modules;
Object gotStructFunDef(ref string text, ParseCb cont, ParseCb rest) {
  /*auto rs = fastcast!(RelNamespace)~ namespace();
  if (!rs)
    throw new Exception(Format("Fail: namespace is "[], namespace(), ". "[]));*/
  auto rs = namespace().get!(RelNamespace);
  if (!rs)
    throw new Exception(Format("Fail: no relns beneath "[], namespace(), ". "[]));
  auto fun = fastalloc!(RelFunction)(rs);
  
  if (auto res = gotGenericFunDef(fun, cast(Namespace) null, true, text, cont, rest)) {
    auto tr = fastcast!(Tree) (res);
    auto he = namespace().get!(HandlesEmits);
    if (!he || !he.handledEmit(tr))
      fastcast!(Module) (current_module()).entries ~= tr;
    return res;
  } else return null;
}
mixin DefaultParser!(gotStructFunDef, "struct_member.struct_fundef"[]);

import ast.vardecl, ast.assign;
class RelFunCall : FunCall, RelTransformable {
  Expr baseptr;
  this(Expr ex) {
    baseptr = ex;
  }
  mixin defaultIterate!(baseptr, params);
  override RelFunCall dup() {
    auto res = fastalloc!(RelFunCall)(baseptr?baseptr.dup:null);
    res.fun = fun;
    res.params = params.dup;
    foreach (ref entry; params) entry = entry.dup;
    return res;
  }
  override Object transform(Expr base) {
    // if (baseptr) { logln("RelFunCall was pretransformed: "[], baseptr, "; new base would be ", base); fail; }
    // I AM REALLY REALLY NOT SURE ABOUT THIS
    // TODO: smother in asserts
    if (baseptr) return this;
    if (!base) fail;
    auto res = dup();
    res.baseptr = base;
    return res;
  }
  override void emitLLVM(LLVMFile lf) {
    if (!baseptr) {
      logln("Untransformed rel-funcall: "[], this);
      fail;
    }
    if (auto lv = fastcast!(LValue) (baseptr)) {
      callDg(lf, fun.type.ret, params,
        fastalloc!(DgConstructExpr)(fun.getPointer(), fastalloc!(RefExpr)(lv)));
    } else {
      // allocate a temporary
      auto bt = baseptr.valueType();
      auto bts=typeToLLVM(bt);
      auto bp = alloca(lf, "1", bts);
      put(lf, "store ", bts, " ", save(lf, baseptr), ", ", bts, "* ", bp);
      callDg(lf, fun.type.ret, params,
        fastalloc!(DgConstructExpr)(fun.getPointer(), fastalloc!(LLVMValue)(bp, fastalloc!(Pointer)(bt))));
    }
  }
  override IType valueType() {
    return fun.type.ret;
  }
}

class RelExtensibleOverloadWrapper : OverloadSet, RelTransformable {
  this(string name, Function[] funs...) { super(name, funs); }
  override {
    Object transform(Expr ex) {
      foreach (ref fun; funs) {
        if (auto rt = fastcast!(RelTransformable) (fun))
          fun = fastcast!(Function) (rt.transform(ex));
      }
      return this;
    }
    Extensible extend(Extensible ex) {
      auto os = fastcast!(OverloadSet) (super.extend(ex));
      if (!os) fail;
      return fastalloc!(RelExtensibleOverloadWrapper)(os.name, os.funs);
    }
  }
}

class RelFunction : Function, RelTransformable, HasInfo {
  Expr baseptr; // unique per instance
  IType basetype; // for mangling purposes
  RelNamespace context;
  Expr bp_cache;
  bool autogenerated; // was generated by the compiler
  private this() { }
  this(RelNamespace rn) {
    context = rn;
    basetype = fastcast!(IType)~ rn;
    assert(!!basetype);
  }
  override {
    RelFunction alloc() { return new RelFunction; }
    Expr getPointer() { return fastalloc!(FunSymbol)(this, fastcast!(hasRefType)(context).getRefType()); }
    Argument[] getParams(bool implicits) {
      auto res = super.getParams(implicits);
      if (implicits) res ~= Argument(fastcast!(hasRefType)(context).getRefType(), "__base_ptr");
      return res;
    }
    RelFunction flatdup() {
      auto res = fastcast!(RelFunction) (super.flatdup());
      res.context = context;
      res.baseptr = baseptr?baseptr.dup:null;
      res.basetype = basetype;
      return res;
    }
    RelFunction dup() {
      auto res = fastcast!(RelFunction) (super.dup());
      res.context = context;
      res.baseptr = baseptr?baseptr.dup:null;
      res.basetype = basetype;
      return res;
    }
    Object transform(Expr base) {
      if (baseptr) {
        debug logln("WARN: RelFun was already transformed with ", baseptr, ", new ", base);
        // fail;
      }
      assert(!!fastcast!(RelNamespace) (basetype));
      auto res = flatdup();
      if (!base) fail;
      res.baseptr = base;
      return res;
    }
    Extensible extend(Extensible e2) {
      auto res = super.extend(e2);
      if (!res) return null;
      auto os = fastcast!(OverloadSet) (res);
      if (!os || fastcast!(RelTransformable) (res)) return res;
      return fastalloc!(RelExtensibleOverloadWrapper)(os.name, os.funs);
    }
    Extensible simplify() { return this; }
  }
  FunctionPointer typeAsFp() {
    auto res = new FunctionPointer(this);
    if (auto rnfb = fastcast!(RelNamespaceFixupBase) (context))
      res.args ~= Argument(rnfb.genCtxType(context));
    else
      res.args ~= Argument(fastalloc!(Pointer)(basetype));
    return res;
  }
  void iterate(void delegate(ref Iterable) dg, IterMode mode = IterMode.Lexical) {
    super.iterate(dg, mode);
    defaultIterate!(baseptr).iterate(dg, mode);
  }
  override {
    string mangleSelf() {
      return qformat(basetype.mangle(), "_", super.mangleSelf());
    }
    string getInfo() { return Format(name, " under "[], context); }
    string mangle(string name, IType type) {
      return mangleSelf() ~ (type?("_" ~ type.mangle()):""[])~"_"~name;
    }
    FunCall mkCall() {
      auto res = fastalloc!(RelFunCall)(baseptr);
      res.fun = this;
      return res;
    }
    import ast.aliasing;
    int fixup() {
      auto id = super.fixup();
      if (!fastcast!(hasRefType) (context))
        logln("bad context: "[], context, " is not reftype"[]);
      
      auto bp = fastcast!(Expr)(lookup("__base_ptr"));
      if (!bp) {
        logln("in ", this);
        logln("field = ", field);
        fail;
      }
      // auto bp = fastalloc!(Variable)((fastcast!(hasRefType) (context)).getRefType(), id++, "__base_ptr");
      // add(bp);
      
      if (fastcast!(Pointer)~ bp.valueType())
        add(fastalloc!(LValueAlias)(fastalloc!(DerefExpr)(bp), "this"[]));
      return id;
    }
    Object lookup(string name, bool local = false) {
      auto res = super.lookup(name, true);
      if (res) return res;
      else if (local) return null;
      
      if (!bp_cache) {
        auto bp = fastcast!(Expr) (lookup("__base_ptr"[], true));
        if (bp) {
          if (auto ptr = fastcast!(Pointer) (bp.valueType())) bp = fastalloc!(DerefExpr)(bp);
          bp_cache = bp;
        }
      }
      if (bp_cache) {
        if (auto res = context.lookupRel(name, bp_cache))
          return res;
      }
      
      return super.lookup(name, false);
    }
  }
}

// &foo.fun, stolen from ast.nestfun
class StructFunRefExpr : mkDelegate {
  RelFunction fun;
  this(RelFunction fun) {
    this.fun = fun;
    // logln("base ptr is "[], fun.baseptr);
    if (!fun.baseptr)
      fail;
    super(fun.getPointer(), fastalloc!(RefExpr)(fastcast!(CValue)~ fun.baseptr));
  }
  override typeof(this) dup() { return new typeof(this)(fun); }
  override string toString() {
    return Format("&"[], fun.baseptr, "."[], fun);
  }
  override IType valueType() {
    return fastalloc!(Delegate)(fun.type.ret, fun.type.params);
  }
}

Object gotStructfunRefExpr(ref string text, ParseCb cont, ParseCb rest) {
  string ident;
  RelFunction rf;
  auto propbackup = propcfg().withCall;
  propcfg().withCall = false;
  scope(exit) propcfg().withCall = propbackup;
  if (!rest(text, "tree.expr _tree.expr.arith"[], &rf))
    return null;
  
  return fastalloc!(StructFunRefExpr)(rf);
}
mixin DefaultParser!(gotStructfunRefExpr, "tree.expr.dg_struct_ref"[], "21010"[], "&"[]);

static this() {
  getOpCall = delegate Object(Object obj) {
    auto ex = fastcast!(Expr) (obj); if (!ex) return null;
    auto st = fastcast!(Structure) (resolveType(ex.valueType()));
    if (!st) return null;
    auto oc = st.lookupRel("opCall", ex);
    if (!oc) return null;
    return oc;
  };
}
