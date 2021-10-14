module Canjica.EvalApply where

import qualified Canjica.Boolean               as Boolean
import qualified Canjica.Function              as Function
import           Canjica.Function               ( functionArguments
                                                , functionBody
                                                , functionEnvironment
                                                )
import qualified Canjica.Let                   as Let
import qualified Canjica.Number                as Number
import           Capability.Error        hiding ( (:.:) )
import           Capability.Reader       hiding ( (:.:) )
import           Capability.State        hiding ( (:.:) )
import           Data.IORef
import qualified Data.Map                      as Map
import           Pipoquinha.BuiltIn      hiding ( T )
import qualified Pipoquinha.Environment        as Environment
import           Pipoquinha.Environment         ( ReaderCapable
                                                , StateCapable
                                                , ThrowCapable
                                                )
import           Pipoquinha.Error               ( T(..) )
import           Pipoquinha.Parser             as Parser
import           Pipoquinha.SExp         hiding ( T )
import qualified Pipoquinha.SExp               as SExp
import qualified Pipoquinha.Type               as Type
import           Protolude               hiding ( MonadReader
                                                , ask
                                                , asks
                                                , get
                                                , gets
                                                , local
                                                , put
                                                , yield
                                                )
import           Text.Megaparsec                ( errorBundlePretty
                                                , parse
                                                )
throwIfError :: ThrowCapable m => SExp.Result a -> m a
throwIfError = \case
  Left  error -> throw @"runtimeError" error
  Right value -> return value

eval
  :: (ReaderCapable SExp.T m, ThrowCapable m, StateCapable SExp.T m)
  => SExp.T
  -> m SExp.T
eval atom = case atom of
  n@(Number   _) -> return n
  f@(Function _) -> return f
  m@(Macro    _) -> return m
  b@(Bool     _) -> return b
  e@(Error    _) -> return e
  s@(Str      _) -> return s
  b@(BuiltIn  _) -> return b
  Symbol name    -> do
    join (asks @"table" (Environment.getValue name)) >>= liftIO . readIORef
  Pair (List l ) -> apply l
  Pair (_ :.: _) -> throw @"runtimeError" $ CannotApply Type.Pair
  Pair _         -> return $ Pair Nil

batchEval
  :: (ReaderCapable SExp.T m, ThrowCapable m, StateCapable SExp.T m)
  => [SExp.T]
  -> m [SExp.T]
batchEval = traverse eval

apply
  :: (ReaderCapable SExp.T m, ThrowCapable m, StateCapable SExp.T m)
  => [SExp.T]
  -> m SExp.T

apply [] = return $ Pair Nil

{- Number operations -}

apply (BuiltIn Add : values) =
  batchEval values <&> foldM Number.add (Number 0) >>= throwIfError

apply (BuiltIn Mul : values) =
  batchEval values <&> foldM Number.mul (Number 1) >>= throwIfError

apply [BuiltIn Negate, atom] = eval atom >>= \case
  Number x -> return . Number . negate $ x
  value    -> throw @"runtimeError" TypeMismatch { expected = Type.Number
                                                 , found    = SExp.toType value
                                                 }
apply (BuiltIn Negate : arguments) =
  throw @"runtimeError" $ WrongNumberOfArguments { expectedCount = 1
                                                 , foundCount = length arguments
                                                 }

apply [BuiltIn Invert, atom] = eval atom >>= \case
  Number x -> return . Number $ denominator x % numerator x
  value    -> throw @"runtimeError" TypeMismatch { expected = Type.Number
                                                 , found    = SExp.toType value
                                                 }

apply (BuiltIn Invert : arguments) =
  throw @"runtimeError" $ WrongNumberOfArguments { expectedCount = 1
                                                 , foundCount = length arguments
                                                 }

apply [BuiltIn Numerator, atom] = eval atom >>= \case
  Number x -> return . Number $ numerator x % 1
  value    -> throw @"runtimeError" TypeMismatch { expected = Type.Number
                                                 , found    = SExp.toType value
                                                 }

apply (BuiltIn Numerator : arguments) =
  throw @"runtimeError" $ WrongNumberOfArguments { expectedCount = 1
                                                 , foundCount = length arguments
                                                 }

{- Boolean operations -}

apply [BuiltIn Not, value] = eval value >>= \case
  Bool False -> return . Bool $ True
  _          -> return . Bool $ False

apply (BuiltIn Not : arguments) =
  throw @"runtimeError" $ WrongNumberOfArguments { expectedCount = 1
                                                 , foundCount = length arguments
                                                 }

apply (BuiltIn And : values) =
  batchEval values <&> foldM Boolean.and (Bool True) >>= throwIfError

apply (BuiltIn Or : values) =
  batchEval values <&> foldM Boolean.or (Bool False) >>= throwIfError

{- Value definition operations -}

apply [BuiltIn Def, Symbol name, atom] = do
  evaluatedSExp <- eval atom
  environment   <- ask @"table"
  Environment.insertValue name evaluatedSExp
  return (Symbol name)

apply (BuiltIn Def : arguments) = throw @"runtimeError" $ MalformedDefinition

apply (BuiltIn Defn : Symbol name : rest) = do
  environment <- ask @"table"
  function    <- throwIfError $ Function.make environment rest
  Environment.insertValue name (Function function)
  return $ Symbol name

apply (BuiltIn Defn : arguments) = throw @"runtimeError" $ MalformedDefinition

apply [BuiltIn If, predicate, consequent, alternative] =
  eval predicate >>= \case
    Bool False -> eval alternative
    _          -> eval consequent

