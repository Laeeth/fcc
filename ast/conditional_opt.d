module ast.conditional_opt;

import ast.base, ast.conditionals, ast.index, ast.static_arrays, ast.fold;
import ast.int_literal;

static this() {
  foldopt ~= delegate Itr(Itr it) {
    auto ew = fastcast!(ExprWrap) (it);
    if (!ew) return null;
    auto ce = fastcast!(CondExpr) (ew.ex);
    if (!ce) return null;
    return ce.cd;
  };
  foldopt ~= delegate Itr(Itr it) {
    auto sie = fastcast!(SAIndexExpr) (it);
    if (!sie) return null;
    auto salit = fastcast!(SALiteralExpr) (sie.ex);
    if (!salit || salit.exs.length != 2) return null;
    if (salit.exs[0].valueType().size != 4 || salit.exs[1].valueType().size != 4)
      return null;
    auto ce = fastcast!(CondExpr) (sie.pos);
    if (!ce) return null;
    auto cmp = fastcast!(Compare) (ce.cd);
    if (!cmp) return null;
    // logln("salit ", salit.exs, " INDEX ", ce.cd);
    cmp = cmp.dup;
    cmp.falseOverride = salit.exs[0];
    cmp.trueOverride = salit.exs[1];
    return fastcast!(Itr) (cmp);
  };
  foldopt ~= delegate Itr(Itr it) {
    auto isAnd = fastcast!(AndOp) (it), isOr = fastcast!(OrOp) (it);
    if (!isAnd && !isOr) return null;
    setupStaticBoolLits();
    Cond c1, c2;
    if (isAnd) { c1 = isAnd.c1; c2 = isAnd.c2; }
    if (isOr)  { c1 = isOr.c1;  c2 = isOr.c2;  }
    c1 = fastcast!(Cond) (fold(c1));
    c2 = fastcast!(Cond) (fold(c2));
    if (isStaticTrue(c1)) {
      if (isStaticTrue(c2)) return cTrue;
      else if (isStaticFalse(c2)) return isAnd?cFalse:cTrue;
      else return null;
    } else if (isStaticFalse(c1)) {
      if (isStaticTrue(c2)) return isAnd?cFalse:cTrue;
      else if (isStaticFalse(c2)) return cFalse;
      else return null;
    } else return null;
  };
  foldopt ~= delegate Itr(Itr it) {
    auto cmp = fastcast!(Compare) (it);
    if (!cmp) return null;
    // logln("e1: ", cmp.e1);
    // logln("e2: ", cmp.e2);
    auto i1 = fastcast!(IntExpr) (cmp.e1);
    auto i2 = fastcast!(IntExpr) (cmp.e2);
    // logln("i1: ", i1);
    // logln("i2: ", i2);
    if (!i1 || !i2) return null;
    bool result;
    if (cmp.smaller && i1.num < i2.num) result = true;
    if (cmp.equal && i1.num == i2.num) result = true;
    if (cmp.greater && i1.num > i2.num) result = true;
    Expr res;
    if (result) {
      if (cmp.trueOverride) res = cmp.trueOverride;
      else res = True;
    } else {
      if (cmp.falseOverride) res = cmp.falseOverride;
      else res = False;
    }
    return new ExprWrap(res);
  };
}
