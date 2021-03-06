module ast.arrays;

import ast.base, ast.types, ast.static_arrays, ast.returns, ast.tuples, tools.base: This, This_fn, rmSpace;

import dwarf2;
// ptr, length
class Array_ : Type, RelNamespace, Dwarf2Encodable, ReferenceType {
  IType elemType;
  this() { }
  this(IType et) { elemType = forcedConvert(et); }
  IType proxyCache;
  string elemtypecmp, lltypecache;
  override {
    // bool isComplete() { return elemType.isComplete; }
    bool isComplete() { return true; /* size not determined by element size! */ }
    IType proxyType() { if (proxyCache) return proxyCache; if (auto ep = elemType.proxyType()) { proxyCache = fastalloc!(Array)(ep); return proxyCache; } return null; }
    string llvmSize() {
      if (nativePtrSize == 4) return "8";
      fail;
    }
    string llvmType() {
      auto tt = elemType.llvmType();
      if (elemtypecmp != tt) {
        elemtypecmp = tt;
        
        if (nativePtrSize == 4) lltypecache = qformat("{i32, ", typeToLLVM(fastalloc!(Pointer)(elemType), true), "}");
        else fail;
      }
      return lltypecache;
    }
    bool isTempNamespace() { return false; }
    Object lookupRel(string str, Expr base, bool isDirectLookup = true) {
      int idx;
      if (readIndexShorthand(str, idx))
        return fastcast!(Object) (lookupOp("index"[], base, mkInt(idx)));
      return null;
    }
    string mangle() {
      return "array_of_"~elemType.mangle();
    }
    string toString() { return Format(elemType, "[]"[]); }
    int opEquals(IType ty) {
      if (!super.opEquals(ty)) return false;
      ty = resolveType(ty);
      return (fastcast!(Array) (ty)).elemType == elemType;
    }
    bool isPointerLess() { return false; }
    bool canEncode() {
      auto d2e = fastcast!(Dwarf2Encodable)(resolveType(elemType));
      return d2e && d2e.canEncode();
    }
    Dwarf2Section encode(Dwarf2Controller dwarf2) {
      auto elempref = registerType(dwarf2, fastcast!(Dwarf2Encodable) (fastalloc!(Pointer)(resolveType(elemType))));
      auto sizeref = registerType(dwarf2, Single!(SysInt));
      auto sect = fastalloc!(Dwarf2Section)(dwarf2.cache.getKeyFor("structure type"[]));
      with (sect) {
        data ~= ".int\t8\t/* byte size */";
        auto len = fastalloc!(Dwarf2Section)(dwarf2.cache.getKeyFor("structure member"[]));
        with (len) {
          data ~= dwarf2.strings.addString("length"[]);
          data ~= sizeref;
          data ~= ".byte\t1f - 0f\t/* size */";
          data ~= "0:";
          data ~= ".byte\t0x23\t/* DW_OP_plus_uconst */";
          data ~= ".uleb128\t0x0\t/* offset */";
          data ~= "1:";
        }
        sub ~= len;
        auto ptr = fastalloc!(Dwarf2Section)(dwarf2.cache.getKeyFor("structure member"[]));
        with (ptr) {
          data ~= dwarf2.strings.addString("ptr"[]);
          data ~= elempref;
          data ~= ".byte\t1f - 0f\t/* size */";
          data ~= "0:";
          data ~= ".byte\t0x23\t/* DW_OP_plus_uconst */";
          data ~= ".uleb128\t0x4\t/* offset */";
          data ~= "1:";
        }
        sub ~= ptr;
      }
      return sect;
    }
  }
}

final class Array : Array_ {
  static const isFinal = true;
  this() { super(); }
  this(IType it) { super(it); }
}

