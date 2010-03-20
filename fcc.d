module fcc; // feep's crazed compiler

import tools.base, tools.log, tools.compat;

extern(C) {
  int mkstemp(char* tmpl);
  int close(int fd);
}

string error;

string tmpnam(string base = "fcc") {
  string name = base ~ "XXXXXX";
  auto p = toStringz(name);
  auto fd = mkstemp(p);
  assert(fd != -1);
  close(fd);
  return toString(p);
}

bool isAlpha(dchar d) {
  // TODO expand
  return d >= 'A' && d <= 'Z' || d >= 'a' && d <= 'z';
}

bool isAlphanum(dchar d) {
  return isAlpha(d) || d >= '0' && d <= '9';
}

string next_text(string s) {
  if (s.length > 100) s = s[0 .. 100];
  return s.replace("\n", "\\");
}

void eatComments(ref string s) {
  s = s.strip();
  while (true) {
    if (auto rest = s.startsWith("/*")) { rest.slice("*/"); s = rest.strip(); }
    else break;
  }
}

bool accept(ref string s, string t) {
  auto s2 = s.strip();
  t = t.strip();
  s2.eatComments();
  // logln("accept ", t, " from ", s2.next_text(), "? ", !!s2.startsWith(t));
  return s2.startsWith(t) && (s = s2[t.length .. $], true);
}

/+
  What do we expect of a type system?
  Nothing.
+/

class Type {
  int size;
  abstract string mangle();
  int opEquals(Object obj) {
    // specialize where needed
    return this.classinfo is obj.classinfo &&
      size == (cast(Type) cast(void*) obj).size;
  }
  void match(ref Expr[] params) {
    if (!params.length)
      throw new Exception(Format("Missing parameter of ", this));
    if (params[0].valueType() !is this)
      throw new Exception(Format("Expected ", this, ", got ", params[0]));
    params.take();
  }
}

class Void : Type {
  this() { size = 4; }
  override string mangle() { return "void"; }
}

class Variadic : Type {
  this() { size = 0; }
  void match(ref Expr[] params) {
    params = null; // match all
  }
  override string mangle() { return "variadic"; }
}

class Char : Type {
  this() { size = 1; }
  override string mangle() { return "char"; }
}

const nativeIntSize = 4, nativePtrSize = 4;

class Class : Type {
  Stuple!(Type, string)[] members;
  this() { size = nativePtrSize; }
  abstract override string mangle() { return "class"; }
}

class SizeT : Type {
  this() { size = nativeIntSize; }
  override string mangle() { return "size_t"; }
}

class SysInt : Type {
  this() { size = nativeIntSize; }
  override string mangle() { return "sys_int"; }
}

class Pointer : Type {
  Type target;
  this(Type t) { target = t; size = nativePtrSize; }
  int opEquals(Object obj) {
    if (obj.classinfo !is this.classinfo) return false;
    auto p = cast(Pointer) cast(void*) obj;
    return target == p.target;
  }
  override string mangle() { return "ptrto_"~target.mangle(); }
}

Type[] type_memofield;

// TODO: memoize better
Type tmemo(Type t) {
  foreach (entry; type_memofield) {
    if (entry.classinfo is t.classinfo && entry == t) return entry;
  }
  type_memofield ~= t;
  return t;
}

class ParseException {
  string where, info;
  this(string where, string info) {
    this.where = where; this.info = info;
  }
}

class Namespace {
  Namespace sup;
  Stuple!(string, Class)[] classes;
  Stuple!(string, Function)[] functions;
  void addClass(string name, Class cl) { classes ~= stuple(name, cl); }
  void addFun(Function fun) { fun.sup = this; functions ~= stuple(fun.name, fun); }
  abstract string mangle(string name, Type type);
  Class lookupClass(string name) {
    foreach (cl; classes)
      if (name == cl._0) return cl._1;
    if (sup) return sup.lookupClass(name);
    return null;
  }
  Function lookupFun(string name) {
    foreach (fn; functions)
      if (name == fn._0) return fn._1;
    if (sup) return sup.lookupFun(name);
    return null;
  }
}

