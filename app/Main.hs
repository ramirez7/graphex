module Main where

import           Data.Aeson           (eitherDecode, encode)
import           Data.Bool            (bool)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Csv             as CSV
import           Data.Foldable
import           Data.List            (sortOn)
import           Data.List.NonEmpty   (NonEmpty)
import qualified Data.List.NonEmpty   as NE
import qualified Data.Map.Strict      as Map
import           Data.Ord             (Down (..))
import           Data.Text            (Text)
import qualified Data.Text            as T
import qualified Data.Text.IO         as TIO
import           Options.Applicative  (Parser, argument, command,
                                       customExecParser, fullDesc, help, helper,
                                       hsubparser, info, long, metavar, prefs,
                                       progDesc, short, showDefault,
                                       showHelpOnError, some, str, strOption,
                                       switch, value, (<**>))

import           Graphex
import Graphex.Cabal
import Graphex.CSV qualified
import Graphex.LookingGlass

data Command
    = DirectDepsOn Text
    | AllDepsOn (NonEmpty Text)
    | Why Text Text
    | AllPaths Text Text
    | Rankings
    | Select Text
    | ToCSV Bool
    deriving stock Show


data Options = GraphCmd GraphOptions | CabalCmd CabalOptions
  deriving stock Show

data GraphOptions = GraphOptions {
    optGraph   :: FilePath,
    optReverse :: Bool,
    optCommand :: Command
    } deriving stock Show

data CabalOptions = CabalOptions deriving stock Show

options :: Parser Options
options = hsubparser $ fold
  [ command "graph" (info (GraphCmd <$> graphOptions) (progDesc "Graph operations"))
  , command "cabal" (info (CabalCmd <$> cabalOptions) (progDesc "Cabal operations"))
  ]

cabalOptions :: Parser CabalOptions
cabalOptions = pure CabalOptions

graphOptions :: Parser GraphOptions
graphOptions = GraphOptions
    <$> strOption (long "graph" <> short 'g' <> showDefault <> value "graph.json" <> help "path to graph data")
    <*> switch (long "reverse" <> short 'r' <> help "reverse edges")
    <*> hsubparser (fold [
        command "deps" (info depsCmd (progDesc "Show all direct inbound dependencies to a module")),
        command "all" (info allDepsCmd (progDesc "Show all dependencies to a module")),
        command "why" (info whyCmd (progDesc "Show why a module depends on another module")),
        command "all-paths" (info allPathsCmd (progDesc "Show all ways a module depends on another module")),
        command "rank" (info (pure Rankings) (progDesc "Show the most depended on modules")),
        command "select" (info selectCmd (progDesc "Select a subset of the graph from a starting module")),
        command "to-csv" (info csvCmd (progDesc "Convert to a CSV of edges compatible with SQLite and Gephi"))
        ])

    where
        depsCmd = DirectDepsOn <$> argument str (metavar "module")
        allDepsCmd = AllDepsOn <$> some1 (argument str (metavar "module"))
        selectCmd = Select <$> argument str (metavar "module")
        whyCmd = Why <$> argument str (metavar "module from") <*> argument str (metavar "module to")
        allPathsCmd = AllPaths <$> argument str (metavar "module from") <*> argument str (metavar "module to")
        csvCmd = ToCSV <$> switch (long "no-header" <> short 'n' <> help "Omit CSV header")
        some1 = fmap NE.fromList . some

printStrs :: Foldable f => f Text -> IO ()
printStrs = traverse_ TIO.putStrLn

getInput :: FilePath -> IO Graph
getInput fn = either fail (pure . depToGraph) . eitherDecode =<< BL.readFile fn

main :: IO ()
main = customExecParser (prefs showHelpOnError) opts >>= \case
  GraphCmd GraphOptions{..} -> do
    let handleReverse = bool id reverseEdges optReverse
    graph <- handleReverse <$> getInput optGraph
    case optCommand of
        Why from to      -> printStrs $ why graph from to
        AllPaths from to -> BL.putStr . encode . graphToDep $ allPathsTo graph from to
        DirectDepsOn m   -> printStrs $ directDepsOn graph m
        AllDepsOn m      -> printStrs $ foldMap (allDepsOn graph) m
        Rankings         -> printStrs $ fmap (\(m,n) -> m <> " - " <> (T.pack . show) n) . sortOn (Down . snd) . Map.assocs $ rankings graph
        Select m         -> BL.putStr $ encode (graphToDep (handleReverse (restrictTo graph (allDepsOnWithKey graph m))))
        ToCSV noHeader   -> BL.putStr $ (if noHeader then CSV.encode else CSV.encodeDefaultOrderedByName) $ Graphex.CSV.toEdges graph
  CabalCmd CabalOptions{} -> do
    mg <- discoverCabalModuleGraph
    BL.putStr $ encode $ toLookingGlass "Internal Package Dependencies" mempty mg
  where
    opts = info (options <**> helper) ( fullDesc <> progDesc "Graph CLI tool.")
