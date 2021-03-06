module ast.c_bind;

// Optimized for GL.h and SDL.h; may not work for others!! 
import ast.base, ast.modules, ast.structure, ast.casting, ast.static_arrays,
  ast.externs, ast.stringparse, ast.literals, ast.nestfun,
  ast.tuples: AstTuple = Tuple;

import tools.compat, tools.functional, alloc;
alias parseBase.startsWith startsWith;

import cache;
alias memconserve_stdfile.exists exists;

string buf;
int bufbase;
int buflen;
string readStream(InputStream IS) {
  const SIZE = 65536; // enough?
  // if (!buf) { buf = new char[SIZE]; buflen = SIZE; }
  int reslen;
  ubyte[SIZE] buffer = void;
  int i;
  do {
    i = IS.read(buffer);
    if (i < 0) throw new Exception(Format("Read error: ", i));
    /*while ((buf.length - bufbase) < reslen + i) {
      buflen *= 2;
      buf = buf[bufbase .. bufbase + reslen] ~ new char[buflen - bufbase - reslen];
      bufbase = 0;
    }
    buf[bufbase .. $][reslen .. reslen + i] = cast(string) buffer[0 .. i];*/
    buf ~= cast(string) buffer[0 .. i];
    reslen += i;
  } while (i);
  // auto res = buf[bufbase .. $][0 .. reslen];
  auto res = buf;
  buf = null;
  // bufbase += reslen;
  return res;
}


// defines string readback(string)
version(Windows) {
  import std.c.windows.windows;
  extern(System) {
    bool CreatePipe(HANDLE*, HANDLE*, SECURITY_ATTRIBUTES*, int size);
    bool SetHandleInformation(HANDLE, int mask, int flags);
    const HANDLE_FLAG_INHERIT = 0x01;
    struct PROCESS_INFORMATION {
      HANDLE hProcess, hThread;
      DWORD dwProcessId, dwThreadId;
    }
    struct STARTUPINFOA {
      DWORD cb;
      LPSTR lpReserved, lpDesktop, lpTitle;
      DWORD dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
      WORD wShowWindow, cbReserved2;
      PBYTE lpReserved2;
      HANDLE hStdInput, hStdOutput, hStdError;
    }
    alias STARTUPINFOA STARTUPINFO;
    const STARTF_USESTDHANDLES = 256;
    const CREATE_NO_WINDOW = 0x08000000;
    BOOL CreateProcessA(LPCSTR, LPSTR, LPSECURITY_ATTRIBUTES, LPSECURITY_ATTRIBUTES, BOOL, DWORD, PVOID, LPCSTR, STARTUPINFOA*, PROCESS_INFORMATION*);
  }
  extern(C) int _open_osfhandle(HANDLE, int = 0);
  extern(C) string readback(string cmd) {
    SECURITY_ATTRIBUTES attr;
    attr.nLength = SECURITY_ATTRIBUTES.sizeof;
    attr.bInheritHandle = true;
    attr.lpSecurityDescriptor = null;
    HANDLE[2] fd;
    if (!CreatePipe(&fd[0], &fd[1], &attr, 0)) fail("Couldn't create pipe");
    if (!SetHandleInformation(fd[0], HANDLE_FLAG_INHERIT, 0)) fail("Couldn't set pipe to noinherit");
    PROCESS_INFORMATION procinfo;
    STARTUPINFO startinfo;
    startinfo.cb = STARTUPINFO.sizeof;
    startinfo.hStdError = fd[1];
    startinfo.hStdOutput = fd[1];
    startinfo.hStdInput = cast(HANDLE) 0;
    startinfo.dwFlags |= STARTF_USESTDHANDLES;
    auto succ = CreateProcessA(null, toStringz(cmd),
      null, null, true, /* inherit handles */
      CREATE_NO_WINDOW, null, null,
      &startinfo, &procinfo);
    if (!succ) fail(Format("Couldn't create process '", cmd, "'"));
    CloseHandle(fd[1]);
    CloseHandle(procinfo.hProcess);
    CloseHandle(procinfo.hThread);
    
    scope fs = fastalloc!(CFile)(fdopen(_open_osfhandle(fd[0]), "r"), FileMode.In);
    return readStream(fs);
    
  }
} else {
  extern(C) {
    int pipe(int*);
    int close(int);
  }
  
  extern(C) string readback(string cmd) {
    // logln("> ", cmd);
    int[2] fd; // read end, write end
    if (-1 == pipe(fd.ptr)) throw new Exception(Format("Can't open pipe! "));
    scope(exit) close(fd[0]);
    auto cmdstr = qformat(cmd, " >&"[], fd[1], " &"[]);
    system(toStringz(cmdstr));
    close(fd[1]);
    scope fs = fastalloc!(CFile)(fdopen(fd[0], "r"), FileMode.In);
    return readStream(fs);
  }
}

import
  ast.aliasing, ast.pointer, ast.fun, ast.namespace, ast.int_literal,
  ast.fold, ast.opers;
import tools.time;