bool gotType(ref string text, out Type type) {
  if (text.accept("void")) return type = tmemo(new Void), true;
  if (text.accept("size_t")) return type = tmemo(new SizeT), true;
  if (text.accept("int")) return type = tmemo(new SysInt), true;
  return false;
}

struct AsmFile {
  ubyte[][string] constants;
  string code;
  void pushStack(string addr, Type type) {
    assert(type.size == 4);
    put("subl $", type.size, ", %esp");
    put("movl ", addr, ", (%esp)");
  }
  void put(T...)(T t) {
    code ~= Format(t, "\n");
  }
  string genAsm() {
    string res;
    res ~= ".data\n";
    foreach (name, c; constants) {
      res ~= Format(name, ":\n");
      res ~= ".byte ";
      foreach (val; c) res ~= Format(cast(ubyte) val, ", ");
      res ~= "0\n";
    }
    res ~= ".text\n";
    res ~= code;
    return res;
  }
}

interface Tree {
  void emitAsm(ref AsmFile);
}

interface Statement : Tree { }

interface Expr : Statement {
  Type valueType();
}

class StringExpr : Expr {
  string str;
  // default action: place in string segment, load address on stack
  override void emitAsm(ref AsmFile af) {
    auto name = Format("cons_", af.constants.length);
    af.constants[name] = cast(ubyte[]) str;
    af.pushStack("$"~name, valueType());
  }
  override Type valueType() { return tmemo(new Pointer(new Char)); }
}

bool gotStringExpr(ref string text, out Expr ex) {
  auto t2 = text;
  StringExpr se;
  return t2.accept("\"") &&
    (se = new StringExpr, true) &&
    (se.str = t2.slice("\"").replace("\\n", "\n"), true) &&
    (text = t2, true) &&
    (ex = se, true);
}

class IntExpr : Expr {
  int num;
  override void emitAsm(ref AsmFile af) {
    af.pushStack(Format("$", num), valueType());
  }
  override Type valueType() { return tmemo(new SysInt); }
  this(int i) { num = i; }
}

bool ckbranch(ref string s, bool delegate()[] dgs...) {
  auto s2 = s;
  foreach (dg; dgs) {
    if (dg()) return true;
    s = s2;
  }
  return false;
}

class AsmBinopExpr(string OP) : Expr {
  Expr e1, e2;
  mixin This!("e1, e2");
  override {
    Type valueType() {
      assert(e1.valueType() is e2.valueType());
      return e1.valueType();
    }
    void emitAsm(ref AsmFile af) {
      assert(e1.valueType().size == 4);
      e2.emitAsm(af);
      e1.emitAsm(af);
      af.put("movl (%esp), %eax");
      
      static if (OP == "idivl") af.put("cdq");
      
      af.put(Format("addl $", e1.valueType().size, ", %esp"));
      
      static if (OP == "idivl") af.put("idivl (%esp)");
      else af.put(OP~" (%esp), %eax");
      
      af.put("movl %eax, (%esp)");
    }
  }
}

bool gotMathExpr(ref string text, out Expr ex, FrameState fs, Module mod, int level = 0) {
  auto t2 = text;
  Expr par;
  scope(success) text = t2;
  bool addMath(string op) {
    switch (op) {
      case "+": ex = new AsmBinopExpr!("addl")(ex, par); break;
      case "-": ex = new AsmBinopExpr!("subl")(ex, par); break;
      case "*": ex = new AsmBinopExpr!("imull")(ex, par); break;
      case "/": ex = new AsmBinopExpr!("idivl")(ex, par); break;
    }
    return true;
  }
  switch (level) {
    case -2: return t2.gotBaseExpr(ex, fs, mod);
    case -1:
      return t2.gotMathExpr(ex, fs, mod, level-1) && many(t2.ckbranch(
        t2.accept("*") && t2.gotMathExpr(par, fs, mod, level-1) && addMath("*"),
        t2.accept("/") && t2.gotMathExpr(par, fs, mod, level-1) && addMath("/")
      ));
    case 0:
      return t2.gotMathExpr(ex, fs, mod, level-1) && many(t2.ckbranch(
        t2.accept("+") && t2.gotMathExpr(par, fs, mod, level-1) && addMath("+"),
        t2.accept("-") && t2.gotMathExpr(par, fs, mod, level-1) && addMath("-")
      ));
  }
}

