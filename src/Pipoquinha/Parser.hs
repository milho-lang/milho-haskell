module Pipoquinha.Parser
  ( sExpLine
  , sExpFile
  , parseFile
  , parseExpression
  ) where

import           Control.Monad.Combinators.NonEmpty
                                                ( endBy1 )
import           Control.Monad.Fail             ( fail )
import           Data.List.NonEmpty
import           Data.Text                      ( strip )
import           Data.Void
import qualified Pipoquinha.BuiltIn            as BuiltIn
import           Pipoquinha.BuiltIn
import           Pipoquinha.Error               ( T(..) )
import qualified Pipoquinha.SExp               as SExp
import           Pipoquinha.SExp
import           Protolude               hiding ( bool
                                                , list
                                                , many
                                                , some
                                                , try
                                                )
import           Text.Megaparsec         hiding ( endBy1 )
import           Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer    as L

type Parser = Parsec Void Text

builtInChoice :: [Parser BuiltIn.T]
builtInChoice = fmap toChoice [minBound ..]
  where toChoice builtIn = try (builtIn <$ string (show builtIn))

builtIn :: Parser BuiltIn.T
builtIn = string ".__" *> try (choice builtInChoice) <?> "built-in"

number :: Parser Rational
number =
  L.signed
      (return ())
      (do
        numerator   <- L.decimal
        denominator <- optional (char '/' >> L.decimal)
        case denominator of
          Nothing -> return (numerator % 1)
          Just 0  -> fail "denominator cannot be 0"
          Just x  -> return (numerator % x)
      )
    <?> "number"

bool :: Parser Bool
bool =
  choice
      [ True <$ string "True"
      , False <$ string "False"
      , True <$ string "Real"
      , False <$ string "Feiki"
      ]
    <?> "boolean"

str :: Parser Text
str =
  toS <$> between (char '\"') (char '\"') (many $ satisfy (/= '"')) <?> "string"

pair :: Parser SExp.Pair
pair = do
  _    <- char '(' *> space
  head <- sExp `endBy1` space1
  _    <- char '.' *> space1
  tail <- sExp
  _    <- space <* char ')'
  return (make head tail) <?> "pair"
 where
  make (x :| []) y = x :.: y
  make (x :| xs) y = x ::: make (fromList xs) y


list :: Parser [SExp.T]
list =
  between (char '(' *> space) (space <* char ')') (sExp `sepEndBy` space1)
    <?> "list"

quotedSExp :: Parser SExp.T
quotedSExp =
  (do
      _          <- char '\''
      expression <- sExp
      return (Pair (List [BuiltIn Quote, expression]))
    )
    <?> "quote"

invalidSymbolChars :: [Char]
invalidSymbolChars = "[]() \t\r\n\"'"

invalidSymbolStart :: [Char]
invalidSymbolStart = ".1234567890" <> invalidSymbolChars

pSymbol :: Parser Text
pSymbol = do
  firstChar <- satisfy (`notElem` invalidSymbolStart)
  rest      <- many $ satisfy (`notElem` invalidSymbolChars)
  return (toS (firstChar : rest))

sExp :: Parser SExp.T
sExp =
  choice
      [ SExp.Pair Nil <$ string "Nil"
      , Bool <$> bool
      , try (Number <$> number)
      , Symbol <$> pSymbol
      , String <$> str
      , BuiltIn <$> builtIn
      , try (Pair <$> pair)
      , Pair . List <$> list
      , quotedSExp
      ]
    <?> "SExpression"

sExpLine :: Parser SExp.T
sExpLine = sExp <* eof

sExpFile :: Parser [SExp.T]
sExpFile = between space space (sExp `sepBy` space1) <* eof

parseFile :: Text -> Either Text [SExp.T]
parseFile = first (toS . errorBundlePretty) . parse sExpFile mempty . strip

parseExpression :: Text -> SExp.T
parseExpression =
  fromEither (Error . ParserError . toS . errorBundlePretty)
    . parse sExpLine mempty
 where
  fromEither f (Left  a) = f a
  fromEither _ (Right b) = b
