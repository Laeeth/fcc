module parseBase;

import casts;

version(Windows) {
  int bcmp (char* from, char* to, int count) {
    while (count-- > 0) {
      if (*from++ != *to++) return 1;
    }
    return 0;
  }
} else {
  extern(C) int bcmp(char*, char*, int);
}

version(Windows) { } else pragma(set_attribute, faststreq_samelen_nonz, optimize("-O3"));
int faststreq_samelen_nonz(string a, string b) {
  // the chance of this happening is approximately 0.1% (I benched it)
  // as such, it's not worth it
  // if (a.ptr == b.ptr) return true; // strings are assumed immutable
  if (a.length > 4) {
    if ((cast(int*) a.ptr)[0] != (cast(int*) b.ptr)[0]) return false;
    return bcmp(a.ptr + 4, b.ptr + 4, a.length - 4) == 0;
  }
  int ai = *cast(int*) a.ptr, bi = *cast(int*) b.ptr;
  /**
   1 => 0x000000ff => 2^8 -1
   2 => 0x0000ffff => 2^16-1
   3 => 0x00ffffff => 2^24-1
   4 => 0xffffffff => 2^32-1
   **/
  uint mask = (0x01010101U >> ((4-a.length)*8))*0xff;
  // uint mask = (1<<((a.length<<3)&0x1f))-(((a.length<<3)&32)>>5)-1;
  // uint mask = (((1<<((a.length<<3)-1))-1)<<1)|1;
  return (ai & mask) == (bi & mask);
}

version(Windows) { } else pragma(set_attribute, faststreq, optimize("-O3"));
int faststreq(string a, string b) {
  if (a.length != b.length) return false;
  if (!b.length) return true;
  return faststreq_samelen_nonz(a, b);
}

int[int] accesses;

char takech(ref string s, char deflt) {
  if (!s.length) return deflt;
  else {
    auto res = s[0];
    s = s[1 .. $];
    return res;
  }
}

import tools.base, errors;
struct StatCache {
  tools.base.Stuple!(Object, char*, int)[char*] cache;
  int depth;
  tools.base.Stuple!(Object, char*)* opIn_r(char* p) {
    auto res = p in cache;
    if (!res) return null;
    auto delta = depth - res._2;
    if (!(delta in accesses)) accesses[delta] = 0;
    accesses[delta] ++;
    return cast(tools.base.Stuple!(Object, char*)*) res;
  }
  void opIndexAssign(tools.base.Stuple!(Object, char*) thing, char* idx) {
    cache[idx] = stuple(thing._0, thing._1, depth++);
  }
}

struct SpeedCache {
  tools.base.Stuple!(char*, Object, char*)[24] cache;
  int curPos;
  tools.base.Stuple!(Object, char*)* opIn_r(char* p) {
    int i = curPos - 1;
    if (i == -1) i = cache.length - 1;
    while (i != curPos) {
      if (cache[i]._0 == p)
        return cast(tools.base.Stuple!(Object, char*)*) &cache[i]._1;
      if (--i < 0) i += cache.length;
    }
    return null;
  }
  void opIndexAssign(tools.base.Stuple!(Object, char*) thing, char* idx) {
    cache[curPos++] = stuple(idx, thing._0, thing._1);
    if (curPos == cache.length) curPos = 0;
  }
}

enum Scheme { Binary, Octal, Decimal, Hex }
bool gotInt(ref string text, out int i) {
  auto t2 = text.mystripl();
  t2.eatComments();
  if (auto rest = t2.startsWith("-")) {
    return gotInt(rest, i)
      && (
        i = -i,
        (text = rest),
        true
      );
  }
  ubyte ub;
  bool accept(ubyte from, ubyte to = 0xff) {
    if (!t2.length) return false;
    ubyte nub = t2[0];
    if (nub < from) return false;
    if (to != 0xff) { if (nub > to) return false; }
    else { if (nub > from) return false; }
    nub -= from;
    t2.take();
    ub = nub;
    return true;
  }
  
  int res;
  bool getDigits(Scheme scheme) {
    static int[4] factor = [2, 8, 10, 16];
    bool gotSomeDigits = false;
    outer:while (true) {
      // if it starts with _, it's an identifier
      while (gotSomeDigits && accept('_')) { }
      switch (scheme) {
        case Scheme.Hex:
          if (accept('a', 'f')) { ub += 10; break; }
          if (accept('A', 'F')) { ub += 10; break; }
        case Scheme.Decimal: if (accept('0', '9')) break;
        case Scheme.Octal:   if (accept('0', '7')) break;
        case Scheme.Binary:  if (accept('0', '1')) break;
        default: break outer;
      }
      gotSomeDigits = true;
      assert(ub < factor[scheme]);
      long nres = cast(long) res * cast(long) factor[scheme] + cast(long) ub;
      if (cast(int) nres != nres && cast(uint) nres != nres) {
        text.setError("Number too large for 32-bit integer representation");
        return false;
      } 
      res = cast(int) nres;
    }
    return gotSomeDigits;
  }

  if (accept('0')) {
    if (accept('b') || accept('B')) {
      if (!getDigits(Scheme.Binary)) return false;
    } else if (accept('x') || accept('X')) {
      if (!getDigits(Scheme.Hex)) return false;
    } else {
      if (!getDigits(Scheme.Octal)) res = 0;
    }
  } else {
    if (!getDigits(Scheme.Decimal)) return false;
  }
  i = res;
  text = t2;
  return true;
}

