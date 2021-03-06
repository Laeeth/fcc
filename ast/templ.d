module ast.templ;

import ast.base, ast.parse, ast.modules, ast.namespace, ast.fun, ast.oop, ast.nestfun, ast.fold;

interface ITemplate : Named {
  Object getInstanceIdentifier(IType it, ParseCb rest, string name);
}

extern(C) bool _isITemplate(Object obj) { return !!fastcast!(ITemplate)(obj); }

interface ITemplateX : ITemplate { // extended template-like
  bool isAliasTemplate();
  TemplateInstance getInstance(IType type, ParseCb rest, bool forceNew = false);
  TemplateInstance getInstance(Tree tr, ParseCb rest);
  Object postprocess(Object obj);
}

void delegate()[] resetDgs;
void resetTemplates() { foreach (dg; resetDgs) dg(); }

class RelTemplate : ITemplateX, Iterable {
  Template sup;
  Expr ex;
  bool fixupme; // nested function template
  this(Template t, Expr e, bool fum = false) { sup = t; ex = e; fixupme = fum; }
  mixin defaultIterate!(ex);
  override {
    string toString() { return qformat("RelTemplate<", sup, ", ", ex, ">"); }
    RelTemplate dup() { return fastalloc!(RelTemplate)(sup, ex.dup, fixupme); }
    bool isAliasTemplate() { return sup.isAliasTemplate(); }
    string getIdentifier() { return sup.getIdentifier(); }
    Object getInstanceIdentifier(IType it, ParseCb rest, string name) {
      return postprocess(sup.getInstanceIdentifier(it, rest, name));
    }
    TemplateInstance getInstance(IType type, ParseCb rest, bool forceNew = false) {
      return sup.getInstance(type, rest, forceNew);
    }
    TemplateInstance getInstance(Tree tr, ParseCb rest) {
      return sup.getInstance(tr, rest);
    }
    Object postprocess(Object obj) {
      if (auto f = fastcast!(Function)(obj))
        obj = fastcast!(Object)(doBasePointerFixup(f));
      if (fixupme) {
        auto itr = fastcast!(Iterable) (obj);
        if (itr) {
          fixupEBP(itr, ex);
          return fastcast!(Object)(itr);
        }
      }
      auto rt = fastcast!(RelTransformable) (obj);
      if (!rt) return obj;
      return rt.transform(ex);
    }
  }
}

// value-equal
import ast.literals;
bool vequals(Tree t1, Tree t2) {
  auto o1 = fastcast!(Object)(t1), o2 = fastcast!(Object)(t2);
  if (o1.classinfo !is o2.classinfo) return false;
  if (auto ie = fastcast!(IntExpr)(o1)) {
    return ie.num == fastcast!(IntExpr)(o2).num;
  }
  // logln(" -- ", o1.classinfo.name, " ", o1);
  // fail;
  return t1 == t2;
}

class Template : ITemplateX, SelfAdding, RelTransformable /* for templates in structs */ {
  string name;
  string param;
  bool isAlias;
  override bool isAliasTemplate() { return isAlias; }
  string source; // HAX
  Namespace context;
  union {
    Stuple!(TemplateInstance, IType)[] emat_type; // past tense of emit
    Stuple!(TemplateInstance, Tree)[] emat_alias;
  }
  bool[IType] hacked_it;
  this() {
    resetDgs ~= &resetme;
    context = namespace();
  }
  void resetme() { emat_type = null; emat_alias = null; }
  override {
    Object transform(Expr base) {
      return fastalloc!(RelTemplate)(this, base);
    }
    TemplateInstance getInstance(IType type, ParseCb rest, bool forceNew = false) {
      if (isAlias) fail;
      type = resolveType(type);
      if (auto tup = fastcast!(Tuple) (type)) {
        IType[] resolved;
        foreach (t2; tup.types) resolved ~= resolveType(t2);
        type = mkTuple(resolved, tup.names);
      }
      TemplateInstance ti;
      if (!forceNew) foreach (ref entry; emat_type) {
        debug if ((qformat(entry._1) == qformat(type)) != (entry._1.mangle() == type.mangle())) {
          logln("1: ", entry._1, ": ", entry._1.mangle());
          logln("2: ", type, ": ", type.mangle());
          fail;
        }
        // if (qformat(entry._1) == qformat(type)) { ti = entry._0; break; }
        // if (entry._1.mangle() == type.mangle()) {
        // DON'T SWITCH THIS BACK WITHOUT DOCUMENTING WHY
        if (entry._1 == type) {
          ti = entry._0;
          break;
        }
      }
      if (!ti) {
        // if (name == "join") logln(name, ": type alloc with ", type);
        ti = fastalloc!(TemplateInstance)(this, type, rest);
        // if (name == "join") logln(name, ": type alloc => ", ti);
      }
      ti.emitCopy();
      return ti;
    }
    TemplateInstance getInstance(Tree tr, ParseCb rest) {
      if (!isAlias) fail;
      if (auto ex = fastcast!(Expr)(tr)) {
        tr = collapse(forcedConvert(ex)); // (int) to int -- wtf TODO do this earlier
      }
      TemplateInstance ti;
      foreach (entry; emat_alias) {
        if (vequals(entry._1, tr)) { ti = entry._0; break; }
      }
      if (!ti) {
        ti = fastalloc!(TemplateInstance)(this, tr, rest);
      }
      ti.emitCopy();
      return ti;
    }
    Object getInstanceIdentifier(IType type, ParseCb rest, string name) {
      bool forceNew;
      start:
      auto res = getInstance(type, rest, forceNew).lookup(name, true);
      // logln("res = ", res);
      if (auto fun = fastcast!(Function)(res)) if (!fun.type.ret) {
        if (forceNew) {
          logln("wat 3 ", fun);
          fail;
        }
        forceNew = true;
        foreach (key, value; hacked_it)
          if (key == type) {
            logln("Tried to hack around circular dependency by double-instantiating ", name, ", but it still went circular. Giving up. ");
            throw new Exception("Fuck. ");
          }
        hacked_it[type] = true;
        goto start;
      }
      hacked_it.remove(type);
      return res;
    }
    string getIdentifier() { return name; }
    bool addsSelf() { return true; }
    string toString() {
      return Format("template "[], name);
    }
    Object postprocess(Object obj) { return obj; }
  }
}