// ptr, length, capacity
class ExtArray : Type, RelNamespace, Dwarf2Encodable, ReferenceType {
  IType elemType;
  bool freeOnResize;
  this() { }
  this(IType et, bool fOR) { elemType = forcedConvert(et); freeOnResize = fOR; }
  override {
    bool isTempNamespace() { return false; }
    IType proxyType() { if (auto ep = elemType.proxyType()) return new ExtArray(ep, freeOnResize); return null; }
    Object lookupRel(string str, Expr base, bool isDirectLookup = true) {
      int idx;
      if (readIndexShorthand(str, idx))
        return fastcast!(Object) (lookupOp("index"[], base, mkInt(idx)));
      return null;
    }
    string llvmSize() {
      if (nativePtrSize == 4) return "12";
      fail;
    }
    string llvmType() {
      scope p = new Pointer(elemType);
      // auto p = fastalloc!(Pointer)(elemType);
      if (nativePtrSize == 4) return qformat("{i32, i32, ", typeToLLVM(p, true), "}");
      fail;
    }
    string mangle() {
      return qformat("rich_"[], freeOnResize?"auto_"[]:null, "array_of_"[], elemType.mangle());
    }
    int opEquals(IType ty) {
      if (!super.opEquals(ty)) return false;
      ty = resolveType(ty);
      auto ea = fastcast!(ExtArray) (ty);
      return ea.elemType == elemType && ea.freeOnResize == freeOnResize;
    }
    string toString() {
      return Format(elemType, "["[], freeOnResize?"auto ":""[], "~]"[]);
    }
    // copypaste from above :D
    bool canEncode() {
      auto d2e = fastcast!(Dwarf2Encodable)(resolveType(elemType));
      return d2e && d2e.canEncode();
    }
    Dwarf2Section encode(Dwarf2Controller dwarf2) {
      auto elempref = registerType(dwarf2, fastcast!(Dwarf2Encodable) (fastalloc!(Pointer)(resolveType(elemType))));
      auto sizeref = registerType(dwarf2, Single!(SysInt));
      auto sect = fastalloc!(Dwarf2Section)(dwarf2.cache.getKeyFor("structure type"[]));
      with (sect) {
        data ~= ".int\t12\t/* byte size */";
        auto cap = fastalloc!(Dwarf2Section)(dwarf2.cache.getKeyFor("structure member"[]));
        with (cap) {
          data ~= dwarf2.strings.addString("capacity"[]);
          data ~= sizeref;
          data ~= ".byte\t1f - 0f\t/* size */";
          data ~= "0:";
          data ~= ".byte\t0x23\t/* DW_OP_plus_uconst */";
          data ~= ".uleb128\t0x0\t/* offset */";
          data ~= "1:";
        }
        sub ~= cap;
        auto len = fastalloc!(Dwarf2Section)(dwarf2.cache.getKeyFor("structure member"[]));
        with (len) {
          data ~= dwarf2.strings.addString("length"[]);
          data ~= sizeref;
          data ~= ".byte\t1f - 0f\t/* size */";
          data ~= "0:";
          data ~= ".byte\t0x23\t/* DW_OP_plus_uconst */";
          data ~= ".uleb128\t0x4\t/* offset */";
          data ~= "1:";
        }
        sub ~= len;
        auto ptr = fastalloc!(Dwarf2Section)(dwarf2.cache.getKeyFor("structure member"[]));
        with (ptr) {
          data ~= dwarf2.strings.addString("ptr"[]);
          data ~= elempref;
          data ~= ".byte\t1f - 0f\t/* size */";
          data ~= "0:";
          data ~= ".byte\t0x23\t/* DW_OP_plus_uconst */";
          data ~= ".uleb128\t0x8\t/* offset */";
          data ~= "1:";
        }
        sub ~= ptr;
      }
      return sect;
    }
  }
}