import tools.compat: replace;
import tools.base: Stuple, stuple;

string matchOneOf(dstring list, string var) {
  string res;
  foreach (dchar d; list) {
    if (res.length) res ~= " || ";
    string myu; myu ~= d;
    res ~= "("~var~" == '"~myu~"')";
  }
  return res;
}

// TODO: unicode
bool isNormal(dchar c) {
  return (c >= 'a' && c <= 'z') ||
         (c >= 'A' && c <= 'Z') ||
         (c >= '0' && c <= '9') ||
         mixin(matchOneOf("_" "αβγδεζηθικλμνξοπρσςτυφχψωΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ" "µð", "c"));
}

string lastAccepted, lastAccepted_stripped;
template acceptT(bool USECACHE) {
  // pragma(attribute, optimize("-O3"))
  bool acceptT(ref string s, string t) {
    string s2;
    debug if (t !is t.strip()) {
      logln("bad t: '", t, "'");
      fail;
    }
    static if (USECACHE) {
      if (s.ptr == lastAccepted.ptr && s.length == lastAccepted.length) {
        s2 = lastAccepted_stripped;
      } else {
        s2 = s.mystripl();
        s2.eatComments();
        lastAccepted = s;
        lastAccepted_stripped = s2;
      }
    } else {
      s2 = s.mystripl();
      s2.eatComments();
    }
    
    size_t idx = t.length, zero = 0;
    if (!s2.startsWith(t)) return false;
    if (isNormal(t.decode(zero)) && s2.length > t.length && isNormal(s2.decode(idx))) {
      return false;
    }
    s = s2[t.length .. $];
    if (!(t.length && t[$-1] == ' ') || !s.length) return true;
    if (s[0] != ' ') return false;
    s = s[1 .. $];
    return true;
  }
}

alias acceptT!(true)/*.acceptT*/ accept;
alias acceptT!(false)/*.acceptT*/ accept_mt;

bool hadABracket(string s) {
  auto s2 = (s.ptr - 1)[0..s.length + 1];
  if (s2.accept("}")) return true;
  return false;
}

// statement terminator.
// multiple semicolons can be substituted with a single one
// and "}" counts as "};"
bool acceptTerminatorSoft(ref string s) {
  if (!s.ptr) return true; // yeagh. Just assume it worked and leave me alone.
  if (s.accept(";")) return true;
  auto s2 = (s.ptr - 1)[0..s.length + 1];
  if (s2.accept(";") || s2.accept("}")) return true;
  return false;
}

bool mustAcceptTerminatorSoft(ref string s, lazy string err) {
  string s2 = s;
  if (!acceptTerminatorSoft(s2)) s.failparse(err());
  s = s2;
  return true;
}

bool mustAccept(ref string s, string t, lazy string err) {
  if (s.accept(t)) return true;
  s.failparse(err());
}

bool bjoin(ref string s, lazy bool c1, lazy bool c2, void delegate() dg,
           bool allowEmpty = true) {
  auto s2 = s;
  if (!c1) { s = s2; return allowEmpty; }
  dg();
  while (true) {
    s2 = s;
    if (!c2) { s = s2; return true; }
    s2 = s;
    if (!c1) { s = s2; return false; }
    dg();
  }
}

// while expr
bool many(ref string s, lazy bool b, void delegate() dg = null, string abort = null) {
  while (true) {
    auto s2 = s, s3 = s2;
    if (abort && s3.accept(abort)
        ||
        !b()
    ) {
      s = s2;
      break;
    }
    if (dg) dg();
  }
  return true;
}

