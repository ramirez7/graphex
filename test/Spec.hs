module Spec where

import           Control.Monad            (foldM, guard)
import           Data.Foldable            (fold)
import           Data.Map                 (Map)
import qualified Data.Map.Strict          as Map
import           Data.Set                 (Set)
import qualified Data.Set                 as Set
import           Data.Text                (Text)
import qualified Data.Text                as T
import qualified Data.Tree                as Tree
import           GHC.Generics             (Generic)

import           Test.QuickCheck.Checkers
import           Test.QuickCheck.Classes
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck    as QC

import           Graphex
import           Graphex.Core
import           Graphex.Search

-- It's usually a terrible idea to write your own Show instance, but this is just for debugging.
instance Show Graph where
    show (Graph m) = fold [show k <> " -> " <> show (Set.toList vs) <> ", " | (k, vs) <- Map.assocs m]

-- I asked ChatGPT to make me a list of arbitrary strings in Haskell format.
someStrings :: [Text]
someStrings =
    ["x", "y", "z", "foo", "bar", "baz", "qux", "hello", "world",
     "alpha", "beta", "gamma", "delta", "list", "value", "result",
     "input", "output", "function", "variable"]

instance Arbitrary Graph where
    arbitrary = do
        -- We begin with some subset of keys in arbitrary order
        somekeys <- shuffle =<< sublistOf someStrings
        -- We build a graph of acyclic connections, ensuring that all keys are present
        Graph . (<> Map.fromList [(k, mempty) | k <- somekeys]) <$> foldM next mempty somekeys
        where
            next m k = flip (Map.insert k) m . Set.fromList <$> sublistOf (Map.keys m)

    -- A custom shrink here needs to make sure
    shrink (Graph m) = Graph . Map.fromList <$> keySubs (Map.assocs m)
        where
            keySubs = fmap clean . shrinkList (const [])
            clean kvs = (\(k, vs) -> (k, vs `Set.intersection` keys)) <$> kvs
                where
                    keys = Set.fromList (fmap fst kvs)

-- A DAG that we know contains the given node.
data GraphWithKey = GraphWithKey Text Graph
    deriving stock (Show, Eq, Generic)

instance Arbitrary GraphWithKey where
    arbitrary = do
        Graph g <- arbitrary `suchThat` (\(Graph m) -> (not . Map.null) m)
        k <- QC.elements (Map.keys g)
        pure $ GraphWithKey k (Graph g)

    -- When shrinking, our k is constant and should still be in the resulting map keyset (though links can be removed)
    shrink (GraphWithKey k g) = GraphWithKey k <$> filter (\(Graph m) -> Map.member k m) (shrink g)

-- A DAG that we know contains two keys that are connected (a path exists to the second one from the first one).
data ConnectedGraph = ConnectedGraph Text Text Graph
    deriving stock (Show, Eq, Generic)

instance Arbitrary ConnectedGraph where
    arbitrary = do
        (g@(Graph m), connMap) <- arbitrary `suchThatMap` connections
        from <- QC.elements (Map.keys connMap)
        to <- QC.elements (connMap Map.! from)
        pure $ ConnectedGraph from to g
        where
            connections :: Graph -> Maybe (Graph, Map Text [Text])
            connections g@(Graph m) = do
                let connMap = Map.fromListWith (<>) [(k, [ks]) | k <- Map.keys m, ks <- Set.toList (Set.delete k $ allDepsOn g k)]
                guard (not . Map.null $ connMap)
                pure (g, connMap)

    -- When shrinking, our k is constant and should still be in the resulting map keyset (though links can be removed)
    shrink (ConnectedGraph from to g) = ConnectedGraph from to <$> filter (\(Graph m) -> Map.member from m && Map.member to m) (shrink g)

prop_reverseEdgesId :: Graph -> Property
prop_reverseEdgesId g =
    counterexample ("fwd: " <> show g <> "\n rev: " <> show rg) $
    g === reverseEdges (reverseEdges g)
    where
        rg = reverseEdges g

prop_reversedDep :: Graph -> Property
prop_reversedDep g@(Graph m) =
    counterexample ("fwd: " <> show g <> "\nrev: " <> show rg) $
    all (\(k, vs) -> all (\k' -> k `elem` directDepsOn rg k') vs) (Map.assocs m)
    where
        rg = reverseEdges g

prop_reachableIsFindable :: ConnectedGraph -> Bool
prop_reachableIsFindable gwk@(ConnectedGraph from to g) = not . null $ why g from to

prop_negativePathfinding :: Graph  -> Property
prop_negativePathfinding g = forAll oneGoodKey (null . uncurry (why g))
    where oneGoodKey = do
            good <- elements someStrings
            let bad = "missingnode"
            elements [ (good, bad), (bad, good) ]

prop_notSelfDepDirect :: GraphWithKey -> Bool
prop_notSelfDepDirect (GraphWithKey k g) = k `notElem` directDepsOn g k