class LateType : IType {
  string name;
  IType me;
  void delegate() tryResolve;
  bool release;
  this(string n) { name = n; }
  string toString() { if (!me) return Format("(LateType ("[], name, "), unresolved)"); return name; }
  void needMe() {
    if (!me) tryResolve();
    if (!me)
      me = Single!(Void); // fallback assumption.
      // throw new Exception(Format("Couldn't resolve ", this));
  }
  override {
    string llvmSize() { needMe; return me.llvmSize; }
    string llvmType() { needMe; return me.llvmType; }
    bool isPointerLess() { needMe; return me.isPointerLess(); }
    bool isComplete() { return !!me; } // TODO: ??
    int opEquals(IType it) {
      auto lt = fastcast!(LateType) (it);
      if (lt && name == lt.name) return true;
      needMe;
      it = resolveType(it);
      return it is me || it == me;
    }
    string mangle() { needMe; return me.mangle(); }
    IType proxyType() { if (!release) return null; /* delay, defer */ needMe; return me; }
  }
}

const c_tree_expr = "tree.expr"
  " >tree.expr.vardecl >tree.expr.type_stringof >tree.expr.type_mangleof"
  " >tree.expr.classid >tree.expr.iter >tree.expr.iter_range"
  " >tree.expr.new >tree.expr.eval >tree.expr.cast >tree.expr.veccon"
  " >tree.expr.cast_explicit_default >tree.expr.cast_convert"
  " >tree.expr.scoped >tree.expr.stringex >tree.expr.dynamic_class_cast"
  " >tree.expr.properties >tree.expr.veccon";

const c_tree_expr_matcher = matchrule_static(c_tree_expr);

TLS!(Expr delegate(ref string)) specialCallback;
static this() { New(specialCallback); }

bool parsingCHeader() {
  auto ns = namespace();
  while (ns) {
    auto mns = ns.get!(MiniNamespace);
    if (!mns) return false;
    if (mns.id == "parse_header") return true;
    ns = mns.sup;
  }
  return false;
}

Named[string] global_c_memo_cache;