import std.utf;
bool gotIdentifier(ref string text, out string ident, bool acceptDots = false, bool acceptNumbers = false) {
  auto t2 = text.mystripl();
  t2.eatComments();
  bool isValid(dchar d, bool first = false) {
    return isNormal(d) || (!first && d == '-') || (acceptDots && d == '.');
  }
  // array length special handling
  if (t2.length && t2[0] == '$') { text = t2; ident = "$"; return true; }
  if (!acceptNumbers && t2.length && t2[0] >= '0' && t2[0] <= '9') { return false; /* identifiers must not start with numbers */ }
  size_t idx = 0;
  if (!t2.length || !isValid(t2.decode(idx), true)) return false;
  size_t prev_idx = 0;
  dchar cur;
  do {
    prev_idx = idx;
    if (idx == t2.length) break;
    cur = t2.decode(idx);
  } while (isValid(cur));
  // prev_idx now is the start of the first invalid character
  /*if (ident in reserved) {
    // logln("reject ", ident);
    return false;
  }*/
  ident = t2[0 .. prev_idx];
  text = t2[prev_idx .. $];
  return true;
}

bool[string] reserved;
static this() {
  reserved["auto"] = true;
  reserved["return"] = true;
  reserved["function"] = true;
  reserved["delegate"] = true;
  reserved["type-of"] = true;
  reserved["string-of"] = true;
}

// This isn't a symbol! Maybe I was wrong about the dash .. 
// Remove the last dash part from "id" that was taken from "text"
// and re-add it to "text" via dark pointer magic.
bool eatDash(ref string text, ref string id) {
  auto dp = id.rfind("-");
  if (dp == -1) return false;
  auto removed = id.length - dp;
  id = id[0 .. dp];
  // give back
  text = (text.ptr - removed)[0 .. text.length + removed];
  return true;
}

// see above
bool eatDot(ref string text, ref string id) {
  auto dp = id.rfind(".");
  if (dp == -1) return false;
  auto removed = id.length - dp;
  id = id[0 .. dp];
  // give back also
  text = (text.ptr - removed)[0 .. text.length + removed];
  return true;
}

bool ckbranch(ref string s, bool delegate()[] dgs...) {
  auto s2 = s;
  foreach (dg; dgs) {
    if (dg()) return true;
    s = s2;
  }
  return false;
}

bool verboseParser = false;

string[bool delegate(string)] condInfo;

alias Tuple!(string, bool delegate(string), ubyte, bool)
  RuleData;

const RULEPTR_SIZE_HAX = (Stuple!(int, RuleData)).sizeof;
void[RULEPTR_SIZE_HAX][] slab;
int slab_freeptr = -1, slab_top;

struct RuleStruct(alias A) {
  Stuple!(RuleData) tuple;
  bool fun(Params!(typeof(&A))[1 .. $] rest) {
    return A(&tuple, rest);
  }
}

template allocRuleData(alias A) {
  bool delegate(Params!(typeof(&A))[1 .. $])
  allocRuleData(RuleData rd, ref int id) {
    void* res;
    if (slab_freeptr != -1) {
      auto ptr = slab[slab_freeptr].ptr;
      *cast(int*) ptr = id;
      res = ptr + 4;
      
      id = slab_freeptr;
      slab_freeptr = *cast(int*) res;
    } else {
      if (!slab) slab = new void[RULEPTR_SIZE_HAX][65536];
      if (slab_top >= slab.length) slab.length = slab.length * 2;
      
      auto ptr = slab[slab_top].ptr;
      *cast(int*) ptr = id;
      res = ptr + 4;
      
      id = slab_top++;
    }
    auto strp = cast(RuleStruct!(A)*) res;
    strp.tuple = stuple(rd);
    return &strp.fun;
  }
}

Object ardlock;
static this() { New(ardlock); }

void freeRuleData(int offs) {
  const string SRC = `
    auto ptr = slab[offs].ptr;
    auto data = ptr + 4;
    *cast(int*) data = slab_freeptr;
    slab_freeptr = offs;
    auto prevId = *cast(int*) ptr;
    if (prevId != -1) freeRuleData(prevId);
  `;
  // logln("free ", offs);
  version(MT) {
    synchronized(ardlock) { mixin(SRC); }
  } else {
    mixin(SRC);
  }
}

bool sectionStartsWith(string section, string rule) {
  if (section.length == rule.length && section.faststreq_samelen_nonz(rule)) return true;
  if (section.length < rule.length) return false;
  if (!section[0..rule.length].faststreq_samelen_nonz(rule)) return false;
  if (section.length == rule.length) return true;
  // only count hits that match a complete section
  return section[rule.length] == '.';
}