alias gotMathExpr gotExpr;

bool gotIntExpr(ref string text, out Expr ex) {
  auto t2 = text.strip();
  if (auto rest = t2.startsWith("-")) {
    return gotIntExpr(rest, ex)
      && (
        ((cast(IntExpr) ex).num = -(cast(IntExpr) ex).num),
        (text = rest),
        true
      );
    }
  bool isNum(char c) { return c >= '0' && c <= '9'; }
  if (!t2.length || !isNum(t2[0])) return false;
  int res = t2.take() - '0';
  while (t2.length) {
    if (!isNum(t2[0])) break;
    res = res * 10 + t2.take() - '0'; 
  }
  ex = new IntExpr(res);
  text = t2;
  return true;
}

void callFunction(Function fun, Expr[] params, ref AsmFile dest) {
  // dest.put("int $3");
  if (params.length) {
    auto p2 = params;
    foreach (entry; fun.type.params)
      entry._0.match(p2);
    assert(!p2.length);
    assert(cast(Void) fun.type.ret);
    foreach_reverse (param; params) {
      param.emitAsm(dest);
    }
  } else assert(!fun.type.params.length, Format("Expected ", fun.type.params, "!"));
  dest.put("call "~fun.mangleSelf);
  foreach (param; params) {
    dest.put(Format("addl $", param.valueType().size, ", %esp"));
  }
  // dest.put("leave");
}

// information about active stack frame
// built while generating function
class FrameState {
  Variable[] vars;
  string toString() {
    return Format(
      super.toString(), " - ", size(), " in ", vars
    );
  }
  int size() {
    int res;
    // TODO: alignment
    foreach (var; vars)
      res += var.type.size;
    return res;
  }
}

class FunctionType : Type {
  Type ret;
  Stuple!(Type, string)[] params;
  this() { size = -1; } // functions are not values
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
  }
}

class Function : Namespace, Tree {
  string name;
  FunctionType type;
  FrameState frame;
  Statement _body;
  bool extern_c = false;
  // declare parameters as variables
  void fixup() {
    // cdecl: 0 old ebp, 4 return address, 8 parameters .. I think.
    int cur = 8;
    // TODO: alignment
    foreach (param; type.params) {
      if (param._1) frame.vars ~= new Variable(param._0, param._1, cur);
      cur += param._0.size;
    }
  }
  string mangleSelf() {
    if (extern_c || name == "main")
      return name;
    else
      return sup.mangle(name, type);
  }
  override {
    void emitAsm(ref AsmFile af) {
      af.put(".globl "~mangleSelf);
      af.put(".type "~mangleSelf~", @function");
      af.put(mangleSelf~": ");
      af.put("pushl %ebp");
      af.put("movl %esp, %ebp");
      _body.emitAsm(af);
      af.put("movl %ebp, %esp");
      af.put("popl %ebp");
      af.put("ret");
    }
    string mangle(string name, Type type) {
      return sup.mangle(name, type)~"_in_"~name;
    }
  }
}

class Module : Namespace, Tree {
  string name;
  Module[] imports;
  Tree[] entries;
  override {
    void emitAsm(ref AsmFile af) {
      foreach (entry; entries)
        entry.emitAsm(af);
    }
    string mangle(string name, Type type) {
      return "module_"~this.name~"_"~name~"_of_"~type.mangle();
    }
    Class lookupClass(string name) {
      if (auto res = super.lookupClass(name)) return res;
      if (auto lname = name.startsWith(this.name~"."))
        if (auto res = super.lookupClass(lname)) return res;
      foreach (mod; imports)
        if (auto res = mod.lookupClass(name)) return res;
      return null;
    }
    Function lookupFun(string name) {
      if (auto res = super.lookupFun(name)) return res;
      if (auto lname = name.startsWith(this.name~"."))
        if (auto res = super.lookupFun(lname)) return res;
      foreach (mod; imports)
        if (auto res = mod.lookupFun(name)) return res;
      return null;
    }
  }
}

