module ast.withstmt;

import ast.base, ast.parse, ast.vardecl, ast.namespace, ast.guard, ast.scopes, ast.fun;

class WithStmt : Namespace, Statement, ScopeLike {
  RelNamespace rns;
  Namespace ns;
  VarDecl vd;
  Expr context;
  Scope sc;
  void delegate(AsmFile) pre, post;
  mixin defaultIterate!(vd, sc);
  string toString() { return Format("with ", context, " ", sc._body); }
  int temps;
  override int framesize() {
    return (cast(ScopeLike) sup).framesize() + temps;
  }
  this(Expr ex) {
    sup = namespace();
    namespace.set(this);
    scope(exit) namespace.set(this.sup);
    
    sc = new Scope;
    sc.sup = this;
    sc.fun = get!(Function);
    
    if (auto isc = cast(IScoped) ex) {
      ex = isc.getSup;
      pre = &isc.emitAsmStart;
      temps += ex.valueType().size;
      post = &isc.emitAsmEnd;
    }
    
    rns = cast(RelNamespace) ex.valueType();
    ns = cast(Namespace) ex; // say, context
    assert(rns || ns, Format("Cannot with-expr a non-[rel]ns: ", ex)); // TODO: select in gotWithStmt
    
    if (auto lv = cast(LValue) ex) {
      context = lv;
    } else {
      auto var = new Variable;
      var.type = ex.valueType();
      var.initval = ex;
      // temps += var.type.size;
      logln("temps now ", temps);
      var.baseOffset = boffs(var.type);
      logln("base offs for ", ex, " temp var is ", var.baseOffset);
      context = var;
      New(vd);
      vd.vars ~= var;
    }
  }
  override {
    void emitAsm(AsmFile af) {
      mixin(mustOffset("0"));
      
      if (pre) pre(af);
      scope(exit) if (post) post(af);
      
      auto dg = sc.open(af);
      if (vd) vd.emitAsm(af);
      dg()();
    }
    string mangle(string name, IType type) { assert(false); }
    Stuple!(IType, string, int)[] stackframe() { assert(false); }
    Object lookup(string name, bool local = false) {
      if (rns)
        if (auto res = rns.lookupRel(name, context))
          return res;
      if (ns)
        if (auto res = ns.lookup(name, true))
          return res;
      if (local) return null;
      return sup.lookup(name);
    }
  }
}

import tools.log;
Object gotWithStmt(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  // if (!t2.accept("with")) return null;
  if (!t2.accept("using")) return null;
  Expr ex;
  if (!rest(t2, "tree.expr", &ex)) throw new Exception("Couldn't match with-expr at "~t2.next_text());
  auto backup = namespace();
  scope(exit) namespace.set(backup);
  auto ws = new WithStmt(ex);
  namespace.set(ws.sc);
  if (!rest(t2, "tree.stmt", &ws.sc._body)) throw new Exception("Couldn't match with-body at "~t2.next_text());
  text = t2;
  return ws;
}
mixin DefaultParser!(gotWithStmt, "tree.stmt.withstmt");