string matchrule_static(string rules) {
  // string res = "false /apply/ delegate bool(ref bool hit, string text) {";
  string res;
  int i;
  int falses;
  string preparams;
  while (rules.length) {
    string passlabel = "pass"~ctToString(i);
    string flagname  = "flag"~ctToString(i);
    i++;
    auto rule = ctSlice(rules, " ");
    auto first = rule[0], rest = rule[1 .. $];
    bool smaller, greater, equal, before, after, after_incl;
    switch (first) {
      case '<': smaller = true; rule = rest; break;
      case '>': greater = true; rule = rest; break;
      case '=': equal = true; rule = rest; break;
      case '^': before = true; preparams ~= "bool "~flagname~", "; falses ++; rule = rest; break;
      case '_': after = true; preparams ~= "bool "~flagname~", "; falses ++; rule = rest; break;
      case ',': after_incl = true; preparams ~= "bool "~flagname~", "; falses ++; rule = rest; break;
      default: break;
    }
    if (!smaller && !greater && !equal && !before && !after && !after_incl)
      smaller = equal = true; // default (see below)
    if (smaller) res ~= "if (text.sectionStartsWith(\""~rule~"\")) goto "~passlabel~";\n";
    if (equal)   res ~= "if (text == \""~rule~"\") goto "~passlabel~";\n";
    if (greater) res ~= "if (!text.sectionStartsWith(\""~rule~"\")) goto "~passlabel~";\n";
    if (before)  res ~= "if (text.sectionStartsWith(\""~rule~"\")) hit = true; if (!hit) goto "~passlabel~";\n";
    if (after)   res ~= "if (text.sectionStartsWith(\""~rule~"\")) hit = true; else if (hit) goto "~passlabel~";\n";
    if (after_incl)res~="if (text.sectionStartsWith(\""~rule~"\")) hit = true; if (hit) goto "~passlabel~";\n";
    res ~= "return false; "~passlabel~": \n";
  }
  string falsestr;
  if (falses == 1) falsestr = "false /apply/ ";
  else if (falses > 1) {
    falsestr = "false";
    for (int k = 1; k < falses; ++k) falsestr ~= ", false";
    falsestr = "stuple("~falsestr~") /apply/ ";
  }
  return falsestr ~ "delegate bool("~preparams~"string text) { \n" ~ res ~ "return true; \n}";
}

// cases: smaller, greater, equal, before, after
version(Windows) { } else pragma(set_attribute, fun, optimize("-O3"));
bool fun(Stuple!(RuleData)* data, string text) {
  auto op1 = data._1;
  if (op1 && !op1(text)) return false;
  // avoid allocation from ~"."
  auto rule = data._0, cases = data._2;
  if ((cases&4) && text == rule)
    return true;
  
  bool startswith = text.sectionStartsWith(rule);
  if ((cases&1) && startswith) // all "below" in the tree
    return true;
  if ((cases&2) && !startswith) // arguable
    return true;
  
  auto hit = &data._3;
  if (cases&8) {
    if (startswith)
      *hit = true;
    return !*hit;
  }
  if (cases&16) {
    if (startswith)
      *hit = true;
    else return *hit;
  }
  if (cases&32) {
    if (startswith)
      *hit = true;
    return *hit;
  }
  return false;
}

bool delegate(string) matchrule(string rules, ref int id) {
  bool delegate(string) res;
  auto rules_backup = rules;
  while (rules.length) {
    auto rule = rules.slice(" ");
    bool smaller, greater, equal, before, after, after_incl;
    assert(rule.length);
  restartRule:
    auto first = rule[0], rest = rule[1 .. $];
    switch (first) {
      case '<': smaller = true; rule = rest; goto restartRule;
      case '>': greater = true; rule = rest; goto restartRule;
      case '=': equal = true; rule = rest; goto restartRule;
      case '^': before = true; rule = rest; goto restartRule;
      case '_': after = true; rule = rest; goto restartRule;
      case ',': after_incl = true; rule = rest; goto restartRule;
      default: break;
    }
    
    if (!smaller && !greater && !equal && !before && !after && !after_incl)
      smaller = equal = true; // default
    // different modes
    assert((smaller || greater || equal) ^ before ^ after ^ after_incl);
    
    alias allocRuleData!(fun) ard;
    const string src = `
      res = ard(
        rule, res,
        (smaller<<0) | (greater<<1) | (equal<<2) | (before<<3) | (after<<4) | (after_incl<<5),
        false, id
      );
    `;
    version (MT) {
      synchronized(ardlock) {
        mixin(src);
      }
    } else {
      mixin(src);
    }
    // logln("allocate ", id);
  }
  return res;
}

struct ParseCtl {
  int state;
  string reason;
  const ParseCtl AcceptAbort = {0}, RejectAbort = {1}, AcceptCont = {2};
  static ParseCtl RejectCont(string reason) {
    ParseCtl res;
    res.state = 3;
    res.reason = reason;
    return res;
  }
  string decode() {
    switch (state) {
      case 0: return "AcceptAbort";
      case 1: return "RejectAbort";
      case 2: return "AcceptCont";
      case 3: return "RejectCont:"~reason;
    }
  }
}