import ast.stringparse;
Object gotTemplate(bool ReturnNoOp)(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  auto tmpl = new Template;
  if (!(t2.gotIdentifier(tmpl.name) && t2.accept("(") && (t2.accept("alias") && test(tmpl.isAlias = true) || true) && t2.gotIdentifier(tmpl.param) && t2.accept(")")))
    t2.failparse("Failed parsing template header");
  t2.noMoreHeredoc();
  tmpl.source = t2.coarseLexScope(true, false);
  ITemplateX itmpl = tmpl;
  if (fastcast!(Scope)(namespace())) { // nested
    // introduce ebp so that nested functions will resolve properly
    itmpl = fastalloc!(RelTemplate)(tmpl, fastalloc!(Register!("ebp"))(), true);
  }
  text = t2;
  namespace().add(tmpl.name, itmpl);
  static if (ReturnNoOp) return Single!(NoOp);
  else return fastcast!(Object)(itmpl);
}
// a_ so this comes first .. lol
mixin DefaultParser!(gotTemplate!(false), "tree.toplevel.a_template", null, "template");
mixin DefaultParser!(gotTemplate!(false), "struct_member.struct_template", null, "template");
mixin DefaultParser!(gotTemplate!(true), "tree.stmt.template_statement", "182", "template");

import tools.log;

class DependencyEntry : Tree {
  Dependency sup;
  this(Dependency dep) { sup = dep; }
  mixin defaultIterate!();
  mixin defaultCollapse!();
  DependencyEntry dup() { return this; }
  string toString() { return Format("<dep "[], sup, ">"[]); }
  void emitLLVM(LLVMFile lf) {
    sup.emitDependency(lf);
  }
}

