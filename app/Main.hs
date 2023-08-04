module Main where

import           Data.Foldable
import           Data.Text           (Text)
import qualified Data.Text.IO        as TIO
import           Options.Applicative (Parser, argument, command,
                                      customExecParser, fullDesc, help, helper,
                                      hsubparser, info, long, metavar, prefs,
                                      progDesc, short, showDefault,
                                      showHelpOnError, str, strOption, value,
                                      (<**>))

import           Graphex

data Command
    = DirectDepsOn Text
    | AllDepsOn Text
    | Why Text Text
    deriving stock Show

data Options = Options {
    optGraph   :: FilePath,
    optCommand :: Command
    } deriving stock Show

options :: Parser Options
options = Options
    <$> strOption (long "graph" <> short 'g' <> showDefault <> value "graph.json" <> help "path to graph data")
    <*> hsubparser (
        command "deps" (info depsCmd (progDesc "Show all direct inbound dependencies to a module"))
         <> command "all" (info allDepsCmd (progDesc "Show all dependencies to a module"))
         <> command "why" (info whyCmd (progDesc "Show why a module depends on another module")))

    where
        depsCmd = DirectDepsOn <$> argument str (metavar "module")
        allDepsCmd = AllDepsOn <$> argument str (metavar "module")
        whyCmd = Why <$> argument str (metavar "module from") <*> argument str (metavar "module to")


main :: IO ()
main = do
    Options{..} <- customExecParser (prefs showHelpOnError) opts
    i <- getInput optGraph
    traverse_ TIO.putStrLn $ case optCommand of
        Why from to    -> why i from to
        DirectDepsOn m -> directDepsOn i m
        AllDepsOn m    -> allDepsOn i m
  where
    opts = info (options <**> helper) ( fullDesc <> progDesc "Graph CLI tool.")