bool gotModule(ref string text, out Module mod) {
  auto t2 = text;
  Function fn;
  Tree tr;
  return t2.accept("module ") && (New(mod), true) &&
    t2.gotIdentifier(mod.name, true) && t2.accept(";") &&
    many(
      t2.gotFunDef(fn, mod) && (tr = fn, true) ||
      t2.gotImportStatement(mod) && (tr = null, true),
    {
      if (tr) mod.entries ~= tr;
    }) && (text = t2, true);
}

bool bjoin(lazy bool c1, lazy bool c2, void delegate() dg) {
  if (!c1) return true;
  dg();
  while (true) {
    if (!c2) return true;
    if (!c1) return false;
    dg();
  }
}

// while expr
bool many(lazy bool b, void delegate() dg = null) {
  while (b()) { if (dg) dg(); }
  return true;
}

Module sysmod;

Module lookupMod(string name) {
  if (name == "sys") {
    return sysmod;
  }
  assert(false, "TODO");
}

static this() {
  New(sysmod);
  sysmod.name = "sys";
  {
    auto puts = new Function;
    puts.extern_c = true;
    New(puts.type);
    puts.type.ret = tmemo(new Void);
    puts.type.params ~= stuple(tmemo(new Pointer(new Char)), cast(string) null);
    puts.name = "puts";
    sysmod.addFun(puts);
  }
  
  {
    auto printf = new Function;
    printf.extern_c = true;
    New(printf.type);
    printf.type.ret = tmemo(new Void);
    printf.type.params ~= stuple(tmemo(new Pointer(new Char)), cast(string) null);
    printf.type.params ~= stuple(tmemo(new Variadic), cast(string) null);
    printf.name = "printf";
    sysmod.addFun(printf);
  }
}

Function lookupFun(Namespace ns, string name) {
  if (auto res = ns.lookupFun(name)) return res;
  assert(false, "No such identifier: "~name);
}

Class lookupClass(Namespace ns, string name) {
  if (auto res = ns.lookupClass(name)) return res;
  assert(false, "No such identifier: "~name);
}

class FunCall : Expr {
  string name;
  Expr[] params;
  Namespace context;
  override void emitAsm(ref AsmFile af) {
    callFunction(lookupFun(context, name), params, af);
  }
  override Type valueType() {
    return lookupFun(context, name).type.ret;
  }
}

bool gotIdentifier(ref string text, out string ident, bool acceptDots = false) {
  auto t2 = text.strip();
  t2.eatComments();
  bool isValid(char c) {
    return isAlphanum(c) || (acceptDots && c == '.');
  }
  if (!t2.length || !isValid(t2[0])) return false;
  do {
    ident ~= t2.take();
  } while (t2.length && isValid(t2[0]));
  text = t2;
  return true;
}

bool gotFuncall(ref string text, out Expr expr, FrameState fs, Module mod) {
  auto fc = new FunCall;
  fc.context = mod;
  string t2 = text;
  Expr ex;
  return t2.gotIdentifier(fc.name, true)
    && t2.accept("(")
    && bjoin(t2.gotExpr(ex, fs, mod), t2.accept(","), { fc.params ~= ex; })
    && t2.accept(")")
    && ((text = t2), (expr = fc), true);
}

bool gotVariable(ref string text, out Variable v, FrameState fs) {
  // logln("Match variable off ", text.next_text());
  Variable var;
  string name, t2 = text;
  return t2.gotIdentifier(name, true)
    && {
      // logln("Look for ", name, " in ", fs.vars);
      // TODO: global variable lookup here
      foreach (var; fs.vars)
        if (var.name == name) {
          v = var;
          text = t2;
          return true;
        }
      error = "unknown identifier "~name;
      return false;
    }();
}

bool gotBaseExpr(ref string text, out Expr expr, FrameState fs, Module mod) {
  Variable var;
  return
       text.gotFuncall(expr, fs, mod)
    || text.gotStringExpr(expr)
    || text.gotIntExpr(expr)
    || text.gotVariable(var, fs) && (expr = var, true)
    || { auto t2 = text; return t2.accept("(") && t2.gotExpr(expr, fs, mod) && t2.accept(")") && (text = t2, true); }();
}