apply (BuiltIn If : arguments) = throw @"runtimeError" $ WrongNumberOfArguments
  { expectedCount = 3
  , foundCount    = length arguments
  }

apply (BuiltIn Print : rest) =
  batchEval rest >>= putStr . unwords . map show >> return (Pair Nil)

apply (BuiltIn Fn : rest) = do
  environment <- ask @"table"
  function    <- throwIfError $ Function.make environment rest
  return $ Function function

apply (BuiltIn Eql : rest) = batchEval rest >>= \case
  []            -> throw @"runtimeError" (WrongNumberOfArguments 1 0)
  (base : rest) -> return (Bool $ (== base) `all` rest)

apply [BuiltIn Loop, procedure] = forever (eval procedure)

apply (BuiltIn Loop : arguments) =
  throw @"runtimeError" $ WrongNumberOfArguments { expectedCount = 1
                                                 , foundCount = length arguments
                                                 }

apply [BuiltIn Read] = do
  input <- liftIO getLine
  return $ case parse Parser.sExpLine mempty input of
    Left  e -> Error . ParserError . toS . errorBundlePretty $ e
    Right a -> a

apply (BuiltIn Read : arguments) =
  throw @"runtimeError" $ WrongNumberOfArguments { expectedCount = 0
                                                 , foundCount = length arguments
                                                 }

apply [BuiltIn Eval, value] = eval >=> eval $ value

apply (BuiltIn Eval : arguments) =
  throw @"runtimeError" $ WrongNumberOfArguments { expectedCount = 1
                                                 , foundCount = length arguments
                                                 }

apply [BuiltIn Quote, atom] = return atom

apply (BuiltIn Quote : arguments) =
  throw @"runtimeError" $ WrongNumberOfArguments { expectedCount = 1
                                                 , foundCount = length arguments
                                                 }


apply (BuiltIn Do : rest)      = foldM (const eval) (Pair Nil) rest

apply [BuiltIn Cons, car, cdr] = do
  car <- eval car
  cdr <- eval cdr
  return $ Pair (car :.: cdr)

apply (BuiltIn Cons : arguments) =
  throw @"runtimeError" $ WrongNumberOfArguments { expectedCount = 2
                                                 , foundCount = length arguments
                                                 }
apply [BuiltIn Car, atom] = eval atom >>= \case
  Pair Nil       -> return $ Pair Nil
  Pair (x ::: _) -> return x
  Pair (x :.: _) -> return x
  value -> throw @"runtimeError" TypeMismatch { expected = Type.Pair
                                              , found    = SExp.toType value
                                              }

apply (BuiltIn Car : arguments) =
  throw @"runtimeError" $ WrongNumberOfArguments { expectedCount = 1
                                                 , foundCount = length arguments
                                                 }

apply [BuiltIn Cdr, atom] = eval atom >>= \case
  Pair Nil        -> return $ Pair Nil
  Pair (_ ::: xs) -> return $ Pair xs
  Pair (_ :.: x ) -> return x
  value -> throw @"runtimeError" TypeMismatch { expected = Type.Pair
                                              , found    = SExp.toType value
                                              }

apply (BuiltIn Cdr : arguments) =
  throw @"runtimeError" $ WrongNumberOfArguments { expectedCount = 1
                                                 , foundCount = length arguments
                                                 }

apply [BuiltIn Set, Symbol name, atom] = do
  evaluatedSExp <- eval atom
  environment   <- ask @"table"
  Environment.setValue name evaluatedSExp environment
  return (Symbol name)

apply (BuiltIn Set : _)                     = throw @"runtimeError" MalformedSet

apply [BuiltIn Let, Pair (List exps), body] = do
  letTable           <- throwIfError $ Let.makeTable exps

  environment        <- ask @"table"

  evaluatedArguments <- mapM eval letTable

  newScope           <- liftIO . mapM newIORef $ evaluatedArguments

  environmentRef     <- liftIO . newIORef $ Environment.Table
    { variables = newScope
    , parent    = Just environment
    }

  local @"table" (const environmentRef) (eval body)

apply (BuiltIn Let : arguments) =
  throw @"runtimeError" $ WrongNumberOfArguments { expectedCount = 2
                                                 , foundCount = length arguments
                                                 }

apply (BuiltIn MakeList : list) = batchEval list <&> Pair . List

apply (s@(Symbol _)     : as  ) = do
  operator <- eval s
  apply (operator : as)

apply (Function fn : as) = do
  evaluated      <- batchEval as
  result         <- throwIfError $ Function.proceed fn evaluated
  newScope       <- liftIO . mapM newIORef $ functionArguments result

  environmentRef <- liftIO . newIORef $ Environment.Table
    { variables = newScope
    , parent    = Just $ functionEnvironment result
    }

  local @"table" (const environmentRef) (eval $ functionBody result)

apply (Macro _        : _ ) = throw @"runtimeError" NotImplementedYet

apply (Pair  (List l) : as) = do
  operator <- apply l
  apply (operator : as)

apply (Pair   (_ :.: _) : _) = throw @"runtimeError" $ CannotApply Type.Pair

apply (Pair   Nil       : _) = throw @"runtimeError" $ CannotApply Type.Pair

apply (Bool   _         : _) = throw @"runtimeError" $ CannotApply Type.Boolean

apply (Str    _         : _) = throw @"runtimeError" $ CannotApply Type.String

apply (Number _         : _) = throw @"runtimeError" $ CannotApply Type.Number

apply (e@(Error _)      : _) = return e