void parseHeader(string filename, string src) {
  auto start_time = sec();
  int newsrc_length;
  string newsrc;
  auto backup_src = src;
src_cleanup_redo: // count, then copy
  src = backup_src;
  void addSrc(string text) {
    if (!newsrc) newsrc_length += text.length;
    else {
      newsrc[newsrc_length .. newsrc_length + text.length] = text;
      newsrc_length += text.length;
    }
  }
  string[string] cpp_defines;
  bool inEnum;
  string[] buffer;
  void flushBuffer() {
    foreach (def; buffer) { addSrc(def); addSrc(";"); }
    delete buffer; buffer = null;
  }
  while (src.length) {
    string line;
    void advance() { line = src.slice("\n"[]).mystripl(); }
    advance;
    // logln("-- ", inEnum, " ", line);
    // special handling for fenv.h; shuffle #defines past the enum
    if (line.startsWith("enum")) inEnum = true;
    if (line.startsWith("}")) { inEnum = false; addSrc(line); flushBuffer; continue; }
    if (line.startsWith("#")) {
      if (auto rest = line.startsWith("#define")) {
        if (newsrc) {
          string id;
          if (!rest.gotIdentifier(id)) fail; // what
          if (!rest.mystripl().length) continue; // ignore this kind of #define.
          cpp_defines[id] = rest; // DO NOT STRIP, breaks macro/ () distinction
        }
      }
      continue;
    }
    if (line.startsWith("static inline")) {
      if (line.endsWith("}")) continue; // oneliner
      // skip across
      do {
        advance;
      } while (!line.startsWith("#") && !line.startsWith("}"));
      continue;
    }
    addSrc(line); addSrc(" ");
  }
  if (!newsrc) {
    newsrc = new char[newsrc_length];
    newsrc_length = 0;
    goto src_cleanup_redo;
  }
  // no need to remove comments; the preprocessor already did that
  auto statements = newsrc.split(";") /map/ &strip;
  // write("dump.txt", qformat(statements).replace(", ", "\n"));
  // mini parser
  auto cachep = &(new Stuple!(Named[string]))._0;
  auto myNS = fastalloc!(MiniNamespace)("parse_header"[]);
  myNS.sup = namespace();
  myNS.internalMode = true;
  namespace.set(myNS);
  scope(exit) namespace.set(myNS.sup);
  void add(string name, Named n) {
    if (!name.strip().length) fail;
    if (myNS.lookup(name, true)) { return; } // duplicate definition. meh.
    auto ea = fastcast!(ExprAlias)~ n;
    if (ea) {
      if (!gotImplicitCast(ea.base, (IType it) { return !fastcast!(AstTuple) (it); })) {
        logln("Weird thing ", ea);
        fail;
      }
    }
    
    if (auto p = name in global_c_memo_cache) {
      n = *p; // memoize: use global C namespace to disambiguate stuff
    } else global_c_memo_cache[name] = n;
    // logln("add ", name, " <- ", n);
    myNS._add(name, fastcast!(Object)(n));
    if (auto ns = fastcast!(Namespace) (n)) ns.sup = null; // lol
    (*cachep)[name] = n;
  }
  
  void delegate()[] resolves;
  scope(success)
    foreach (dg; resolves)
      dg();
  IType matchSimpleType(ref string text) {
    string cache_text, cache_ident, cache_t2; bool cache_res;
    bool accept(string s) {
      auto t2 = text;
      // if (auto rest = t2.startsWith(s)) { text = rest; return true; }
      // t2.eatComments();
      // if (auto rest = t2.startsWith(s)) { text = rest; return true; }
      string part2;
      if (text is cache_text) {
        if (!cache_res) return false;
        part2 = cache_ident;
        t2 = cache_t2;
      } else {
        cache_text = text;
        if (!t2.gotCIdentifier(part2)) {
          cache_res = false;
          return false;
        }
        cache_t2 = t2;
        cache_ident = part2;
        cache_res = true;
      }
      if (s != part2) return false;
      text = t2;
      return true;
    }
    string accept_cache, accept_ident, accept_res_cache; bool accept_res;
    text = text.mystripl();
    if (auto rest = text.startsWith("...")) { text = rest; return Single!(Variadic); }
    if (text.startsWith("(")) return null; // shortcut
    bool unsigned;
    if (accept("_Bool")) return Single!(Char);
    if (accept("DWORD")) return Single!(SysInt);
    if (accept("unsigned")) unsigned = true;
    else {
      accept("signed");
      accept("__signed__"); // gcc??
    }
    
    if (accept("long")) {
      if (accept("int")) return Single!(SysInt);
      if (accept("long")) { accept("int"); return Single!(Long); }
      return unsigned?Single!(SizeT):Single!(SysInt);
    }
    if (accept("int")) return Single!(SysInt);
    if (accept("short")) { accept("int"); return Single!(Short); }
    if (accept("char")) return Single!(Char);
    if (unsigned) return Single!(SysInt);
    
    if (accept("void")) return Single!(Void);
    if (accept("float")) return Single!(Float);
    if (accept("double")) return Single!(Double);
    if (accept("struct") || accept("union")) {
      string name;
      if (!text.gotIdentifier(name))
        return Single!(Void);
      if (auto p = name in *cachep) return fastcast!(IType)~ *p;
      else {
        auto lt = fastalloc!(LateType)(name);
        auto dg = stuple(lt, name, cachep) /apply/
        delegate void(LateType lt, string name, typeof(cachep) cachep) {
          if (auto p = name in *cachep) {
            lt.me = fastcast!(IType)~ *p;
            if (auto al = fastcast!(TypeAlias) (lt.me))
              if (al.base is lt) {
                // logln("CIRCULAR TYPE: ", name);
                // fail;
                goto makevoid;
              }
          }
          else {
            // logln(name, " didn't resolve in time");
            // fail;
            makevoid:
            lt.me = Single!(Void);
          }
        };
        auto dg2 = stuple(lt, dg) /apply/
        delegate void(LateType lt, void delegate() dg) {
          lt.release = true;
          dg();
        };
        lt.tryResolve = dg;
        resolves ~= dg2;
        return lt;
      }
    }
    string id;
    if (!text.gotIdentifier(id)) return null;
    if (auto p = id in *cachep) return fastcast!(IType) (*p);
    if (auto ty = fastcast!(IType) (namespace().lookup(id, true))) {
      if (auto n = fastcast!(Named) (ty)) (*cachep)[id] = n;
      return ty;
    }
    return null;
  }
  void eatPointless(ref string text) { // does nothing in neat
    while (true) {
      if (text.accept("const")) continue;
      if (text.accept("__const")) continue;
      if (text.accept("__restrict")) continue;
      break;
    }
  }
  IType matchType(ref string text) {
    auto t2 = text;
    if (t2.accept(")")) return null;
    text.eatPointless();
    if (auto ty = matchSimpleType(text)) {
      while (text.accept("*")) {
        text.eatPointless();
        auto p = fastalloc!(Pointer)(Single!(SysInt));
        p.target = ty; // manually initialize to skip forcedConvert so we give late types more time to resolve
        ty = p;
      }
      return ty;
    } else return null;
  }
  IType matchParam(ref string text) {
    auto t2 = text;
    IType ty = matchType(t2);
    if (!ty) return null;
    t2.eatPointless();
    string id;
    if (!gotIdentifier(t2, id)) {
      if (t2.accept("(") && t2.accept("*")) {
        gotIdentifier(t2, id);
        if (!t2.accept(")") || !t2.accept("(")) {
          return null;
        }
        Argument[] args;
        while (!t2.accept(")")) {
          auto p = t2.matchParam();
          if (!p) return null;
          args ~= Argument(p);
        }
        t2.accept(",");
        text = t2;
        return fastalloc!(FunctionPointer)(ty, Cfilter(args), true);
      }
    }
    text = t2;
    if (auto sa = fastcast!(StaticArray)~ resolveType(ty)) {
      ty = fastalloc!(Pointer)(sa.elemType);
    }
    redo:if (text.startsWith("[")) {
      ty = fastalloc!(Pointer)(ty);
      text.slice("]");
      goto redo;
    }
    text.accept(",");
    return ty;
  }
  bool useStdcall, noreturn;
  void eatAttribute(ref string s) {
    useStdcall = false;
    noreturn = false;
    retry: s = s.strip();
    if (auto rest = s.startsWith("__attribute__"[])) {
      if (rest.between("((", "))") == "__stdcall__") useStdcall = true;
      if (rest.between("((", "))") == "__noreturn__") noreturn = true;
      s = rest.between(") ", "");
      goto retry;
    }
  }
  Stuple!(string[], string)[string] macros;
  bool[char*] loopbreaker; // recursion loop avoidance, lol
  bool readCExpr(ref string source, ref Expr res) {
    // logln("readCExpr ", source);
    source = mystripl(source);
    if (!source.length) return false;
    auto s2 = source;
    // fairly obvious what this is
    if (source.endsWith("_TYPE"[]) || s2.matchType()) return false;
    int i;
    s2 = source;
    // (foo)
    {
      IType ty;
      auto s3 = s2;
      if (s3.accept("(") && (ty = matchType(s3), ty) && s3.accept(")") && readCExpr(s3, res)) {
        IType alt;
        if (Single!(Char) == ty) alt = Single!(Byte); // same type in C
        // work around numeric overflow issue for (unsigned)-1 - accept size_t, then hardcast to int
        if (Single!(SysInt) == ty) alt = Single!(SizeT);
        res = collapse(forcedConvert(res));
        // res = reinterpret_cast(ty, res);
        // IType[] tried;
        if (!gotImplicitCast(res, ty, (IType it) { /*tried ~= it;*/ return test(it == ty || alt && it == alt); })) {
          // logln("reject ", source.nextText(), " because no conversion of ", res, " to ", ty, " (tried ", tried, ")");
          return false;
        }
        res = reinterpret_cast(ty, res);
        source = s3;
        return true;
      }
    }
    {
      auto s3 = s2;
      Expr res2;
      if (s3.accept("(") && readCExpr(s3, res2) && s3.accept(")")) {
        res = res2;
        source = s3;
        return true;
      }
    }
    if (s2.accept("'")) { // char
      if (!s2.length) return false;
      auto ch = s2[0..1]; s2 = s2[1 .. $];
      if (!s2.accept("'")) return false;
      res = reinterpret_cast(Single!(Char), fastalloc!(DataExpr)(cast(ubyte[]) ch));
      source = s2;
      return true;
    }
    if (s2.gotInt(i)) {
      if (auto rest = s2.startsWith("U"[])) s2 = rest; // TODO
      if (s2.accept("LL")) return false; // long long
      s2.accept("L");
      if (!s2.length /* special handling for separators */ || s2.startsWith(","[]) || s2.startsWith(")"[]) || s2.startsWith("<"[]) || s2.startsWith(">"[])) {
        res = fastalloc!(IntExpr)(i);
        source = s2;
        return true;
      }
    }
    s2 = source;
    if (s2.startsWith("__PRI"[])) return false; // no chance to parse
    string ident;
    if (s2.gotIdentifier(ident) && !s2.length) {
      // float science notation constants
      if (ident.length > 2) {
        if (ident[0] == 'e' || ident[0] == 'E')
          if (ident[1] == '+' || ident[1] == '-') return false;
        if (ident[0] == '1' && (ident[1] == 'e' || ident[1] == 'E'))
          if (ident[2] == '+' || ident[2] == '-') return false;
      }
      if (auto p = ident in *cachep) {
        if (auto ex = fastcast!(Expr)(*p)) {
          res = ex;
          source = null;
          return true;
        }
        // force this into an Expr format by funptring it
        // this will be turned back into a Function in readCObj
        if (auto fun = fastcast!(Function)(*p)) {
          res = fastalloc!(FunRefExpr)(fun);
          source = null;
          return true;
        }
        logln("not an expr: ", *p);
        fail;
        return false;
      }
      // logln("IDENT ", ident);
    }
    if (auto tup = ident in macros) {
      auto backup = s2;
      auto args = tup._0, str = tup._1;
      // logln("macro parse for ", ident, " on ", s2);
      if (!s2.accept("(")) return false;
      Object[] objs;
      while (true) {
        Expr ex;
        string ident2;
        if (readCExpr(s2, ex)) objs ~= fastcast!(Object) (ex);
        else if (auto ty = matchType(s2)) objs ~= fastcast!(Object) (ty);
        else if (s2.gotCIdentifier(ident2) && ident2 in *cachep) {
          objs ~= fastcast!(Object)((*cachep)[ident2]);
        } else {
          // logln("macro arg fail ", s2);
          return false;
        }
        if (!s2.accept(",")) break;
      }
      if (!s2.accept(")")) {
        // logln("fail 2 on ", s2);
        return false;
      }
      if (objs.length != args.length) {
        // logln("length fail");
        return false;
      }
      auto myNS2 = fastalloc!(MiniNamespace)("parse_macro"[]);
      myNS2.sup = namespace();
      myNS2.internalMode = true;
      namespace.set(myNS2);
      scope(exit) namespace.set(myNS2.sup);
      foreach (k, arg; objs) {
        // logln(args[k], " -> ", arg);
        myNS2._add(args[k], arg);
      }
      auto popCache = pushCache(); scope(exit) popCache();
      
      if (!readCExpr(str, res)) {
        // logln("macro fail ", str);
        return false;
      }
      res = collapse(res);
      // logln(ident, " -- ", backup, " (args ", tup._0, ", str ", tup._1, ") => ", objs, " => ", res);
      source = s2;
      return true;
    }
    s2 = source;
    if (s2.startsWith("__attribute__ (("[])) s2 = s2.between("))", "");
    // logln(" @ '", source, "'");
    s2 = s2.mystripl();
    if (!s2.length) return false;
    auto old_dg = *specialCallback();
    Expr callback(ref string text) {
      auto tp = text.ptr;
      if (tp in loopbreaker) return null;
      loopbreaker[tp] = true;
      scope(exit) loopbreaker.remove(tp);
      Expr res;
      if (readCExpr(text, res)) return res;
      if (old_dg) if (auto res = old_dg(text)) return res;
      return null;
    }
    *specialCallback() = &callback;
    scope(exit) *specialCallback() = old_dg;
    auto lenbackup = *lenient.ptr();
    *lenient.ptr() = true;
    scope(exit) *lenient.ptr() = lenbackup;
    auto s3 = s2;
    try res = fastcast!(Expr) (parse(s2, mixin(c_tree_expr_matcher)));
    catch (Exception ex) {
      // logln("subparse ", s3, " => ", ex);
      return false; // no biggie
    }
    // logln("subparse ", s3, " => ", res);
    if (!res) return false;
    source = s2;
    return true;
  };
  bool readCObj(ref string source, ref Object obj) {
    Expr ex;
    if (!readCExpr(source, ex)) return false;
    // of course, this breaks #define foo &bar
    // do we care? we don't care because literally nobody does that.
    if (auto fre = fastcast!(FunRefExpr)(ex)) {
      obj = fre.fun;
    } else {
      obj = fastcast!(Object)(ex);
    }
    return true;
  }
  while (statements.length) {
    auto stmt = statements.take(), start = stmt;
    // logln(filename, "> ", stmt);
    useStdcall = false;
    noreturn = false;
    stmt.accept("__extension__");
    bool isTypedef;
    if (stmt.accept("typedef")) isTypedef = true;
    stmt.eatPointless();
    if (stmt.accept("enum")) {
      auto entries = stmt.between("{", "}").split(",");
      if (entries.length && !entries[$-1].strip().length)
        entries = entries[0..$-1]; // A, B, C,
      Expr cur = mkInt(0);
      Named[] elems;
      foreach (entry; entries) {
        // logln("> "[], entry);
        entry = entry.replace("(unsigned long)", ""); // hack
        string id;
        if (!gotIdentifier(entry, id)) {
          stmt = entry;
          goto giveUp;
        }
        if (entry.accept("=")) {
          Expr ex;
          if (!readCExpr(entry, ex) || entry.strip().length) {
            // logln("--", entry);
            goto giveUp;
          }
          ex = collapse(ex);
          cur = ex;
        }
        elems ~= fastalloc!(ExprAlias)(cur, id);
        cur = collapse(lookupOp("+", cur, mkInt(1)));
      }
      // logln("Got from enum: ", elems);
      stmt = stmt.between("}", "");
      string name;
      if (stmt.strip().length && (!gotIdentifier(stmt, name) || stmt.strip().length)) {
        // logln("fail on '", stmt, "'");
        goto giveUp;
      }
      foreach (elem; elems) add(elem.getIdentifier(), elem);
      if (name)
        add(name, fastalloc!(TypeAlias)(Single!(SysInt), name));
      continue;
    }
    {
      auto st2 = stmt;
      bool advanced;
      bool consumedStruct(void delegate(string, string, IType) match) {
        bool isUnion;
        if (!st2.accept("struct")) {
          if (st2.accept("union")) isUnion = true;
          else return false;
        }
        string ident;
        gotIdentifier(st2, ident);
        if (!st2.accept("{")) return false;
        auto startstr = st2;
        auto st = fastalloc!(Structure)(ident);
        // st.minAlign = 4;
        st.isUnion = isUnion;
        const debugStructs = false;
        while (true) {
          static if (debugStructs)
            logln(ident, ">", st2);
          if (st2.startsWith("#define"[]))
            goto skip;
          IType ty;
          {
            auto st3 = st2;
            if ((st3.accept("struct") || st3.accept("union")) && st3.accept("{")) {
              if (!consumedStruct((string name, string ident, IType type) {
                ty = type;
                st2 = name;
              })) return false;
            }
          }
          if (!ty) ty = matchType(st2);
          if (!ty) {
            if (isUnion) {
              static if (debugStructs) logln("WARN incomplete union: experimental code!");
              goto skip;
            } else {
              static if (debugStructs) logln("type failed");
              goto giveUp1;
            }
          }
          while (true) {
            auto pos = st2.find("sizeof");
            if (pos == -1) break;
            auto block = st2[pos .. $].between("(", ")");
            auto sty = matchType(block);
            if (!sty) {
              static if (debugStructs) logln("sizeof loop match failed");
              goto giveUp1;
            }
            auto translated = Format(guessSize(sty));
            st2 = st2[0 .. pos] ~ translated ~ st2[pos .. $].between(")", "");
            // logln("st2 => ", st2);
          }
          while (true) {
            auto atpos = st2.find("__attribute__");
            if (atpos == -1) break;
            st2 = st2[0..atpos] ~ st2[atpos .. $].between("))", "");
          }
          string name3;
          auto st3 = st2;
          Expr size;
          st3 = st3.replace("(int)", ""); // hax
          if (gotIdentifier(st3, name3) && st3.accept("[") && readCExpr(st3, size) && st3.accept("]")) {
            redo:
            size = collapse(size);
            if (fastcast!(AstTuple)~ size.valueType()) {
              // unwrap "(foo)"
              logln("at ", st2.nextText(), ":");
              logln("unwrap ", (cast(Object) size).classinfo.name, " ", size);
              size = (fastcast!(StructLiteral)~ (fastcast!(RCE)~ size).from)
                .exprs[$-1];
              goto redo;
            }
            auto ie = fastcast!(IntExpr)~ size;
            // logln("size: ", size);
            if (!ie) {
              static if (debugStructs) logln("size ie cast failed");
              goto giveUp1;
            }
            fastalloc!(RelMember)(name3, fastalloc!(StaticArray)(ty, ie.num), st);
            // logln("rest: ", st3);
            if (st3.strip().length) {
              static if (debugStructs) logln("left over ", st3, ", failed");
              goto giveUp1;
            }
            goto skip;
          }
          // logln(">> ", st2);
          if (st2.find("(") != -1) {
            if (st2.accept("(") && st2.accept("*")) {
              string name;
              if (!gotIdentifier(st2, name)) {
                static if (debugStructs) logln("fail in fp ", st2);
                goto giveUp1;
              }
              ty = Single!(Pointer, Single!(Void));
              st2 = name;
            } else {
              // alias to void for now.
              if (ident) add(ident, fastalloc!(TypeAlias)(Single!(Void), ident));
              static if (debugStructs) logln("can't handle the ", st2, ". fail. ");
              goto giveUp1; // can't handle yet
            }
          }
          foreach (var; st2.split(",")) {
            if (Single!(Void) == ty) {
              static if (debugStructs) logln("void base type at ", startstr, ". fail. ");
              goto giveUp1;
            }
            fastalloc!(RelMember)(var.strip(), ty, st);
          }
        skip:
          st2 = statements.take(); advanced = true;
          if (st2.accept("}")) break;
        }
        IType ty = st;
        while (st2.accept("*")) {
          ty = fastalloc!(Pointer)(ty);
        }
        auto name = st2.strip();
        if (!name.length) name = ident.strip();
        if (!name.length) goto giveUp1;
        if (!st.name.length) st.name = name;
        static if (debugStructs)
          logln(ident, "> success: '", name, "' -> ", ty);
        match(name, ident, ty);
        return true;
        giveUp1:
        static if (debugStructs)
          logln("give up on struct ", ident, " at ", st2);
        while (true) {
          static if (debugStructs) logln("stmt: ", st2, " in ", startstr);
          st2 = statements.take();
          advanced = true;
          if (st2.accept("}")) {
            static if (debugStructs) logln("info ", st2);
            return false;
          }
        }
        // logln(">>> ", st2);
        return false;
      }
      bool addedSomething;
      consumedStruct((string name, string ident, IType type) {
        addedSomething = true;
        add(name, fastalloc!(TypeAlias)(type, name));
        if (ident && ident != name)
          // neat doesn't have a separate struct namespace, so add it to regular one
          add(ident, fastalloc!(TypeAlias)(type, ident));
      });
      if (addedSomething || advanced) continue;
    }
    if (isTypedef) {
      auto target = matchType(stmt);
      // logln("typedef target ", target, ", left ", stmt);
      string name;
      if (!target) goto giveUp;
      if (stmt.accept("{")) {
        while (true) {
          stmt = statements.take();
          if (stmt.accept("}")) break;
        }
      }
      {
        auto st2 = stmt;
        // Wtf, glew
        bool ateAttribute(ref string s) { s.eatAttribute(); return true; }
        if (st2.accept("(") && st2.ateAttribute() && st2.accept("*") && gotIdentifier(st2, name) && st2.accept(")")) {
          if (!st2.accept("(")) goto giveUp;
          IType ret = target; Argument[] args;
          while (true) {
            IType argtype = matchType(st2);
            if (!argtype) {
              // logln("Bad type in FP ", stmt, " at ", st2);
              goto giveUp;
            }
            string argname;
            gotIdentifier(st2, argname);
            
            args ~= Argument(argtype);
            if (st2.accept(",")) continue;
            if (st2.accept(")")) break;
            goto giveUp;
          }
          auto fp = fastalloc!(FunctionPointer)(ret, Cfilter(args), true);
          fp.stdcall = useStdcall;
          target = fp;
          stmt = st2;
          goto typedef_done;
        }
      }
      if (!gotIdentifier(stmt, name)) {
        auto st2 = stmt;
        // function pointer
        if (!st2.accept("(")) goto giveUp;
        Argument[] args;
        do {
          auto partype = matchType(st2);
          if (!partype) goto giveUp;
          string parname;
          st2.gotIdentifier(parname);
          args ~= Argument(partype);
        } while (st2.accept(","));
        if (!st2.accept(")")) goto giveUp;
        // logln("get function pointer named ", name, " (ret ", target, ") , params ", args, " @", st2);
        target = fastalloc!(FunctionPointer)(target, Cfilter(args), true);
        stmt = st2;
      }
      string typename = name;
      if (matchSimpleType(typename) && !typename.strip().length) {
        // logln("Skip type ", name, " for duplicate. ");
        continue;
      }
      Expr size;
      redo2:
      auto st3 = stmt;
      if (st3.accept("[") && readCExpr(st3, size) && st3.accept("]")) {
        redo3:
        size = collapse(size);
        // unwrap "(bar)" again
        if (fastcast!(AstTuple)~ size.valueType()) {
          size = (fastcast!(StructLiteral)~ (fastcast!(RCE)~ size).from).exprs[$-1];
          goto redo3;
        }
        if (!fastcast!(IntExpr) (size)) goto giveUp;
        target = fastalloc!(StaticArray)(target, (fastcast!(IntExpr)~ size).num);
        stmt = st3;
        goto redo2;
      }
      if (stmt.accept("[")) goto giveUp;
      if (stmt.accept(",")) {
        // logln("giving up on ", stmt);
        goto typedef_done;
      }
      if (stmt.length) {
        auto st4 = stmt;
        if (st4.accept("__attribute__") && st4.accept("((")
        &&  st4.accept("__mode__") && st4.accept("(")) {
          if (Single!(SysInt) == resolveType(target)) {
            if (st4.accept("__QI__") && st4.accept(")") && st4.accept("))")) {
              stmt = st4;
              target = Single!(Byte);
            }
            else if (st4.accept("__HI__") && st4.accept(")") && st4.accept("))")) {
              stmt = st4;
              target = Single!(Short);
            }
            else if (st4.accept("__SI__") && st4.accept(")") && st4.accept("))")) {
              stmt = st4;
              // int already
            }
            else if (st4.accept("__DI__") && st4.accept(")") && st4.accept("))")) {
              stmt = st4;
              target = Single!(Long);
            }
          }
        }
        stmt.eatAttribute();
        if (stmt.strip().length) {
          // logln("LEFTOVER: ", stmt);
          // logln("(target ", target, " = ", name, ")");
          goto giveUp;
        }
      }
      
    typedef_done:
      bool strict;
      auto rt = resolveTypeHard(target, true);
      // strict |= test(Single!(Void) == rt);
      auto test = rt;
      while (true) {
        if (auto pt = fastcast!(Pointer)(test)) {
          test = resolveTypeHard(pt.target, true);
          continue;
        }
        break;
      }
      auto lt = fastcast!(LateType)(test);
      strict |= lt && !lt.me;
      // logln(name, " strict? ", strict, " on ", rt);
      auto ta = fastalloc!(TypeAlias)(target, name, false, strict);
      // logln("add ", name, " = ", ta);
      (*cachep)[name] = ta;
      continue;
    }
    
    stmt.accept("extern");
    stmt.eatAttribute();
    
    if (auto ret = stmt.matchType()) {
      stmt.eatAttribute();
      string name;
      bool funptr_mode;
      if (!gotIdentifier(stmt, name)) {
        if (stmt.accept("*")) funptr_mode = true;
        // this is apparently valid syntax :o
        if (!stmt.accept("(") || !gotIdentifier(stmt, name) || !stmt.accept(")")) {
          goto giveUp;
        }
      }
      if (!stmt.accept("(")) {
        if (!stmt.length) {
          add(name, fastalloc!(ExternCGlobVar)(ret, name));
          continue;
        }
        goto giveUp;
        // logln(">> ", stmt);
        fail;
      }
      IType[] args;
      // logln(name, "@ ", stmt, ", get types");
      while (true) {
        if (auto ty = matchParam(stmt)) args ~= ty;
        else break;
      }
      // logln(name, "@ ", stmt, ", got ", args);
      if (!stmt.accept(")")) goto giveUp;
      // Wait. What?
      // is this an old assumption to fix bad C ABI support? Take it out for now.
      // DO NOT REENABLE WITHOUT COMMENTING WHY
      /*foreach (ref arg; args)
        if (Single!(Short) == resolveType(arg))
          arg = Single!(SysInt);*/
      if (funptr_mode) {
        auto fptype = fastalloc!(FunctionPointer)(ret, Cfilter(args /map/ (IType it) { return Argument(it); }), true);
        fptype.stdcall = useStdcall;
        auto ec = fastalloc!(ExternCGlobVar)(fptype, name);
        add(name, ec);
      } else {
        auto fun = fastalloc!(Function)();
        fun.name = name;
        fun.extern_c = true;
        fun.type = fastalloc!(FunctionType)();
        fun.type.ret = ret;
        fun.type.params = Cfilter(args /map/ (IType it) { return Argument(it); });
        fun.type.stdcall = useStdcall;
        fun.sup = null;
        fun.noreturn = noreturn;
        add(name, fun);
      }
      continue;
    }
    giveUp:;
    // logln("Gave up on |", stmt, "| ", start);
  }
  bool removed_resolvable_exprs() {
    string[string] newdefines;
    bool gotAny;
    foreach (key, value; cpp_defines) {
      void add2(Named named) { add(key, named); gotAny = true; }
      Expr ex;
      try {
        Object obj;
        auto stmt = value;
        if (!readCObj(stmt, obj) || stmt.mystripl().length) {
          goto giveUp;
        }
        ex = fastcast!(Expr)(obj);
        if (!ex) {
          auto fun = fastcast!(Function)(obj);
          if (!fun) fail;
          // logln("obj got ", fun);
          add2(fun);
          continue;
        }
      } catch (Exception ex) {
        goto giveUp;
      }
      auto vt = ex.valueType();
      if (auto fp = fastcast!(FunctionPointer)(resolveType(vt))) {
        // you almost certainly want this to act like a function, don't you?
        auto pf = fastalloc!(PointerFunction!(Function)) (ex);
        // logln("pf got ", pf);
        add2(pf);
        continue;
      }
      auto ea = fastalloc!(ExprAlias)(ex, key);
      // logln("got ", ea);
      add2(ea);
      continue;
    giveUp:
      newdefines[key] = value;
    }
    cpp_defines = newdefines;
    return gotAny;
  }
  bool removed_resolvable_types() {
    string[string] newdefines; bool gotAny;
    foreach (key, value; cpp_defines) {
      void add2(Named named) { add(key, named); gotAny = true; }
      auto stmt = value;
      if (auto ty = matchType(stmt)) {
        if (!stmt.mystripl().length) {
          auto ta = fastalloc!(TypeAlias)(ty, key);
          add(key, ta);
          continue;
        }
      }
      newdefines[key] = value; // failed to do anything with
    }
    cpp_defines = newdefines;
    return gotAny;
  }
  void remove_macros() {
    string[string] newdefines;
    foreach (key, value; cpp_defines) {
      string[] macroArgs;
      bool isMacroParams(ref string s) {
        auto s2 = s;
        // NOT accept(): spacing matters!
        // it's only a macro if the () comes directly after the name!
        if (!s2.startsWith("("[])) return false;
        s2 = s2[1..$];
        while (true) {
          string id;
          if (!s2.gotIdentifier(id)) break;
          macroArgs ~= id;
          if (!s2.accept(",")) break;
        }
        if (!s2.accept(")")) return false;
        s = s2;
        return true;
      }
      if (isMacroParams(value)) {
        macros[key] = stuple(macroArgs, value);
        continue;
      }
      newdefines[key] = value;
    }
    cpp_defines = newdefines;
  }
  // being string-based, this step is not dependent on other #defines
  remove_macros;
  
  bool try_exprs = true, try_types = true;
  while (true) {
    if (try_types)
      if (removed_resolvable_types()) try_exprs = true;
      else try_types = false;
    if (!try_exprs && !try_types) break;
    
    if (try_exprs)
      if (removed_resolvable_exprs()) try_types = true;
      else try_exprs = false; // no point unless we get an expr
    if (!try_exprs && !try_types) break; // nothing left to do
  }
  if (cpp_defines.length) {
    // logln("leftover unresolved defines: ", cpp_defines);
    // fail;
  }
  auto ns = myNS.sup;
  foreach (key, value; *cachep) {
    if (ns.lookup(key)) {
      // logln("Skip ", key, " as duplicate. ");
      continue;
    }
    // logln("Add ", value);
    ns.add(key, value);
  }
  // logSmart!(false)("# Got ", (*cachep).length, " definitions from ", filename, " in ", sec() - start_time, "s. ");
}

