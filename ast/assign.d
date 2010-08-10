module ast.assign;

import ast.base, ast.variable, ast.pointer;

class Assignment : Statement {
  LValue target;
  Expr value;
  bool blind;
  import tools.log;
  this(LValue t, Expr e, bool force = false, bool blind = false) {
    this.blind = blind;
    if (!force && t.valueType() != cast(Object) e.valueType()) {
      throw new Exception(Format(
        "Can't assign: ", t, " of ", t.valueType(), " <- ", e.valueType()
      ));
    }
    target = t;
    value = e;
  }
  mixin defaultIterate!(target, value);
  override string toString() { return Format(target, " := ", value, "; "); }
  override void emitAsm(AsmFile af) {
    if (blind) {
      value.emitAsm(af);
      target.emitLocation(af);
      af.popStack("%eax", new Pointer(target.valueType()));
      af.popStack("(%eax)", value.valueType());
    } else {
      mixin(mustOffset("0"));
      {
        mixin(mustOffset("value.valueType().size"));
        value.emitAsm(af);
      }
      {
        mixin(mustOffset("nativePtrSize"));
        target.emitLocation(af);
      }
      af.popStack("%eax", new Pointer(target.valueType()));
      af.popStack("(%eax)", value.valueType());
    }
  }
}

import tools.log;
Object gotAssignment(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  LValue target;
  Expr ex;
  if (rest(t2, "tree.expr >tree.expr.arith", &ex) && t2.accept("=")) {
    auto lv = cast(LValue) ex;
    if (!lv) throw new Exception(Format("Assignment target is not an lvalue: ", ex, " at ", t2.next_text()));
    target = lv;
    Expr value;
    if (rest(t2, "tree.expr", &value)) {
      // logln(target.valueType(), " <- ", value.valueType());
      if (target.valueType() != cast(Object) value.valueType()) {
        throw new Exception(Format("Mismatching types in assignment: ", target, " <- ", value.valueType()));
      }
      text = t2;
      return new Assignment(target, value);
    } else throw new Exception("While grabbing assignment value at '"~t2.next_text()~"'");
  } else return null;
}
mixin DefaultParser!(gotAssignment, "tree.semicol_stmt.assign");