import tools.functional;
struct ParseCb {
  Object delegate(ref string text,
    bool delegate(string),
    ParseCtl delegate(Object) accept
  ) dg;
  bool delegate(string) cur;
  Object opCall(T...)(ref string text, T t) {
    bool delegate(string) matchdg;
    int delid = -1;
    
    scope(exit)
      if (delid != -1)
        freeRuleData (delid);
    
    static if (T.length && is(T[0]: char[])) {
      alias T[1..$] Rest1;
      matchdg = matchrule(t[0], delid);
      auto rest1 = t[1..$];
    } else static if (T.length && is(T[0] == bool delegate(string))) {
      alias T[1..$] Rest1;
      matchdg = t[1];
      auto rest1 = t[1..$];
    } else {
      matchdg = cur;
      alias T Rest1;
      alias t rest1;
    }
    
    static if (Rest1.length && is(typeof(rest1[$-1](null))) && !is(Ret!(Rest1[$-1]) == void)) {
      static assert(is(typeof(rest1[$-1](null)) == bool) || is(typeof(rest1[$-1](null)) == ParseCtl),
        "Bad accept return type: "~typeof(rest1[$-1](null)).stringof);
      static assert(is(typeof(cast(Params!(Rest1[$-1])[0]) new Object)), "Bad accept params: "~Params!(Rest1[$-1]).stringof);
      alias Params!(Rest1[$-1])[0] MustType;
      alias Rest1[0 .. $-1] Rest2;
      auto accept = rest1[$-1];
      auto rest2 = rest1[0 .. $-1];
      static if (Rest2.length == 1 && is(typeof(*rest2[0])))
        static assert(is(Params!(Rest1[$-1]) == Tuple!(typeof(*rest2[0]))), "ParseCb mismatch: "~Params!(Rest1[$-1]).stringof~" != "~Tuple!(typeof(*rest2[0])).stringof);
    } else {
      bool delegate(Object) accept;
      alias Rest1 Rest2;
      alias rest1 rest2;
    }
    
    static if (Rest2.length == 1 && is(typeof(*rest2[0])) && !is(MustType))
      alias typeof(*rest2[0]) MustType;
    static if (Rest2.length == 1 && is(Rest2[0] == delegate)) {
      alias Params!(Rest2[0])[0] MustType;
      auto callback = rest2[0];
    }
    auto myAccept = delegate ParseCtl(Object obj) {
      static if (is(MustType)) {
        auto casted = fastcast!(MustType) (obj);
      } else {
        auto casted = obj;
      }
      if (!casted) {
        // logln("Reject ", obj, "; doesn't match ", typeof(casted).stringof, ".");
        return ParseCtl.RejectCont(null/*Format(obj, " doesn't match ", typeof(casted).stringof)*/);
      }
      static if (is(typeof(accept(casted)) == bool)) {
        return (!accept || accept(casted))?ParseCtl.AcceptAbort:ParseCtl.RejectCont(Format("accept dg to bool returned false"));
      }
      static if (is(typeof(accept(casted)) == ParseCtl)) {
        return accept?accept(casted):ParseCtl.AcceptAbort;
      }
      return ParseCtl.AcceptAbort;
    };
    
    static if (Rest2.length == 1 && is(typeof(*rest2[0])) || is(typeof(callback))) {
      // only accept-test objects that match the type
      auto backup = text;
      static if (is(typeof(callback))) {
        auto res = fastcast!(MustType) (dg(text, matchdg, myAccept));
        if (delid != -1) {
          freeRuleData (delid);
          delid = -1;
        }
        if (!res) text = backup;
        else callback(res);
        return fastcast!(Object) (res);
      } else {
        *rest2[0] = fastcast!(typeof(*rest2[0])) (dg(text, matchdg, myAccept));
        if (!*rest2[0]) text = backup;
        return fastcast!(Object) (*rest2[0]);
      }
    } else {
      static assert(!Rest2.length, "Left: "~Rest2.stringof~" of "~T.stringof);
      return dg(text, matchdg, myAccept);
    }
  }
}

// used to be class, flattened for speed
struct Parser {
  string key, id;
  Object delegate
    (ref string text, 
     ParseCtl delegate(Object) accept,
     ParseCb cont,
     ParseCb rest) match;
}

// stuff that it's unsafe to memoize due to side effects
bool delegate(string)[] globalStateMatchers;

void delegate()[] _pushCache, _popCache;

void delegate() pushCache() {
  foreach (dg; _pushCache) dg();
  return _popCache /apply/ delegate void(void delegate()[] dgs) {
    foreach (dg; dgs) dg();
  };
}