string[] defines;
string[][string] prepend;
Object defines_sync;

import ast.pragmas;
static this() {
  New(defines_sync);
  pragmas["define"] = delegate Object(Expr ex) {
    if (!gotImplicitCast(ex, (Expr ex) { ex = collapse(ex); return !!fastcast!(StringExpr) (ex); }))
      throw new Exception("String expected for pragma(define, ...)");
    ex = collapse(ex);
    string str = (fastcast!(StringExpr) (ex)).str;
    synchronized(defines_sync) defines ~= str.strip();
    return Single!(NoOp);
  };
  pragmas["include_prepend"] = delegate Object(Expr ex) {
    if (!gotImplicitCast(ex, (Expr ex) { ex = collapse(ex); return !!fastcast!(StringExpr) (ex); }))
      throw new Exception("\"file1 < file2\" string expected for pragma(include_prepend, ...)");
    ex = collapse(ex);
    string str = (fastcast!(StringExpr) (ex)).str;
    auto file1 = str.slice("<").strip(), file2 = str.strip();
    if (!file1.length || !file2.length) 
      throw new Exception(
        Format("Invalid pragma parameter for include_prepend (\"file1 < file2\" expected): ", ex));
    synchronized(defines_sync) {
      if (!(file2 in prepend)) prepend[file2] = null;
      prepend[file2] ~= file1;
    }
    return Single!(NoOp);
  };
}

