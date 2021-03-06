module errors;

import alloc, tools.base;

string mystripl(string s) {
  while (s.length && (
    s[0] == ' '  || s[0] == '\t' ||
    s[0] == '\n' || s[0] == '\r'
  )) {
    s = s[1 .. $];
  }
  return s;
}

string mystrip(string s) {
  while (s.length && (
    s[0] == ' '  || s[0] == '\t' ||
    s[0] == '\n' || s[0] == '\r'
  )) s = s[1 .. $];
  while (s.length && (
    s[$-1] == ' '  || s[$-1] == '\t' ||
    s[$-1] == '\n' || s[$-1] == '\r'
  )) s = s[0 .. $-1];
  return s;
}

string nextText(string s, int i = 100) {
  if (s.length > i) s = s[0 .. i];
  return s.replace("\n"[], "\\"[]);
}

// char* cache_marker, cache_res;

void eatComments(ref string s) {
  /// benched this, it doesn't help
  /*
  if (s.ptr is cache_marker) { s = cache_res[0..s.ptr+s.length-cache_res]; return; }
  if (s.ptr is cache_res) { return; }
  auto backupptr = s.ptr;
  scope(success) {
    cache_marker = backupptr;
    cache_res = s.ptr;
  }*/
  s = s.mystripl();
  while (true) {
    if (s.length >= 2 && s[0] == '/' && s[1] == '*') { s = s[2..$]; s.slice("*/"[]); s = s.mystripl(); }
    else if (s.length >= 2 && s[0] == '/' && s[1] == '+') {
      s = s[2..$];
      int depth = 1;
      while (depth) {
        auto a = s.find("/+"[]), b = s.find("+/"[]);
        if (b == -1)
          throw new Exception("Unbalanced comments! "[]);
        if (a != -1 && a < b) {
          depth++;
          s = s[a + 2 .. $];
          continue;
        }
        depth --;
        s = s[b + 2 .. $];
      }
      s = s.mystripl();
    }
    else if (s.length >= 2 && s[0] == '/' && s[1] == '/') { s = s[2..$]; s.slice("\n"[]); s = s.mystripl(); }
    else break;
  }
}

public import tools.threads: SyncObj;

string[string] sourcefiles;

// progress, file
Stuple!(float, string) lookupProgress(string text) {
  eatComments(text);
  text = text.strip();
  synchronized(SyncObj!(sourcefiles)) foreach (key, value; sourcefiles) {
    // yes, >. Not >=. Think about it.
    if (text.ptr < value.ptr || text.ptr > value.ptr + value.length)
      continue;
    return stuple((text.ptr - value.ptr) * 1f / value.length, key);
  }
  return stuple(0f, cast(string) null);
}

string[string] keymemo; // sigh..
// row, col, file
Stuple!(int, ptrdiff_t, string, string) lookupPos(string text) {
  eatComments(text);
  text = text.mystripl();
  synchronized(SyncObj!(sourcefiles)) foreach (key, value; sourcefiles) {
    if (text.ptr < value.ptr || text.ptr > value.ptr + value.length)
      continue;
    int i;
    while (value) {
      auto line = value.slice("\n"[]);
      if (text.ptr < line.ptr || text.ptr > line.ptr + line.length) {
        i++;
        continue;
      }
      if (auto p = key in keymemo) key = *p;
      else { key = key.dup; keymemo[key] = key; /* what .. */ }
      return stuple(i + 1, text.ptr - line.ptr, key, line);
    }
    assert(false);
  }
  return stuple(0, cast(ptrdiff_t) 0, "<unknown>"[], cast(string) null);
}

string reverseLookupPos(int row, int col, string file) {
  synchronized(SyncObj!(sourcefiles)) {
    auto text = sourcefiles[file];
    while (--row) text.slice("\n"[]);
    return text[col .. $];
  }
}

bool emulateGCCOutput = false; // for use in IDE plugins that expect "file:line:column errortext"

class ParseEx : Exception {
  string pos;
  string[] rules;
  this(string pos, string s) {
    // auto test = lookupPos(pos);
    // if (test._2 == "<unknown>") asm { int 3; }
    this.pos = pos; super(s);
  }
  void addRule(string s) { rules ~= s; }
  string toString() {
    auto info = lookupPos(pos);
    if (info._2 == "<unknown>") {
      info._2 = "@`"~pos.nextText()~"`";
    }
    string res;
    if (info._3 && !emulateGCCOutput) {
      auto prefix = "At line: ";
      res = Format("\n"[], prefix, info._3, "\n"[]);
      for (int i = 0; i < prefix.length + info._1; ++i)
        res ~= " ";
      res ~= "^\n";
    }
    
    res ~= Format(info._2, ":"[], info._0, ":"[], info._1, ": "[], msg);
    // this is not actually useful anymore
    // if (rules) res ~= Format(" "[], rules);
    if (emulateGCCOutput) {
      res = res.replace("\n", " "); // :(
      // there's probably a way elegant regex way but I cba
      while (res.find("  ") != -1) { res = res.replace("  ", " "); }
    }
    return res;
  } 
}

import tools.threads: TLS;
import tools.base: New;

// source, mesg
TLS!(Stuple!(string, string)) error;

void failparse(T...)(string text, T t) {
  auto str = Format(t);
  if (auto mesg = error()._1)
    if (!str.endsWith(mesg)) // don't double-add mesg
      str ~= ": "~mesg;
  throw fastalloc!(ParseEx)(text, str);
}

static this() { New(error); }

void setError(T...)(string text, T t) {
  *error.ptr() = stuple(text, Format(t));
}

void resetError() {
  *error.ptr() = stuple(cast(string) null, cast(string) null);
}

void passert(T...)(string text, bool b, T t) {
  if (!b) text.failparse(t);
}
