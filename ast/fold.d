module ast.fold;

import ast.base, tools.base: and;

Itr fold(Itr i) {
  if (!i) return null;
  auto cur = i;
  while (true) {
    auto start = cur;
    auto e1 = cast(Expr) start;
    foreach (dg; foldopt) {
      if (auto res = dg(cur)) cur = res;
      // logln("TEST ", (cast(Object) cur.valueType()).classinfo.name, " != ", (cast(Object) start.valueType()).classinfo.name, ": ", cur.valueType() != start.valueType());
      auto e2 = cast(Expr) cur;
      if (e1 && e2 && e1.valueType() != e2.valueType()) {
        throw new Exception(Format("Fold has violated type consistency: ", start, " => ", cur));
      }
    }
    if (cur is start) break;
  }
  return cur;
}

Expr foldex(Expr ex) {
  auto res = cast(Expr) fold(ex);
  assert(!ex || !!res, Format("folding ", ex, " resulted in ", res, "!"));
  return res;
}

Itr opt(Itr obj) {
  obj = obj.dup;
  void fun(ref Itr it) {
    it = fold(it);
    it.iterate(&fun);
  }
  fun(obj);
  return obj;
}

Expr optex(Expr ex) {
  auto res = cast(Expr) opt(ex);
  assert(!!res);
  return res;
}
