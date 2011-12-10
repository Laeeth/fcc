module ast.unary;

import ast.base, ast.casting, ast.opers, ast.assign, ast.literals, parseBase;

// definitely not an lvalue
class PrePostOpExpr(bool Post, bool Inc) : Expr {
  LValue lv;
  this(LValue lv) {
    this.lv = lv;
  }
  private this() { }
  mixin DefaultDup!();
  mixin defaultIterate!(lv);
  override {
    IType valueType() {
      return lv.valueType();
    }
    void emitAsm(AsmFile af) {
      auto op = lookupOp(Inc?"+":"-", lv, mkInt(1));
      Expr cv;
      if (lv.valueType() == op.valueType()) cv = op;
      else {
        cv = tryConvert(op, lv.valueType());
        if (!cv) throw new Exception(Format("PrePostOpExpr(", Inc?"+":"-", ") failed: cannot reconvert ", op.valueType(), " to ", lv.valueType()));
      }
      auto as = new Assignment(lv, cv);
      static if (Post) {
        lv.emitAsm(af);
        as.emitAsm(af);
      } else {
        as.emitAsm(af);
        lv.emitAsm(af);
      }
    }
  }
}

Object gotPostIncExpr(ref string text, ParseCb cont, ParseCb rest) {
  Expr op;
  auto t2 = text;
  if (!cont(t2, &op)) return null;
  if (t2.accept("++")) {
    auto lv = fastcast!(LValue)~ op;
    if (!lv) throw new Exception(Format("Can't post-increment ", op, ": not an lvalue"));
    text = t2;
    return new PrePostOpExpr!(true, true)(lv);
  } else if (t2.accept("--")) {
    auto lv = fastcast!(LValue)~ op;
    if (!lv) throw new Exception(Format("Can't post-decrement ", op, ": not an lvalue"));
    text = t2;
    return new PrePostOpExpr!(true, false)(lv);
  } else return null;
}
mixin DefaultParser!(gotPostIncExpr, "tree.expr.arith.postincdec", "25");

Object gotPreIncExpr(ref string text, ParseCb cont, ParseCb rest) {
  Expr op;
  auto t2 = text;
  
  if (t2.accept("++")) {
    if (!cont(t2, &op))
      t2.failparse("Can't find expression for pre-inc");
    auto lv = fastcast!(LValue)~ op;
    if (!lv) text.failparse("Can't pre-increment ", op, ": not an lvalue");
    text = t2;
    return new PrePostOpExpr!(false, true)(lv);
  } else if (t2.accept("--")) {
    if (!cont(t2, &op))
      t2.failparse("Can't find expression for pre-inc");
    auto lv = fastcast!(LValue)~ op;
    if (!lv) text.failparse("Can't pre-decrement ", op, ": not an lvalue");
    text = t2;
    return new PrePostOpExpr!(false, false)(lv);
  } else return null;
}
mixin DefaultParser!(gotPreIncExpr, "tree.expr.arith.preincdec", "26");