prop_allDepsContainsSelfDeps :: GraphWithKey -> Bool
prop_allDepsContainsSelfDeps (GraphWithKey k g) = directDepsOn g k `Set.isSubsetOf` allDepsOn g k

prop_ranking :: GraphWithKey -> Bool
prop_ranking (GraphWithKey k g) = length (allDepsOn g k) == rankings g Map.! k

prop_restrictedGraphHasSameDeps :: GraphWithKey -> Bool
prop_restrictedGraphHasSameDeps (GraphWithKey k g) = allDepsOn g k == allDepsOn (restrictTo g (allDepsOn g k)) k

prop_restrictedNodesShouldBeDeps :: GraphWithKey -> Property
prop_restrictedNodesShouldBeDeps (GraphWithKey k g) =
  let restricted = restrictTo g (allDepsOn g k)
      edges = Map.toList (unGraph restricted)
      validNodes = Set.insert k $ allDepsOn g k
  in counterexample ("restricted: " <> show restricted) $
     all (\(k, vs) -> Set.member k validNodes && all (`Set.member` validNodes) vs) edges

prop_allPathsShouldIncludeShortest :: ConnectedGraph -> Property
prop_allPathsShouldIncludeShortest gwk@(ConnectedGraph from to g) =
    why g from to === why (allPathsTo g from to) from to

prop_allPaths :: ConnectedGraph -> Property
prop_allPaths gwk@(ConnectedGraph from to g) =
    counterexample ("allPaths: " <> show allPaths <> "\nallFrom: " <> show allFrom <> "\nallTo: " <> show allTo <> "\ninBoth: " <> show inBoth) $
    conjoin ((\(k, (f,t)) -> counterexample ("  at " <> show k <> ": " <> show (f,t)) $ f .&&. t) <$> got)
    where
        got = mapMaybeWithKey (\k -> if k `elem` [from, to] then Nothing else Just (validated k)) g
        validated k = (checkPath (k `Set.member` inBoth) from k, checkPath (k `Set.member` inBoth) k to)
        allFrom = allDepsOn g from
        allTo = allDepsOn (reverseEdges g) to
        inBoth = allFrom `Set.intersection` allTo
        allPaths = allPathsTo g from to
        hasPath f = not . null . why allPaths f
        checkPath True f  = hasPath f
        checkPath False f = not . hasPath f

prop_importExport :: Graph -> Property
prop_importExport g =
    counterexample ("exported: " <> show exported <> "\nimported: " <> show imported) $
    imported === g
    where
        exported = graphToDep g
        imported = depToGraph exported

prop_floodVsBFS :: GraphWithKey -> Bool
prop_floodVsBFS (GraphWithKey k g) = flood (directDepsOn g) k == Set.fromList (bfsOn id (Set.toList . directDepsOn g) k)

prop_floodVsDFS :: GraphWithKey -> Bool
prop_floodVsDFS (GraphWithKey k g) = flood (directDepsOn g) k == Set.fromList (dfsOn id (Set.toList . directDepsOn g) k)

prop_treeDeps :: GraphWithKey -> Property
prop_treeDeps (GraphWithKey k g) =
    counterexample ("graph: " <> show g <> "\nTree:\n" <> Tree.drawTree (T.unpack <$> t)) $
    allDepsOn g k === Set.fromList (Tree.flatten t)
    where t = graphToTree k g

prop_treeDepsWorksWithCycles :: ConnectedGraph -> Property
prop_treeDepsWorksWithCycles (ConnectedGraph from to g@(Graph m)) =
    counterexample (Tree.drawTree (T.unpack <$> t)) $
    allDepsOn g from === Set.fromList (Tree.flatten t)
  where g' = Graph (Map.insertWith (<>) to (Set.singleton from) m)
        t = graphToTree from g'

prop_treeDepsEmptiness :: Graph -> Property
prop_treeDepsEmptiness g = counterexample (Tree.drawTree (T.unpack <$> t)) $ t === Tree.Node "non-existent-key" []
    where t = graphToTree "non-existent-key" g

instance Arbitrary ModuleName where
    arbitrary = ModuleName <$> elements someStrings

prop_moduleSingleton :: ModuleName -> ModuleName -> Bool
prop_moduleSingleton importer importee = singletonModuleGraph importer importee == mkModuleGraph importer [importee]

toModuleGraph :: Graph -> ModuleGraph
toModuleGraph (Graph m) = foldMap (\(k,v) -> mkModuleGraph (ModuleName k) (ModuleName <$> Set.toList v)) $ Map.assocs m

instance EqProp ModuleGraph where (=-=) = eq

instance Arbitrary ModuleGraph where
    arbitrary = toModuleGraph <$> arbitrary

test_Instances :: [TestTree]
test_Instances = [
  testProperties "semigroup" (unbatch $ semigroup (undefined :: ModuleGraph, undefined :: Int)),
  testProperties "monoid" (unbatch $ monoid (undefined :: ModuleGraph))
  ]
