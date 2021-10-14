module Canjica.EvalApply where

import qualified Canjica.Function              as Function
import           Canjica.Number
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
import           Pipoquinha.Error               ( T
                                                  ( CannotApply
                                                  , NotImplementedYet
                                                  , ParserError
                                                  , TypeMismatch
                                                  , WrongNumberOfArguments
                                                  )
                                                )
import           Pipoquinha.Parser             as Parser
import           Pipoquinha.SExp         hiding ( T )
import qualified Pipoquinha.SExp               as SExp
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
  Pair (_ :.: _) -> throw @"runtimeError" CannotApply
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

apply []                 = return $ Pair Nil

apply (BuiltIn Add : as) = batchEval as
  >>= foldl (\acc current -> acc >>= add current) (return $ Number 0)

apply (BuiltIn Mul : as) = batchEval as
  >>= foldl (\acc current -> acc >>= mul current) (return $ Number 1)

apply [BuiltIn Negate, atom] = eval atom >>= \case
  Number x -> return . Number . negate $ x
  _        -> throw @"runtimeError" TypeMismatch

apply [BuiltIn Invert, atom] = eval atom >>= \case
  Number x -> return . Number $ denominator x % numerator x
  _        -> throw @"runtimeError" TypeMismatch

apply [BuiltIn Numerator, atom] = eval atom >>= \case
  Number x -> return . Number $ numerator x % 1
  _        -> throw @"runtimeError" TypeMismatch

apply [BuiltIn Def, Symbol name, atom] = do
  evaluatedSExp <- eval atom
  environment   <- ask @"table"
  Environment.insertValue name evaluatedSExp
  return (Symbol name)

apply (BuiltIn Defn : Symbol name : rest) = do
  environment <- ask @"table"
  function    <- Function.make environment rest
  Environment.insertValue name (Function function)
  return $ Symbol name

apply [BuiltIn If, predicate, consequent, alternative] =
  eval predicate >>= \case
    Bool False -> eval alternative
    _          -> eval consequent

apply [BuiltIn Not, value] = eval value >>= \case
  Bool False -> return . Bool $ True
  _          -> return . Bool $ False

apply (BuiltIn Print : rest) =
  batchEval rest >>= putStr . unwords . map show >> return (Pair Nil)

apply (BuiltIn Fn : rest) = do
  environment <- ask @"table"
  function    <- Function.make environment rest
  return $ Function function

apply (BuiltIn Eql : rest) = batchEval rest >>= \case
  []            -> throw @"runtimeError" (WrongNumberOfArguments 1 0)
  (base : rest) -> return (Bool $ (== base) `all` rest)

apply [BuiltIn Loop, procedure] = forever (eval procedure)

apply [BuiltIn Read]            = do
  input <- liftIO getLine
  return $ case parse Parser.sExpLine mempty input of
    Left  e -> Error . ParserError . toS . errorBundlePretty $ e
    Right a -> a

apply [BuiltIn Eval , value]   = eval >=> eval $ value

apply [BuiltIn Quote, atom ]   = return atom

apply (BuiltIn Do : rest)      = foldM (const eval) (Pair Nil) rest

apply [BuiltIn Cons, car, cdr] = do
  car <- eval car
  cdr <- eval cdr
  return $ Pair (car :.: cdr)

apply [BuiltIn Car, atom] = eval atom >>= \case
  Pair Nil       -> return $ Pair Nil
  Pair (x ::: _) -> return x
  Pair (x :.: _) -> return x
  _              -> throw @"runtimeError" TypeMismatch

apply [BuiltIn Cdr, atom] = eval atom >>= \case
  Pair Nil        -> return $ Pair Nil
  Pair (_ ::: xs) -> return $ Pair xs
  Pair (_ :.: x ) -> return x
  _               -> throw @"runtimeError" TypeMismatch

apply [BuiltIn Set, Symbol name, atom] = do
  evaluatedSExp <- eval atom
  environment   <- ask @"table"
  Environment.setValue name evaluatedSExp environment
  return (Symbol name)

apply (BuiltIn _    : _ ) = return $ Error NotImplementedYet

apply (s@(Symbol _) : as) = do
  operator <- eval s
  apply (operator : as)

apply (Function fn : as) = do
  evaluatedArguments            <- batchEval as
  (newScope, environment, vars) <- Function.proceed evaluatedArguments fn
  let newEnvironment =
        Environment.Table { variables = newScope, parent = Just environment }
  environmentRef <- liftIO $ newIORef newEnvironment
  local @"table" (const environmentRef) (eval vars)

apply (Macro _        : _ ) = throw @"runtimeError" NotImplementedYet

apply (Pair  (List l) : as) = do
  operator <- apply l
  apply (operator : as)

apply (Pair   (_ :.: _) : _) = throw @"runtimeError" CannotApply

apply (Pair   Nil       : _) = throw @"runtimeError" CannotApply

apply (Bool   _         : _) = throw @"runtimeError" CannotApply

apply (Str    _         : _) = throw @"runtimeError" CannotApply

apply (Number _         : _) = throw @"runtimeError" CannotApply

apply (e@(Error _)      : _) = return e
