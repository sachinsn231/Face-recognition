{-# LANGUAGE MultiParamTypeClasses #-}

module Trainer(
    -- * Types & constructors
      TrainingImage (..)
    -- * Functions
    , train, selectHaarClassifier
    ) where

import Control.Parallel.Strategies
import Data.Function
import Data.List
import System.Directory (getDirectoryContents)
import System.FilePath (FilePath, (</>))

import AdaBoost (
      TrainingTest (..), Classifier (..)
    , Weight, StrongClassifier, adaBoost
    )
import GreyImage (GreyImage, load)
import HaarClassifier (HaarClassifier (..))
import HaarFeatures (HaarFeature, features, compute)
import IntegralImage (computeIntegralImage)
import Primitives
import Window (Win, win, windowWidth, windowHeight)

-- | Contains a training image with its 'IntegralImage'.
data TrainingImage = TrainingImage {
      tiWindow :: Win
    , tiValid :: Bool
    }

instance TrainingTest TrainingImage where
    isValid = tiValid

instance Classifier HaarClassifier TrainingImage where
    classifier `check` image = classifier `check` (tiWindow image)

-- | Trains a strong classifier from directory of tests containing two
-- directories (bad & good).
train :: FilePath -> Int -> FilePath -> IO ()
train directory steps savePath = do
    putStrLn "Loading images ..."
    good <- loadIntegral True (directory </> "good")
    putStrLn "\tgood/ loaded"
    bad <- loadIntegral False (directory </> "bad")
    putStrLn "\tbad/ loaded"
    let tests = good ++ bad

    putStrLn "Train classifier ..."
    let classifier = adaBoost steps tests selectHaarClassifier
    print classifier

    putStrLn "Save classifier ..."
    writeFile savePath $ show classifier
    
  where
    loadIntegral valid = fmap (trainingImages valid) . loadImages
     
    loadImages dir = do
        paths <- getDirectoryContents $ dir
        mapM (loadImage . (dir </>)) (excludeHidden paths)
        
    loadImage path =
        load path $ Just $ Size windowWidth windowHeight
        
    excludeHidden = filter $ ((/=) '.') . head

-- | Accepts a list of images with a boolean indicating if the image is valid.
-- Compute the 'IntegralImage' and initialises a full image 'Win' for each
-- image.
trainingImages :: Bool -> [GreyImage] -> [TrainingImage]
trainingImages valid = map trainingImage
  where
    rect = Rect 0 0 windowWidth windowHeight
    trainingImage image =
        let int = computeIntegralImage image id
            squaredInt = computeIntegralImage image (^2)
            window = win rect int squaredInt
        in TrainingImage window valid

-- | Builds an 'HaarClassifier' which make the best score in classifying the set
-- of tests and weights given.
-- The classifier selection can benefit from parallel computing.
selectHaarClassifier :: [(TrainingImage, Weight)] -> (HaarClassifier, Weight)
selectHaarClassifier tests =
    -- Selects the best classifier over all features.
    minimumBy (compare `on` snd) bestClassifiers
  where
    -- Selects the best classifier for each feature, using parallel computing.
    bestClassifiers =
        let parStrategy = evalTuple2 rseq rseq
        in parMap parStrategy bestClassifier features
    
    -- Selects the best classifier configuration for a feature.
    bestClassifier = minimumBy (compare `on` snd) . featureClassifiers

    -- Lists all possibles classifier configurations associated with theirs
    -- error for a feature and the set of tests.
    featureClassifiers feature =
        -- The first computed classifier will give "False" for each test, so
        -- its error score is the weight of valid tests.
        fst $ foldl' (\(cs, trueError) (v, w) -> 
            let trueError' = trueError - w
                falseError' = 1.0 - trueError'
                c1 = (HaarClassifier feature v True, trueError')
                c2 = (HaarClassifier feature v False, falseError')
            in (c1 : c2 : cs, trueError')
        ) ([], weightValid) (featureValuesSorted feature tests)

    -- Sums the weight of all valid tests.
    weightValid = sum $ map snd $ filter (isValid . fst) tests

-- | Computes all feature's values with a set of tests, sorted.
-- Keeps the test weight. Negative for valid tests, positive for valid tests.
featureValuesSorted :: HaarFeature -> [(TrainingImage, Weight)]
                       -> [(Int64, Weight)]
featureValuesSorted feature tests =
    sortBy (compare `on` value) $ map computeValue tests
  where
    -- Computes the feature value and its weight.
    computeValue (t, w) =
        let w' = if isValid t
            then w
            else -w
        in (compute feature (tiWindow t), w')
    
    value = fst