struct Stack(T) {
  const StaticSize = 4;
  T[StaticSize] static_backing_array;
  T[] backing_array;
  int curDepth;
  void push(ref T t) {
    scope(success) curDepth ++;
    
    int cd = curDepth;
    if (cd < StaticSize) {
      static_backing_array[cd] = t;
      return;
    }
    
    cd -= StaticSize;
    
    if (!backing_array.length) backing_array.length = 1;
    
    if (cd == backing_array.length)
      backing_array.length = backing_array.length * 2;
    
    backing_array[cd] = t;
  }
  void pop(ref T t) {
    curDepth --;
    if (curDepth < 0) fail;
    
    int cd = curDepth;
    if (cd < StaticSize) {
      t = static_backing_array[cd];
      return;
    }
    
    cd -= StaticSize;
    
    t = backing_array[cd];
  }
}

bool[string] unreserved;
static this() {
  unreserved["enum"] = true;
  unreserved["sum"] = true;
  unreserved["prefix"] = true;
  unreserved["suffix"] = true;
  unreserved["vec"] = true;
  unreserved["context"] = true;
  unreserved["do"] = true;
}

void reserve(string key) {
  if (key in unreserved) return;
  reserved[key] = true;
}

template DefaultParserImpl(alias Fn, string Id, bool Memoize, string Key) {
  final class DefaultParserImpl {
    Object info;
    bool dontMemoMe;
    static this() {
      static if (Key) reserve(Key);
    }
    final void push() {
      stack.push(cache);
      cache = Init!(typeof(cache));
    }
    final void pop() {
      stack.pop(cache);
    }
    this(Object obj = null) {
      info = obj;
      foreach (dg; globalStateMatchers)
        if (dg(Id)) { dontMemoMe = true; break; }
      
      _pushCache ~= &push;
      _popCache ~= &pop;
    }
    Parser genParser() {
      Parser res;
      res.key = Key;
      res.id = Id;
      res.match = &match;
      return res;
    }
    Object fnredir(ref string text, ParseCtl delegate(Object) accept, ParseCb cont, ParseCb rest) {
      static if (is(typeof((&Fn)(info, text, accept, cont, rest))))
        return Fn(info, text, accept, cont, rest);
      else static if (is(typeof((&Fn)(info, text, cont, rest))))
        return Fn(info, text, cont, rest);
      else static if (is(typeof((&Fn)(text, accept, cont, rest))))
        return Fn(text, accept, cont, rest);
      else
        return Fn(text, cont, rest);
    }
    static if (!Memoize) {
      Object match(ref string text, ParseCtl delegate(Object) accept, ParseCb cont, ParseCb rest) {
        return fnredir(text, accept, cont, rest);
      }
    } else {
      // Stuple!(Object, char*)[char*] cache;
      SpeedCache cache;
      Stack!(typeof(cache)) stack;
      Object match(ref string text, ParseCtl delegate(Object) accept, ParseCb cont, ParseCb rest) {
        auto t2 = text;
        if (.accept(t2, "]")) return null; // never a valid start
        bool acceptRelevant;
        static if (is(typeof((&Fn)(t2, accept, cont, rest))))
          acceptRelevant = true;
        acceptRelevant &= !!accept;
        if (acceptRelevant || dontMemoMe) {
          static if (Key) if (!.accept(t2, Key)) return null;
          auto res = fnredir(t2, accept, cont, rest);
          if (res) text = t2;
          return res;
        }
        auto ptr = t2.ptr;
        if (auto p = ptr in cache) {
          if (!p._1) text = null;
          else text = p._1[0 .. t2.ptr + t2.length - p._1];
          return p._0;
        }
        static if (Key) if (!.accept(t2, Key)) return null;
        auto res = fnredir(t2, accept, cont, rest);
        cache[ptr] = stuple(res, t2.ptr);
        if (res) text = t2;
        return res;
      }
    }
  }
}

import tools.threads, tools.compat: rfind;
static this() { New(sync); }

template DefaultParser(alias Fn, string Id, string Prec = null, string Key = null, bool Memoize = true) {
  static this() {
    static if (Prec) addParser((new DefaultParserImpl!(Fn, Id, Memoize, Key)).genParser(), Prec);
    else addParser((new DefaultParserImpl!(Fn, Id, Memoize, Key)).genParser());
  }
}

import tools.log;
struct SplitIter(T) {
  T data, sep;
  T front, frontIncl, all;
  T pop() {
    for (int i = 0; i <= cast(int) data.length - cast(int) sep.length; ++i) {
      if (data[i .. i + sep.length] == sep) {
        auto res = data[0 .. i];
        data = data[i + sep.length .. $];
        front = all[0 .. $ - data.length - sep.length - res.length];
        frontIncl = all[0 .. front.length + res.length];
        return res;
      }
    }
    auto res = data;
    data = null;
    front = null;
    frontIncl = all;
    return res;
  }
}

SplitIter!(T) splitIter(T)(T d, T s) {
  SplitIter!(T) res;
  res.data = d; res.sep = s;
  res.all = res.data;
  return res;
}

void delegate(string) justAcceptedCallback;

int[string] idepth;