import ast.structure, ast.scopes, ast.literal_string;
class TemplateInstance : Namespace, HandlesEmits, ModifiesName, IsMangled {
  Namespace context;
  union {
    IType type;
    Tree tr;
  }
  Template parent;
  IsMangled[] instRes;
  bool embedded; // embedded in a fun, special consideration applies for lookups
  override Object lookup(string name, bool local = false) {
    if (auto res = super.lookup(name, local)) return res;
    if (embedded && local && name != parent.name /* lol */)
      return sup.lookup(name, true); // return results from surrounding function for a nestfun
    return null;
  }
  override string modify(string s) {
    auto res = qformat(parent.name, "!"[], parent.isAlias?fastcast!(Object) (tr):fastcast!(Object) (type));
    if (s != parent.name) res ~= "."~s;
    return res;
  }
  override bool handledEmit(Tree tr) {
    // TODO: I feel VERY iffy about this.
    if (fastcast!(Module) (context)) return false;
    /*logln(tr);
    logln(" -- context ", context);
    logln();*/
    return !embedded;
  }
  this(Template parent, IType type, ParseCb rest) {
    this.type = type;
    this.parent = parent;
    assert(!parent.isAlias);
    __add(parent.param, fastcast!(Object)~ type);
    this.sup = context = parent.context;
    parent.emat_type ~= stuple(this, type);
    this(rest);
  }
  this(Template parent, Tree tr, ParseCb rest) {
    this.tr = tr;
    this.parent = parent;
    assert(parent.isAlias);
    __add(parent.param, fastcast!(Object)~ tr);
    this.sup = context = parent.context;
    parent.emat_alias ~= stuple(this, tr);
    this(rest);
  }
  Module[] ematIn;
  void emitCopy(bool weakOnly = false) {
    if (!instRes) return;
    auto mod = fastcast!(Module) (current_module());
    if (!mod) fail;
    foreach (emod; ematIn) if (emod is mod) {
      return;
    }
    void handleDeps(Iterable outer) {
      void addDependencies(ref Iterable it) {
        it.iterate(&addDependencies);
        if (auto dep = fastcast!(Dependency) (it)) {
          mod.addEntry(fastalloc!(DependencyEntry)(dep));
        }
      }
      addDependencies(outer);
    }
    if (weakOnly) {
      foreach (inst; instRes) if (auto fun = fastcast!(Function) (inst)) if (fun.weak) {
        auto copy = fun.dup;
        mod.addEntry(fastcast!(Tree) (copy));
        handleDeps(copy);
      }
    } else {
      foreach (inst; instRes) {
        auto copy = fastcast!(Tree) (inst).dup;
        mod.addEntry(copy);
        handleDeps(fastcast!(Iterable) (copy));
      }
    }
    ematIn ~= mod;
  }
  this(ParseCb rest) {
    withTLS(namespace, this, {
      
      auto rtptbackup = RefToParentType();
      scope(exit) RefToParentType.set(rtptbackup);
      RefToParentType.set(null);
      
      // separate parse context: don't carry through property configuration
      PropArgs defaults;
      auto backup = *propcfg.ptr();
      scope(exit) *propcfg.ptr() = backup;
      *propcfg.ptr() = defaults;
      
      auto t2 = parent.source;
      // open new memoizer level
      auto popCache = pushCache(); scope(exit) popCache();
      Object obj;
      
      // logln("Context: ", context);
      while (true) {
        if (auto tl = fastcast!(TemplateInstance) (context)) {
          context = tl.context;
        } else break;
      }
      // logln(" -> ", context);
      
      string parsemode;
      if (fastcast!(Module) (context))
        parsemode = "tree.toplevel";
      if (fastcast!(Structure) (context))
        parsemode = "struct_member";
      if (fastcast!(Class) (context))
        parsemode = "struct_member";
      if (fastcast!(Scope) (context)) {
        parsemode = "tree.stmt";
        embedded = true;
      }
      if (!parsemode) {
        logln("instance context is ", (cast(Object) context).classinfo.name);
        fail;
      }
      
      // logln("template context is ", (cast(Object) context).classinfo.name);
      // logln("rest toplevel match on ", t2);
      if (!t2.many(
        !!rest(t2, parsemode, &obj),
        {
          auto mg = fastcast!(IsMangled) (obj);
          if (mg) mg.markWeak();
          
          auto tr = fastcast!(Tree) (obj);
          if (!tr) return;
          if (fastcast!(NoOp) (obj)) return;
          auto n = fastcast!(Named)~ tr;
          // if (!n) throw new Exception(Format("Not named: ", tr));
          if (n && !addsSelf(n)) add(n.getIdentifier(), n);
          if (auto ns = fastcast!(Namespace)~ tr) { // now reset sup to correct target.
            ns.sup = this;
          }
          /*if (auto fun = fastcast!(Function)~ tr)
            logln("add ", fun.mangleSelf(), " to ", current_module().name,
              ", at ", current_module().entries.length, "; ", cast(void*) current_module());*/
          // current_module().addEntry(tr);
          // addExtra(mg);
          if (!mg) { logln("!! ", tr); fail; }
          instRes ~= mg;
        }
      ) || t2.mystripl().length)
        t2.failparse("Failed to parse template content");
      
    });
  }
  static string[Tree] mangcache;
  override {
    string toString() {
      if (parent.isAlias) return Format("Instance of "[], parent, " ("[], tr, ") <- "[], sup);
      else return Format("Instance of "[], parent, " ("[], type, ") <- "[], sup);
    }
    void markWeak() { } // templates are always weak
    void markExternC() { assert(false, "TODO"); }
    string mangleSelf() {
      string mangl;
      if (parent.isAlias) {
        if (auto fun = fastcast!(Function)~ tr) {
          mangl = fun.mangleSelf();
          // logln("mangl => ", mangl);
        } else {
          if (auto ptr = tr in mangcache) mangl = *ptr;
          else {
            auto id = qformat("tree_", mangletree(tr));
            mangcache[tr] = id;
            mangl = id;
          }
        }
      } else mangl = this.type.mangle();
      if (parent.context) {
        if (auto m = parent.context.get!(IsMangled))
          return qformat("templinst_", parent.name.cleanup(), "_under_", m.mangleSelf(), "_with_", mangl);
        if (auto n = parent.context.get!(Named))
          return qformat("templinst_", parent.name.cleanup(), "_under_", n.getIdentifier(), "_with_", mangl);
      }
      return qformat("templinst_", parent.name.cleanup(), "_with_", mangl);
    }
    string mangle(string name, IType type) {
      return sup.mangle(name, type)~"__"~mangleSelf();
    }
  }
}

