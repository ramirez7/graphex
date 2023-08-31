{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE FlexibleContexts #-}

-- | Implements a very crude Haskell import parser.
--
-- All it does is parse full module names that are imported in a file,
-- ignoring false positives.
--
-- It does not use CPP, so all conditional imports are parsed out. For
-- graphex, this makes sense in a way - those are all still dependencies.
module Graphex.Parser where

import Data.Text qualified as T
import Data.Void
import Data.String (IsString)
import Data.Maybe (isJust)
import Data.Either (rights)

import Text.Megaparsec
import Text.Megaparsec.Char
import Replace.Megaparsec (sepCap, streamEdit)

import Graphex.Core

importParser
  :: MonadParsec e s m
  => Token s ~ Char
  => IsString (Tokens s)
  => m Import
importParser = do
  -- This newline helps us avoid the word "import" in comments or identifiers.
  -- Basically, we insist imports are at the beginning of a line (which Haskell does
  -- too I think)
  _ <- newline
  _ <- string "import"
  space1
  -- Handle prefix qualified imports
  _ <- isJust <$> optional (string "qualified")
  space
  -- Handle PackageImports
  pkg <- optional $ between (char '"') (char '"') $ some $ alphaNumChar <|> char '-' <|> char '_'
  space

  modid <- some $ alphaNumChar <|> char '.' <|> char '_'

  pure Import
    { module_ = ModuleName $ T.pack modid
    , package = T.pack <$> pkg
    }

importsParser
  :: forall e s m
   . MonadParsec e s m
  => Token s ~ Char
  => IsString (Tokens s)
  => m [Import]
importsParser = rights <$> sepCap importParser

removeBlockComments :: String -> String
removeBlockComments = streamEdit (blockCommentParser @Void) (\_ -> "")

blockCommentParser
  :: forall e s m
   . MonadParsec e s m
  => Token s ~ Char
  => IsString (Tokens s)
  => m String
blockCommentParser = do
  _ <- string "{-"
  manyTill anySingle (string "-}")
  
parseFileImports :: FilePath -> IO [Import]
parseFileImports fp = do
  contents <- removeBlockComments <$> readFile fp
  case runParser (importsParser @Void) fp contents of
    Left err -> error $ unlines $ [mconcat ["Failed to parse ", fp, ":"], errorBundlePretty err]
    Right x -> pure x
