module ast.withstmt;

import ast.base, ast.parse, ast.vardecl, ast.namespace, ast.guard, ast.scopes, ast.fun, ast.casting;

class WithStmt : Namespace, Statement, ScopeLike {
  RelNamespace rns;
  Stuple!(RelNamespace, Expr) [] rnslist;
  Namespace ns;
  VarDecl vd;
  Expr context;
  Scope sc;
  IScoped isc;
  void delegate(AsmFile) pre, post;
  mixin defaultIterate!(vd, sc);
  override WithStmt dup() { assert(false, "wth"); }
  string toString() { return Format("with (", context, ") <- ", sup); }
  int temps;
  override int framesize() {
    return (fastcast!(ScopeLike)~ sup).framesize() + temps;
  }
  this(Expr ex) {
    if (auto isc = fastcast!(IScoped) (ex)) {
      this.isc = isc;
      ex = isc.getSup;
      pre = &isc.emitAsmStart;
      temps += ex.valueType().size;
      post = &isc.emitAsmEnd;
      assert(!!fastcast!(LValue) (ex) || !!fastcast!(MValue) (ex), Format(ex, " which is ", isc, ".getSup; is not an LValue/MValue. Halp. "));
    }
    
    if (auto lv = fastcast!(LValue)~ ex) {
      context = lv;
    } else if (auto mv = fastcast!(MValue)~ ex) {
      context = mv;
    } else {
      auto var = new Variable;
      var.type = ex.valueType();
      var.initval = ex;
      var.baseOffset = boffs(var.type);
      temps += var.type.size;
      context = var;
      New(vd);
      vd.vars ~= var;
    }
    
    rns = fastcast!(RelNamespace)~ ex.valueType();
    
    if (auto srns = fastcast!(SemiRelNamespace) (ex.valueType())) rns = srns.resolve();
    ns = fastcast!(Namespace)~ ex; // say, context
    
    if (!rns && !ns && !isc) {
      Expr ex2 = context;
      gotImplicitCast(ex2, (Expr ex) {
        auto it = ex.valueType();
        if (auto ns = fastcast!(RelNamespace)~ it)
          rnslist ~= stuple(ns, ex);
        return false;
      });
      if (!rnslist) {
        Format("Cannot with-expr a non-[rel]ns: ", context).fail(); // TODO: select in gotWithStmt
      }
    }
    
    sup = namespace();
    namespace.set(this);
    scope(exit) namespace.set(this.sup);
    
    sc = new Scope;
    assert(!!sc.sup);
    
  }
  override {
    void emitAsm(AsmFile af) {
      mixin(mustOffset("0"));
      
      if (pre) pre(af);
      scope(exit) if (post) post(af);
      
      auto dg = sc.open(af);
      if (vd) vd.emitAsm(af); // do this BEFORE onUsing!
      if (auto onUsing = iparse!(Statement, "onUsing", "tree.semicol_stmt.expr", canFail)
                                ("eval (ex.onUsing)", "ex", context))
        onUsing.emitAsm(af);
      auto close = dg();
      if (auto onExit = iparse!(Statement, "onExit", "tree.semicol_stmt.expr", canFail)
                               ("eval (ex.onExit)", "ex", context))
        onExit.emitAsm(af);
      close();
    }
    string mangle(string name, IType type) { return sup.mangle(name, type); }
    Stuple!(IType, string, int)[] stackframe() {
      auto res = sup.stackframe();
      if (vd)
        foreach (var; vd.vars)
          res ~= stuple(var.type, var.name, var.baseOffset);
      return res;
    }
    Object lookup(string name, bool local = false) {
      if (name == "that") return fastcast!(Object)~ context;
      if (!local) {
        if (rns)
          if (auto res = rns.lookupRel(name, context))
            return res;
        if (rnslist)
          foreach (rns; rnslist)
            if (auto res = rns._0.lookupRel(name, rns._1))
              return res;
        if (ns)
          if (auto res = ns.lookup(name, true))
            return res;
      }
      return sup.lookup(name);
    }
  }
}

import tools.log, ast.tuple_access;
Object gotWithStmt(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  Expr ex;
  if (!rest(t2, "tree.expr", &ex))
    t2.failparse("Couldn't match with-expr");
  auto backup = namespace();
  scope(exit) namespace.set(backup);
  
  WithStmt ws, outer;
  
  if (auto list = getTupleEntries(ex)) {
    foreach (entry; list) {
      auto prev = ws;
      ws = new WithStmt(entry);
      if (!outer) outer = ws;
      namespace.set(ws.sc);
      if (prev) prev.sc.addStatement(ws);
    }
  } else {
    ws = new WithStmt(ex);
    if (!outer) outer = ws;
    namespace.set(ws.sc);
  }
  if (!rest(t2, "tree.stmt", &ws.sc._body))
    t2.failparse("Couldn't match with-body");
  text = t2;
  return outer;
}
mixin DefaultParser!(gotWithStmt, "tree.stmt.withstmt", "11", /*"with"*/"using");

Object gotBackupOf(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  string name;
  if (t2.gotIdentifier(name) && t2.accept(")")) {
    auto ws = namespace().get!(WithStmt);
    string[] names;
    do {
      if (!ws.isc) continue;
      auto n = fastcast!(Named)~ ws.isc.getSup();
      if (!n) continue;
      auto ident = n.getIdentifier();
      if (ident == name)
        return ws.vd.vars[0];
      names ~= ident;
    } while (test(ws = ws.get!(WithStmt)));
    throw new Exception(Format("No backup for ", name, ", only ", names, ". "));
  } else
    t2.failparse("Failed to parse backupof()");
}
mixin DefaultParser!(gotBackupOf, "tree.expr.backupof", "52", "backupof(");