Object gotTemplateInst(bool RHSMode)(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  Object getInstance(Object obj) {
    auto t = fastcast!(ITemplateX) (obj);
    if (!t) return null;
    if (!t2.accept("!")) return null;
    TemplateInstance inst;
    IType ty;
    if (t.isAliasTemplate()) {
      Tree tr;
      // try plain named first
      if (!rest(t2, "tree.expr.named"[], &tr) && !rest(t2, "tree.expr _tree.expr.bin"[], &tr))
        t2.failparse("Couldn't match tree object for instantiation");
      inst = t.getInstance(tr, rest);
    } else {
      if (!rest(t2, "type"[], &ty))
        t2.failparse("Couldn't match type for instantiation");
      try inst = t.getInstance(ty, rest);
      catch (Exception ex) throw new Exception(Format("with ", ty, ": ", ex));
    }
    if (auto res = inst.lookup(t.getIdentifier(), true)) return t.postprocess(res);
    else throw new Exception("Template '"~t.getIdentifier()~"' contains no self-named entity! ");
  }
  static if (RHSMode) {
    return lhs_partial.using = delegate Object(Object obj) {
      try {
        auto res = getInstance(obj);
        if (res) text = t2;
        return res;
      } catch (Exception ex) {
        t2.failparse(Format("instantiating ", ex));
      }
    };
  } else {
    try {
      Object obj;
      if (!rest(t2, "tree.expr.named"[], &obj)) return null;
      auto res = getInstance(obj);
      if (res) text = t2;
      return res;
    } catch (Exception ex) {
      t2.failparse(Format("instantiating ", ex));
    }
  }
  // logln("instantiate ", t.name, " with ", ty);
}
mixin DefaultParser!(gotTemplateInst!(false), "type.templ_inst", "32");
mixin DefaultParser!(gotTemplateInst!(false), "tree.expr.templ_expr", "2501");
mixin DefaultParser!(gotTemplateInst!(true), "tree.rhs_partial.instance");

import ast.funcall, ast.tuples, ast.properties;
Object gotIFTI(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  return lhs_partial.using = delegate Object(Object obj) {
    Expr iter;
    auto templ = fastcast!(ITemplate) (obj);
    if (!templ) return null;
    Expr nex;
    {
      bool argIsTuple;
      {
        auto t3 = t2;
        if (t3.accept("(")) argIsTuple = true;
      }
      
      // match no properties if our arg is a tuple/()
      auto backup = propcfg().withTuple;
      scope(exit) propcfg().withTuple = backup;
      if (argIsTuple) propcfg().withTuple = false;
      
      if (!rest(t2, "tree.expr _tree.expr.bin"[], &nex)) return null;
    }
    
    auto io = *templInstOverride.ptr(); // first level
    bool ioApplies;
    try {
      auto res = templ.getInstanceIdentifier(nex.valueType(), rest, templ.getIdentifier());
      {
        auto te = fastcast!(ITemplate) (res);
        if (io._1 && io._0.ptr == currentPropBase.ptr().ptr && te) {
          ioApplies = true;
          try {
            res = te.getInstanceIdentifier(io._1, rest, te.getIdentifier());
          } catch (Exception ex) {
            t2.failparse("ifti post-instantiating with ", io._1, ": ", ex);
          }
        }
        while (true) {
          te = fastcast!(ITemplate) (res);
          if (!te) break;
          res = te.getInstanceIdentifier(mkTuple(), rest, te.getIdentifier());
        }
      }
      auto fun = fastcast!(Function) (res);
      if (!fun) { return null; }
      if (!fun.type.ret) {
        if (fun.coarseSrc) fun.parseMe;
        else {
          logln("wat 1 ", fun);
          fail;
        }
        if (!fun.type.ret) {
          logln("wat 2 ", fun);
          fail;
        }
      }
      text = t2;
      auto fc = buildFunCall(fun, nex, "template_call");
      if (!fc) {
        logln("Couldn't build fun call! ");
        fail;
      }
      return fastcast!(Object) (fc);
    } catch (Exception ex) {
      // fail;
      t2.failparse("template '", templ.getIdentifier(), "' implicitly instantiated with ", nex.valueType(), ioApplies?Format(" (post ", io._1, ")"):"", ": ", ex);
    }
  };
}
mixin DefaultParser!(gotIFTI, "tree.rhs_partial.k_ifti"); // k so it comes after "instance" :p