import ast.structfuns, ast.modules, ast.aliasing, ast.properties, ast.scopes, ast.assign;
Stuple!(IType, bool, Module, IType)[] cache;
bool[IType] isArrayStructType;
IType arrayAsStruct(IType base, bool rich) {
  auto mod = fastcast!(Module) (current_module());
  foreach (entry; cache)
    if (entry._0 == base /* hax */
     && entry._1 == rich
     && entry._2 is mod && mod.isValid) return entry._3;
  auto res = fastalloc!(Structure)(cast(string) null);
  res.sup = sysmod;
  if (rich)
    fastalloc!(RelMember)("capacity"[], Single!(SysInt), res);
  // TODO: fix when int promotion is supported
  // Structure.Member("length"[], Single!(SizeT)),
  fastalloc!(RelMember)("length"[], Single!(SysInt), res);
  fastalloc!(RelMember)("ptr"[], fastalloc!(Pointer)(base), res);
  res.name = "__array_as_struct__"~base.mangle()~(rich?"_rich":""[]);
  if (!mod || !sysmod || mod is sysmod || mod.name == "std.c.setjmp" /* hackaround */) {
    cache ~= stuple(base, rich, mod, fastcast!(IType) (res));
    return res;
  }
  
  auto backup = namespace();
  scope(exit) namespace.set(backup);
  namespace.set(res);
  
  void mkFun(string name, IType ret, Tree delegate() dg) {
    auto fun = fastalloc!(RelFunction)(res);
    New(fun.type);
    fun.type.ret = ret;
    fun.name = name;
    
    auto backup = namespace();
    scope(exit) namespace.set(backup);
    fun.sup = backup;
    namespace.set(fun);
    
    fun.fixup;
    fun.addStatement(fastcast!(Statement) (dg()));
    
    res.add(fun);
    fun.weak = true;
    mod.addEntry(fun);
  }
  cache ~= stuple(base, rich, mod, fastcast!(IType) (res));
  isArrayStructType[res] = true;
  mkFun("free"[], Single!(Void), delegate Tree() {
    if (rich) return iparse!(Statement, "array_free"[], "tree.stmt"[])
                  (`{ mem.free(void*:ptr, capacity * sz); ptr = null; length = 0; capacity = 0; }`, namespace(), "sz", llvmval(base.llvmSize()));
    else return iparse!(Statement, "array_free"[], "tree.stmt"[])
                  (`{ mem.free(void*:ptr, length * sz); ptr = null; length = 0; }`, namespace(), "sz", llvmval(base.llvmSize()));
  });
  if (rich) {
    mkFun("clear"[], Single!(Void), delegate Tree() {
      return iparse!(Statement, "array_clear"[], "tree.stmt"[])
                    (`length = 0;`, namespace());
    });
  }
  {
    auto propbackup = propcfg().withTuple;
    propcfg().withTuple = true;
    scope(exit) propcfg().withTuple = propbackup;
    res.add(fastalloc!(ExprAlias)(
      iparse!(Expr, "array_dup"[], "tree.expr"[])
             (`(base*: dupv (ptr, length * size-of base))[0 .. length]`,
              res, "base"[], base),
      "dup"
    ));
  }
  if (base != Single!(Void)) {
    mkFun("popEnd"[], base, delegate Tree() {
      auto len = fastcast!(LValue) (namespace().lookup("length"[]));
      auto p = fastcast!(Expr) (namespace().lookup("ptr"[]));
      return fastalloc!(ReturnStmt)(
        fastalloc!(StatementAndExpr)(
          fastalloc!(Assignment)(len, lookupOp("-"[], len, mkInt(1))),
          fastalloc!(DerefExpr)(lookupOp("+"[], p, len))
        )
      );
    });
  }
  
  return res;
}

T arrayToStruct(T)(T array) {
  auto avt = resolveType(array.valueType());
  auto
    ar = fastcast!(Array)~ avt,
    ea = fastcast!(ExtArray)~ avt;
  if (ar)
    return fastcast!(T)~ reinterpret_cast(arrayAsStruct(ar.elemType, false), array);
  if (ea)
    return fastcast!(T)~ reinterpret_cast(arrayAsStruct(ea.elemType, true),  array);
  logln(T.stringof, ": "[], array.valueType(), ": "[], array);
  fail;
  assert(false);
}

import ast.structure;
static this() {
  typeModlist ~= delegate IType(ref string text, IType cur, ParseCb, ParseCb) {
    // cur = forcedConvert(cur);
    if (text.accept("[]"[])) {
      return fastalloc!(Array)(cur);
    } else if (text.accept("[~]"[])) {
      return fastalloc!(ExtArray)(cur, false);
    } else if (text.accept("[auto ~]"[]) || text.accept("[auto~]"[]))
      return fastalloc!(ExtArray)(cur, true);
    else return null;
  };
}

import ast.pointer, ast.casting;

static int am_count;