class AggrStatement : Statement {
  Statement[] stmts;
  override void emitAsm(ref AsmFile af) {
    foreach (stmt; stmts)
      stmt.emitAsm(af);
  }
}

bool gotAggregateStmt(ref string text, out AggrStatement as, FrameState fs, Module mod) {
  auto t2 = text;
  
  Statement st;
  return t2.accept("{") && (as = new AggrStatement, true) &&
    many(t2.gotStatement(st, fs, mod), { if (!st) asm { int 3; } as.stmts ~= st; }) &&
    t2.accept("}") && (text = t2, true);
}

class Assignment : Statement {
  Variable target;
  Expr value;
  this(Variable v, Expr e) { target = v; value = e; }
  this() { }
  override void emitAsm(ref AsmFile af) {
    assert(value.valueType().size == 4);
    value.emitAsm(af);
    af.put(Format("movl (%esp), %edx"));
    af.put(Format("movl %edx, ", target.baseOffset, "(%ebp)"));
    af.put(Format("addl $4, %esp"));
  }
}

bool gotAssignment(ref string text, out Assignment as, FrameState fs, Module mod) {
  auto t2 = text;
  New(as);
  return t2.gotVariable(as.target, fs) && t2.accept("=") && t2.gotExpr(as.value, fs, mod) && t2.accept(";") && {
    text = t2;
    return true;
  }();
}

class Variable : Expr {
  override void emitAsm(ref AsmFile af) {
    assert(type.size == 4);
    af.put("subl $", type.size, ", %esp");
    af.put("movl ", baseOffset, "(%ebp), %edx");
    af.put("movl %edx, (%esp)");
  }
  override Type valueType() {
    return type;
  }
  Type type;
  string name;
  // offset off ebp
  int baseOffset;
  Assignment initAss;
  this(Type t, string s, int i) { type = t; name = s; baseOffset = i; }
  this() { }
  string toString() { return Format("[ var ", name, " of ", type, " at ", baseOffset, "]"); }
}

class VarDecl : Statement {
  override void emitAsm(ref AsmFile af) {
    assert(var.type.size == 4);
    if (var.initAss) {
      var.initAss.emitAsm(af);
    } else {
      af.put("subl $4, %esp");
    }
  }
  Variable var;
}

bool gotVarDecl(ref string text, out VarDecl vd, FrameState fs, Module mod) {
  auto t2 = text;
  auto var = new Variable;
  Expr testInit;
  return
    t2.gotType(var.type)
    && t2.gotIdentifier(var.name)
    && (t2.accept("=") && t2.gotExpr(testInit, fs, mod) && {
      var.initAss = new Assignment(var, testInit);
      return true;
    }() || true)
    && t2.accept(";")
    && {
      var.baseOffset = -fs.size; // TODO: check
      New(vd);
      vd.var = var;
      fs.vars ~= var;
      text = t2;
      return true;
    }();
}

bool gotImportStatement(ref string text, Module mod) {
  string m;
  // import a, b, c;
  return text.accept("import") && bjoin(text.gotIdentifier(m, true), text.accept(","), {
    mod.imports ~= lookupMod(m);
  }) && text.accept(";");
}

bool gotStatement(ref string text, out Statement stmt, FrameState fs, Module mod) {
  // logln("match statement from ", text.next_text());
  Expr ex;
  AggrStatement as;
  VarDecl vd;
  Assignment ass;
  auto t2 = text;
  return
    (t2.gotExpr(ex, fs, mod) && t2.accept(";") && (text = t2, stmt = ex, true)) ||
    (text.gotVarDecl(vd, fs, mod) && (stmt = vd, true)) ||
    (text.gotAggregateStmt(as, fs, mod) && (stmt = as, true)) ||
    (text.gotAssignment(ass, fs, mod) && (stmt = ass, true));
}