Parser[] parsers;
string[string] prec; // precedence mapping
Object sync;

void addPrecedence(string id, string val) { synchronized(sync) { prec[id] = val; } }

string lookupPrecedence(string id) {
  synchronized(sync)
    if (auto p = id in prec) return *p;
  return null;
}

import tools.compat: split, join;
string dumpInfo() {
  if (listModified) resort;
  string res;
  int maxlen;
  foreach (parser; parsers) {
    auto id = parser.id;
    if (id.length > maxlen) maxlen = id.length;
  }
  auto reserved = maxlen + 2;
  string[] prevId;
  foreach (parser; parsers) {
    auto id = parser.id;
    auto n = id.dup.split(".");
    foreach (i, str; n[0 .. min(n.length, prevId.length)]) {
      if (str == prevId[i]) foreach (ref ch; str) ch = ' ';
    }
    prevId = id.split(".");
    res ~= n.join(".");
    if (auto p = id in prec) {
      for (int i = 0; i < reserved - id.length; ++i)
        res ~= " ";
      res ~= ":" ~ *p;;
    }
    res ~= "\n";
  }
  return res;
}

bool idSmaller(Parser pa, Parser pb) {
  auto a = splitIter(pa.id, "."), b = splitIter(pb.id, ".");
  string ap, bp;
  while (true) {
    ap = a.pop(); bp = b.pop();
    if (!ap && !bp) return false; // equal
    if (ap && !bp) return true; // longer before shorter
    if (bp && !ap) return false;
    if (ap == bp) continue; // no information here
    auto aprec = lookupPrecedence(a.frontIncl), bprec = lookupPrecedence(b.frontIncl);
    if (!aprec && bprec)
      throw new Exception("Patterns "~a.frontIncl~" vs. "~b.frontIncl~": first is missing precedence info! ");
    if (!bprec && aprec)
      throw new Exception("Patterns "~a.frontIncl~" vs. "~b.frontIncl~": second is missing precedence info! ");
    if (!aprec && !bprec) return ap < bp; // lol
    if (aprec == bprec) throw new Exception("Error: patterns '"~a.frontIncl~"' and '"~b.frontIncl~"' have the same precedence! ");
    for (int i = 0; i < min(aprec.length, bprec.length); ++i) {
      // precedence needs to be _inverted_, ie. lower-precedence rules must come first
      // this is because "higher-precedence" means it binds tighter.
      // if (aprec[i] > bprec[i]) return true;
      // if (aprec[i] < bprec[i]) return false;
      if (aprec[i] < bprec[i]) return true;
      if (aprec[i] > bprec[i]) return false;
    }
    bool flip;
    // this gets a bit hairy
    // 50 before 5, 509 before 5, but 51 after 5.
    if (aprec.length < bprec.length) { swap(aprec, bprec); flip = true; }
    if (aprec[bprec.length] != '0') return flip;
    return !flip;
  }
}

bool listModified;
void addParser(Parser p) {
  parsers ~= p;
  listModified = true;
}

void addParser(Parser p, string pred) {
  addParser(p);
  addPrecedence(p.id, pred);
}

import quicksort: qsort_ = qsort;
import tools.time: sec, µsec;
void resort() {
  parsers.qsort_(&idSmaller);
  listModified = false;
}

// manually inline because gdc is a poopyhead
const string parsecall = `
  if (verboseParser) return _parse!(true).parse(%);
  else return _parse!(false).parse(%);
`;

Object parse(ref string text, bool delegate(string) cond,
    int offs = 0, ParseCtl delegate(Object) accept = null)
{
  mixin(parsecall.ctReplace("%", "text, cond, offs, accept"));
}

