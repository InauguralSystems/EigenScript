namespace EigenCore

inductive BinOp where
  | add | sub | mul | eq | ne | lt | le | gt | ge | and | or
  deriving Repr, BEq

inductive Literal where
  | int (value : Int)
  | string (value : String)
  | bool (value : Bool)
  | null
  deriving Repr, BEq

inductive Expr where
  | literal (value : Literal)
  | variable (name : String)
  | binary (op : BinOp) (left right : Expr)
  | not (value : Expr)
  | array (values : List Expr)
  | call (function : Expr) (arguments : List Expr)
  | when (name : String)
  | prev (name : String)
  | whatWhen (name : String) (ordinal : Expr)
  deriving Repr, BEq

inductive Stmt where
  | assign (name : String) (value : Expr) (isLocal : Bool)
  | print (value : Expr)
  | branch (condition : Expr) (thenBody : List Stmt)
      (elifs : List (Expr × List Stmt)) (elseBody : Option (List Stmt))
  | loop (condition : Expr) (body : List Stmt)
  | define (name : String) (parameters : List String) (body : List Stmt)
  | return_ (value : Expr)
  | expression (value : Expr)
  deriving Repr, BEq

abbrev Program := List Stmt
end EigenCore