bool gotFunDef(ref string text, out Function fun, Module mod) {
  Type ptype;
  string t2 = text;
  New(fun);
  New(fun.frame);
  New(fun.type);
  fun.sup = mod;
  // scope(exit) logln("frame state ", fun.frame);
  string parname;
  error = null;
  return t2.gotType(fun.type.ret)
    && t2.gotIdentifier(fun.name)
    && t2.accept("(")
    // TODO: function parameters belong on the stackframe
    && bjoin(t2.gotType(ptype) && (t2.gotIdentifier(parname) || ((parname=null), true)), t2.accept(","), {
      fun.type.params ~= stuple(ptype, parname);
    }) && t2.accept(")") && (fun.fixup, true) && t2.gotStatement(fun._body, fun.frame, mod)
    && ((text = t2), (mod.addFun(fun), true));
}

string compile(string file, bool saveTemps = false) {
  auto srcname = tmpnam("fcc_src"), objname = tmpnam("fcc_obj");
  scope(success) {
    if (!saveTemps)
      unlink(srcname.toStringz());
  }
  auto text = file.read().castLike("");
  Module mod;
  if (!text.gotModule(mod)) assert(false, "unable to eat module from "~file~": "~error);
  if (text.strip().length) assert(false, "this text confuses me: "~text.next_text()~": "~error);
  AsmFile af;
  mod.emitAsm(af);
  srcname.write(af.genAsm());
  auto cmdline = Format("as -o ", objname, " ", srcname);
  writefln("> ", cmdline);
  system(cmdline.toStringz()) == 0
    || assert(false, "Compilation failed! ");
  return objname;
}

void link(string[] objects, string output, string[] largs) {
  scope(success)
    foreach (obj; objects)
      unlink(obj.toStringz());
  string cmdline = "gcc -o "~output~" ";
  foreach (obj; objects) cmdline ~= obj ~ " ";
  foreach (larg; largs) cmdline ~= larg ~ " ";
  writefln("> ", cmdline);
  system(cmdline.toStringz());
}

void main(string[] args) {
  auto exec = args.take();
  string[] objects;
  string output;
  auto ar = args;
  string[] largs;
  bool saveTemps;
  while (ar.length) {
    auto arg = ar.take();
    if (arg == "-o") {
      output = ar.take();
      continue;
    }
    if (arg.startsWith("-l")) {
      largs ~= arg;
      continue;
    }
    if (arg == "-save-temps" || arg == "-S") {
      saveTemps = true;
      continue;
    }
    if (auto base = arg.endsWith(".cr")) {
      if (!output) output = arg[0 .. $-3];
      objects ~= arg.compile(saveTemps);
      continue;
    }
    return logln("Invalid argument: ", arg);
  }
  if (!output) output = "exec";
  objects.link(output, largs);
}

// class graph gen
import std.moduleinit;
static this() {
  ClassInfo[string] classfield;
  bool ignore(string s) {
    return !!s.startsWith("std." /or/ "object" /or/ "TypeInfo" /or/ "gcx");
  }
  foreach (mod; ModuleInfo.modules()) {
    foreach (cl; mod.localClasses) {
      if (!ignore(cl.name))
        classfield[cl.name] = cl;
      foreach (intf; cl.interfaces)
        if (!ignore(intf.classinfo.name))
          classfield[intf.classinfo.name] = intf.classinfo;
    }
  }
  auto classes = classfield.values;
  string res = "Digraph G {\n";
  scope(success) "fcc.dot".write(res);
  scope(success) res ~= "}";
  string filterName(string n) {
    // ugly band-aid to filter invalid characters
    return n.replace(".", "_").replace("!", "_").replace("(", "_").replace(")", "_");
  }
  foreach (cl; classes) {
    auto name = cl.name;
    res ~= filterName(name) ~ " [label=\"" ~ name ~ "\", shape=box]; \n";
    if (cl.base && !cl.base.name.ignore())
      res ~= filterName(name) ~ " -> " ~ filterName(cl.base.name) ~ "; \n";
    foreach (i2; cl.interfaces) {
      if (!i2.classinfo.name.ignore())
        res ~= filterName(name) ~ " -> "~filterName(i2.classinfo.name)~" [style=dashed]; \n";
    }
  }
}