template _parse(bool Verbose) {
  Object parse(ref string text, bool delegate(string) cond,
      int offs = 0, ParseCtl delegate(Object) accept = null) {
    if (!text.length) return null;
    if (listModified) resort;
    bool matched;
    static if (Verbose)
      logln("BEGIN PARSE '", text.nextText(16), "'");
    
    ubyte[RULEPTR_SIZE_HAX] cond_copy = void;
    ParseCb cont = void, rest = void;
    cont.dg = null; // needed for null check further in
    int i = void;
    Object cont_dg(ref string text, bool delegate(string) cond, ParseCtl delegate(Object) accept) {
      // return .parse(text, cond, offs + i + 1, accept);
      mixin(parsecall.ctReplace("%", "text, cond, offs + i + 1, accept"));
    }
    Object rest_dg(ref string text, bool delegate(string) cond, ParseCtl delegate(Object) accept) {
      // return .parse(text, cond, accept);
      mixin(parsecall.ctReplace("%", "text, cond, 0, accept"));
    }
    
    Object longestMatchRes;
    string longestMatchStr = text;
    const ProfileMode = false;
    static if (ProfileMode) {
      auto start_time = µsec();
      auto start_text = text;
      static float min_speed = float.infinity;
      scope(exit) if (text.ptr !is start_text.ptr) {
        auto delta = (µsec() - start_time) / 1000f;
        auto speed = (text.ptr - start_text.ptr) / delta;
        if (speed < min_speed) {
          min_speed = speed;
          if (delta > 5) {
            logln("New worst slowdown: '",
              condStr, "' at '", start_text.nextText(), "'"
              ": ", speed, " characters/ms "
              "(", (text.ptr - start_text.ptr), " in ", delta, "ms). ");
          }
        }
        // min_speed *= 1.01;
      }
    }
    auto tx = text;
    tx = tx.mystripl();
    tx.eatComments();
    bool tried;
    foreach (j, ref parser; parsers[offs..$]) {
      i = j;
      
      auto id = parser.id;
      
      // auto tx = text;
      // skip early. accept is slightly faster than cond.
      // if (parser.key && !.accept(tx, parser.key)) continue;
      if (parser.key && !tx.startsWith(parser.key)) continue;
      
      // rulestack ~= stuple(id, text);
      // scope(exit) rulestack = rulestack[0 .. $-1];
      
      if (cond(id)) {
        static if (Verbose) {
          if (!(id in idepth)) idepth[id] = 0;
          idepth[id] ++;
          scope(exit) idepth[id] --;
          logln("TRY PARSER [", idepth[id], " ", id, "] for '", text.nextText(16), "'");
        }
        
        matched = true;
        
        if (!cont.dg) {
          cond_copy[] = (cast(ubyte*) cond.ptr)[0 .. RULEPTR_SIZE_HAX];
          cond.ptr = cond_copy.ptr;
          cont.dg = &cont_dg;
          cont.cur = cond;
          rest.dg = &rest_dg;
          rest.cur = cond;
        }
        
        auto backup = text;
        if (auto res = parser.match(text, accept, cont, rest)) {
          auto ctl = ParseCtl.AcceptAbort;
          if (accept) {
            ctl = accept(res);
            static if (Verbose) logln("    PARSER [", idepth[id], " ", id, "]: control flow ", ctl.decode);
            if (ctl == ParseCtl.RejectAbort || ctl.state == 3) {
              static if (Verbose) logln("    PARSER [", idepth[id], " ", id, "] rejected (", ctl.reason, "): ", Format(res));
              text = backup;
              if (ctl == ParseCtl.RejectAbort) return null;
              continue;
            }
          }
          static if (Verbose) logln("    PARSER [", idepth[id], " ", id, "] succeeded with ", res, ", left '", text.nextText(16), "'");
          if (ctl == ParseCtl.AcceptAbort) {
            if (justAcceptedCallback) justAcceptedCallback(text);
            return res;
          }
          if (text.ptr > longestMatchStr.ptr) {
            longestMatchStr = text;
            longestMatchRes = res;
          }
        } else {
          static if (Verbose) logln("    PARSER [", idepth[id], " ", id, "] failed");
        }
        text = backup;
      }
    }
    if (longestMatchRes) {
      text = longestMatchStr;
      if (justAcceptedCallback) justAcceptedCallback(text);
      return longestMatchRes;
    }
    return null;
  }
  version(Windows) { } else pragma(set_attribute, parse, optimize("-O3", "-fno-tree-vrp"));
}

string condStr;
Object parse(ref string text, string cond) {
  condStr = cond;
  scope(exit) condStr = null;
  
  int delid = -1;
  scope(exit)
    if (delid != -1)
      freeRuleData(delid);
  
  try mixin(parsecall.ctReplace("%", "text, matchrule(cond, delid)"));
  catch (ParseEx pe) { pe.addRule(cond); throw pe; }
  catch (Exception ex) throw new Exception(Format("Matching rule '"~cond~"': ", ex));
}

bool test(T)(T t) { if (t) return true; else return false; }

void noMoreHeredoc(string text) {
  if (text.accept("<<"))
    text.failparse("Please switch from heredoc to {}!");
}

string startsWith(string text, string match)
{
  if (text.length < match.length) return null;
  if (!match.length) return text;
  if (!text[0..match.length].faststreq_samelen_nonz(match)) return null;
  return text[match.length .. $];
}

string hex(ubyte u) {
  auto hs = "0123456789ABCDEF";
  return ""~hs[u>>8]~hs[u&0xf];
}

string cleanup(string s) {
  string res;
  foreach (b; cast(ubyte[]) s) {
    if (b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '_') {
      res ~= b;
    } else {
      res ~= "_"~hex(b)~"_";
    }
  }
  return res;
}

bool acceptLeftArrow(ref string text) {
  return text.accept("<-") || text.accept("←");
}