void performCImport(string name) {
  // prevent injection attacks
  foreach (ch; name)
    if (!(ch in Range['a'..'z'].endIncl)
      &&!(ch in Range['A'..'Z'].endIncl)
      &&!(ch in Range['0' .. '9'].endIncl)
      &&("/_-.".find(ch) == -1)
    )
      throw new Exception("Invalid character in "~name~": "~ch~"!");
  // prevent snooping
  if (name.find("..") != -1)
    throw new Exception("Can't use .. in "~name~"!");
  
  string findfile(string s) {
    if (s.exists()) return s;
    foreach (path; include_path) {
      auto combined = path.sub(s);
      if (combined.exists()) return combined;
    }
    throw new Exception(Format("Couldn't find ", s, "! Tried ", include_path));
  }
  string filename = findfile(name);
  string extra;
  if (!isARM()) extra = " -m32";
  synchronized(defines_sync) {
    extra ~= (defines /map/ (string s) { return " -D"~s; }).join("");
    if (name in prepend) extra ~= " "~(prepend[name] /map/ &findfile).join(" ");
  }
  string mygcc;
  version(Windows) mygcc = path_prefix~"gcc";
  else mygcc = path_prefix~platform_prefix~"gcc";
  auto cmdline = 
    mygcc~extra~" -Xpreprocessor -dD -E "
    ~ (include_path
      /map/ (string s) { return "-I"~s; }
      ).join(" ")
    ~ " " ~ filename;
  // logln("? ", cmdline);
  auto src = readback(cmdline);
  parseHeader(filename, src);
}

import ast.fold, ast.literal_string;
Object gotSpecialCallback(ref string text, ParseCb cont, ParseCb rest) {
  Expr ex;
  auto dg = *specialCallback();
  if (!dg) return null;
  auto t2 = text;
  auto res = dg(t2);
  if (!res) return null;
  text = t2;
  return fastcast!(Object) (res);
}
mixin DefaultParser!(gotSpecialCallback, "tree.expr.special_callback", "2302"); // must be before int literal

static this() {
  ast.modules.specialHandler = delegate Module(string name) {
    auto hdr = name.startsWith("c."[]);
    if (!hdr) return null;
    auto hfile = hdr.replace(".", "/") ~ ".h";
    
    auto mod = fastalloc!(Module)(name, hfile);
    mod.dontEmit = true;
    
    auto backup = namespace();
    scope(exit) namespace.set(backup);
    namespace.set(mod);
    
    auto backupmod = current_module();
    scope(exit) current_module.set(backupmod);
    current_module.set(mod);
    
    performCImport(hfile);
    return mod;
  };
}

// Oh C. Oh C, oh C.
Argument[] Cfilter(Argument[] arg) {
  if (arg.length == 1 && arg[0].type == Single!(Void)) return null;
  return arg;
}