// construct array from two (three?) expressions
class ArrayMaker : Expr {
  Expr ptr, length;
  Expr cap;
  int count;
  private this() {
    count = am_count ++;
    // if (count == 8302) asm { int 3; }
  }
  this(Expr ptr, Expr length, Expr cap = null) {
    this();
    this.ptr = ptr; this.length = length; this.cap = cap;
  }
  mixin MyThis!("ptr, length, cap = null"[]);
  mixin DefaultDup!();
  mixin defaultIterate!(ptr, length, cap);
  override Expr collapse() {
    Expr res;
    if (cap) {
      res = mkTupleValueExprMayDiscard(cap, length, ptr);
    } else {
      res = mkTupleValueExprMayDiscard(length, ptr);
    }
    return reinterpret_cast(valueType(), res);
  }
  IType elemType() {
    return (fastcast!(Pointer) (resolveType(ptr.valueType()))).target;
  }
  override string toString() { return Format("array ", count, " (ptr="[], ptr, "[], length="[], length, cap?Format("[], cap="[], cap):""[], ")"[]); }
  IType cachedType;
  override IType valueType() {
    if (!cachedType) {
      if (cap) cachedType = fastalloc!(ExtArray)(elemType(), false);
      else cachedType = fastalloc!(Array)(elemType());
    }
    return cachedType;
  }
  import ast.vardecl, ast.assign;
  override void emitLLVM(LLVMFile lf) {
    assert(false, "this should have got collapsed");
  }
}

import ast.variable, ast.vardecl;
class AllocStaticArray : Expr {
  Expr sa;
  StaticArray st;
  this(Expr sa) {
    this.sa = sa;
    st = fastcast!(StaticArray) (sa.valueType());
  }
  mixin defaultIterate!(sa);
  mixin defaultCollapse!();
  override {
    AllocStaticArray dup() { return fastalloc!(AllocStaticArray)(sa.dup); }
    IType valueType() { return fastalloc!(Array)(st.elemType); }
    void emitLLVM(LLVMFile lf) {
      todo("AllocStaticArray::emitLLVM");
      /*mkVar(lf, valueType(), true, (Variable var) {
        sa.emitLLVM(lf);
        iparse!(Statement, "new_sa"[], "tree.stmt"[])
               (`var = new T[] size; `
               ,"var"[], var, "T"[], st.elemType, "size"[], mkInt(st.length)
               ).emitLLVM(lf);
        lf.mmove4(qformat(4 + st.length, "(%esp)"[]), "%eax"[]);
        lf.popStack("(%eax)"[], st.size);
      });*/
    }
  }
}

Expr staticToArray(Expr sa) {
  if (auto cv = fastcast!(CValue) (sa)) {
    return fastalloc!(ArrayMaker)(
      fastalloc!(CValueAsPointer)(cv),
      mkInt(fastcast!(StaticArray) (resolveType(sa.valueType())).length)
    );
  } else {
    return fastalloc!(AllocStaticArray)(sa);
  }
}

import ast.literals;
static this() {
  implicits ~= delegate Expr(Expr ex) {
    if (!fastcast!(StaticArray)(ex.valueType()) || !fastcast!(CValue) (ex))
      return null;
    if (auto sa = fastcast!(StatementAnd) (ex))
      return mkStatementAndExpr(sa.first, staticToArray(sa.second));
    return staticToArray(ex);
  };
}

Expr getArrayLength(Expr ex) {
  if (auto sa = fastcast!(StaticArray) (resolveType(ex.valueType())))
    return mkInt(sa.length);
  return mkMemberAccess(arrayToStruct!(Expr)(ex), "length");
}

Expr getArrayPtr(Expr ex) {
  if (auto sa = fastcast!(StaticArray) (resolveType(ex.valueType())))
    ex = staticToArray(ex);
  return mkMemberAccess(arrayToStruct!(Expr) (ex), "ptr"[]);
}

static this() {
  defineOp("length"[], delegate Expr(Expr ex) {
    ex = forcedConvert(ex);
    while (true) {
      if (auto ptr = fastcast!(Pointer) (ex.valueType()))
        ex = fastalloc!(DerefExpr)(ex);
      else break;
    }
    if (gotImplicitCast(ex, (IType it) { return fastcast!(Array) (it) || fastcast!(ExtArray) (it) || fastcast!(StaticArray) (it); })) {
      return getArrayLength(ex);
    } else return null;
  });
}

