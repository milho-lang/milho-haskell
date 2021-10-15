module Pipoquinha.BuiltIn where

import           Protolude

data T
  = Add
  | Mul
  | Negate
  | Invert
  | Eql
  | Def
  | Defn
  | Defmacro
  | Fn
  | Let
  | If
  | Read
  | Eval
  | Print
  | Loop
  | Do
  | Not
  | And
  | Or
  | Cons
  | MakeList
  | Car
  | Cdr
  | Quote
  | Gt
  | Lt
  | Numerator
  | Set
  | Concat
  | Str
  | Split
  | Len
  | IsFunction
  | IsBool
  | IsError
  | IsSymbol
  | IsMacro
  | IsString
  | IsNumber
  | IsPair

  deriving (Eq, Show, Ord)