import ast.parse;
// separate because does clever allocation mojo .. eventually
Object gotArrayLength(ref string text, ParseCb cont, ParseCb rest) {
  return lhs_partial.using = delegate Object(Expr ex) {
    return fastcast!(Object) (text.lookupOp("length"[], true, ex));
  };
}
mixin DefaultParser!(gotArrayLength, "tree.rhs_partial.a_array_length"[], null, ".length"[]);

class ArrayExtender : Expr {
  Expr array, ext;
  bool autoarray;
  IType baseType, cachedType;
  this(Expr a, Expr e, bool automatic = false) {
    array = a;
    ext = e;
    autoarray = automatic;
    baseType = (fastcast!(Pointer) (getArrayPtr(array).valueType())).target;
  }
  private this() { }
  mixin DefaultDup!();
  mixin defaultIterate!(array, ext);
  mixin defaultCollapse!();
  override {
    IType valueType() { if (!cachedType) cachedType = fastalloc!(ExtArray)(baseType, autoarray); return cachedType; }
    void emitLLVM(LLVMFile lf) {
      auto ars = save(lf, array); // length, ptr
      auto art = typeToLLVM(array.valueType());
      auto exs = save(lf, ext); // cap
      // extract length, ptr
      auto l = extractvalue(lf, "i32", art, ars, 0);
      auto p = extractvalue(lf, "i8*", art, ars, 1);
      formTuple(lf, "i32", exs, "i32", l, typeToLLVM(fastalloc!(Pointer)(baseType), true), p);
    }
  }
}

static this() {
  implicits ~= delegate Expr(Expr ex, IType it) {
    if (!fastcast!(Array) (ex.valueType()) && !fastcast!(ExtArray) (ex.valueType())) return null;
    if (it && Single!(HintType!(Array)) != it && Single!(HintType!(ExtArray)) != it) return null;
    if (auto lv = fastcast!(LValue) (ex)) {
      if (auto sal = fastcast!(StatementAndLValue) (ex))
        return fastalloc!(StatementAndLValue)(sal.first, arrayToStruct!(LValue) (fastcast!(LValue) (sal.second)));
      return arrayToStruct!(LValue) (lv);
    } else {
      if (auto sae = fastcast!(StatementAndExpr) (ex))
        return fastalloc!(StatementAndExpr)(sae.first, arrayToStruct!(Expr) (sae.second));
      return arrayToStruct!(Expr) (ex);
    }
  };
  implicits ~= delegate void(Expr ex, IType it, void delegate(Expr) consider) {
    if (!fastcast!(Array) (ex.valueType())) return;
    if (it && Single!(HintType!(Array)) != it && Single!(HintType!(ExtArray)) != it) return;
    // if (!isTrivial(ex)) ex = lvize(ex);
    // equiv to extended with 0 cap
    consider(fastalloc!(ArrayExtender)(ex, mkInt(0)));
    consider(fastalloc!(ArrayExtender)(ex, mkInt(0), true)); // try [auto~]
  };
}

Expr arrayCast(Expr ex, IType it) {
  if (!gotImplicitCast(ex, (IType it) { return test(fastcast!(Array) (resolveType(it))); }))
    return null;
  auto ar1 = fastcast!(Array) (resolveType(ex.valueType())), ar2 = fastcast!(Array) (resolveType(it));
  if (!ar1 || !ar2) return null;
  return iparse!(Expr, "array_cast_convert_call"[], "tree.expr"[])
                (`sys_array_cast!Res(from, sz1, sz2)`,
                 "Res"[], ar2, "from"[], ex,
                 "sz1"[], llvmval(ar1.elemType.llvmSize()),
                 "sz2"[], llvmval(ar2.elemType.llvmSize()));
}

import tools.base: todg;
import ast.opers, ast.namespace;
bool delegate(Expr, Expr, bool*) constantStringsCompare;
static this() {
  converts ~= &arrayCast /todg;
}
