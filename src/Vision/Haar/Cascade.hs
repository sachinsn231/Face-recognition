{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Vision.Haar.Cascade (
    -- * Types & constructors
      HaarCascade (..), HaarCascadeStage
    -- * Functions 
    , trainHaarCascade, cascadeStats
    -- * Impure utilities
    , loadHaarCascade
    ) where

import Data.List
import Data.Ratio
import Control.DeepSeq (NFData (), rnf, force)
import System.Random (RandomGen, StdGen, mkStdGen, next)

import Debug.Trace

import AI.Learning.AdaBoost (adaBoost)
import AI.Learning.Classifier (
      Classifier (..), StrongClassifier (..), Score
    )

import Vision.Haar.Classifier (
      HaarClassifier (..), TrainingImage (..), trainHaarClassifier
    )
import Vision.Haar.Window (Win, wRect)

-- | The 'HaarCascade' consists in a set of 'HaarCascadeStage' which will be
-- evaluated in cascade to check an image for an object.
newtype HaarCascade = HaarCascade {
      hcaStages :: [HaarCascadeStage]
    } deriving (Show, Read)
    
-- | An 'HaarCascadeStage' is 'StrongClassifier' (composed of 'HaarClassifier's)
-- trained with the 'adaBoost' algorithm associated with a threshold on the 
-- detection score which enable the cascade trainer to adjust the detection 
-- rate. First stages of the cascade have high false positive rate but very low
-- non-detection rate.
data HaarCascadeStage = HaarCascadeStage {
      hcsClassifier :: !(StrongClassifier HaarClassifier)
    , hcsThreshold :: !Score
    } deriving (Show, Read)
    
instance NFData TrainingImage where
    rnf ti = ti `seq` () 
 
-- | The 'HaarCascade' is able to classify a part of an image using its 
-- iteration window by evaluating each stage in cascade.
instance Classifier HaarCascade Win Bool where
    HaarCascade []     `cClassScore` window = (True, 1)
    HaarCascade stages `cClassScore` window =
        go stages
      where
        go [s]     = s `cClassScore` window
        go ~(s:ss) =
            let (!valid, !score) = s `cClassScore` window
            in if valid
                  then go ss
                  else (False, score)
    {-# INLINE cClassScore #-}

instance Classifier HaarCascade TrainingImage Bool where
    cascade `cClassScore` image = cascade `cClassScore` tiWindow image
    {-# INLINE cClassScore #-}

-- | The 'HaarCascadeStage' validate the window if the score of the 
-- 'StrongClassifier' is greater than the threshold. 
instance Classifier HaarCascadeStage Win Bool where
    stage `cClassScore` window =
        let !stageScore = faceConfidence (hcsClassifier stage) window
        in (stageScore >= hcsThreshold stage, stageScore)
    {-# INLINE cClassScore #-}

instance Classifier HaarCascadeStage TrainingImage Bool where
    stage `cClassScore` image = stage `cClassScore` tiWindow image
    {-# INLINE cClassScore #-}
    
-- | Returns the confidence score that the 'Classifier' gives about the face
-- nature of the test.
faceConfidence :: Classifier HaarClassifier t Bool => 
                  StrongClassifier HaarClassifier -> t -> Score
faceConfidence sc window =
    go (scClassifiers sc) 0
  where
    go []          score = score
    go ((c, w):cs) score = 
        let score' = if c `cClass` window then w else 0
        in go cs (score + score')
{-# INLINE faceConfidence #-}

maxFalsePositive, stageMaxFalsePositive, stageMinDetection :: Rational
maxFalsePositive = 0.000001
stageMaxFalsePositive = 0.6
stageMinDetection = 0.995

trainHaarCascade :: [TrainingImage] -> (StdGen -> [TrainingImage]) -> HaarCascade
trainHaarCascade valid invalidGen =
    trainCascade (HaarCascade []) 1.0 (mkStdGen 1)
  where
    !nValid = length valid
    
    -- Trains the cascade by adding a new stage until the false detection rate
    -- is too high.
    trainCascade cascade falsePositive gen =
        let -- Selects a new set of invalid tests which are incorrectly detected
            -- as faces by the current cascade.
            !invalid = force $ take nValid $ filter (cascade `cClass`) (invalidGen gen)
            
            -- Trains the new stage with the set of tests.
            sc = tail $ adaBoost (invalid ++ valid) trainHaarClassifier
            (!stage, !stageFalsePositive) = trainStage sc invalid
            falsePositive' = falsePositive * stageFalsePositive
            !cascade' = HaarCascade (hcaStages cascade ++ [stage])
        in if traceShow ("New classifier - " ++ show (length $ scClassifiers $ hcsClassifier $ stage) ++ " features", falsePositive') $ falsePositive' > maxFalsePositive
              -- Add a new stage if the false detection rate is too high.
              then trainCascade cascade' falsePositive' (snd $ next gen)
              else cascade'
    
    -- Trains a stage of the cascade by adding a new weak classifier to the 
    -- the stage\'s 'StrongClassifier' until the stage meets the required level
    -- of false detection.
    -- For each new weak classifier, decrease the threshold of the 
    -- 'StrongClassifier' until the stage reaches the minimum level of 
    -- detection.
    trainStage ~(sc:scs) invalid' =
        let -- Valid faces scores, sorted, descending.
            scores = reverse $ sort $ map (faceConfidence sc) valid
            
            groupedScores = [ (head s, length s) | s <- group scores ]
            
            -- Number of not detected valid tests for each threshold.
            thresholdsNotDetected = 
                let infinity = 1/0 
                    -- Starts with an infinite threshold so each face is not 
                    -- detected.
                in scanl step (infinity, nValid) groupedScores
            step (_, !nNotDetected) (!thres, !nDetected) =
                (thres, nNotDetected - nDetected)
            
            -- Detection rates (score between 0 and 1) for each threshold.
            thresholdsRate = [ (thres, rate)
                | (thres, nNotDetected) <- thresholdsNotDetected
                , let rate = integer (nValid - nNotDetected) % integer nValid
                ]
            
            -- Find the first threshold which reaches the required minimum
            -- detection rate.
            Just (!threshold, !rate) = 
                find ((>= stageMinDetection) . snd) thresholdsRate
            
            !stage = HaarCascadeStage sc threshold
            
            !nFalsePositive = length $ filter (stage `cClass`) invalid'
            !falsePositive = integer nFalsePositive % integer nValid
        in traceShow (threshold, length invalid', fromIntegral (numerator rate) / fromIntegral (denominator rate), fromIntegral (numerator falsePositive) / fromIntegral (denominator falsePositive)) (if falsePositive > stageMaxFalsePositive
              -- Add a new weak classifier if the false positive rate is too
              -- high.
              then trainStage scs invalid'
              else (stage, falsePositive))

-- | Loads a trained 'HaarCascade'.
loadHaarCascade :: FilePath -> IO HaarCascade
loadHaarCascade path = read `fmap` readFile path

-- | Gives the statistics (detection rate, false positive rate) of an 
-- 'HaarCascade'.
cascadeStats :: HaarCascade -> [TrainingImage] -> (Score, Score)
cascadeStats cascade ts = 
    let (valid, invalid) = partition tiValid ts
        (nValid, nInvalid) = (length valid, length invalid)
        nDetected = length $ filter (cascade `cClass`) valid
        nFalsePositive = length $ filter (cascade `cClass`) invalid
        detectionRate = double nDetected / double nValid
        falsePositiveRate = double nFalsePositive / double nInvalid
    in (detectionRate, falsePositiveRate)

integer :: (Integral a) => a -> Integer
integer = fromIntegral
double :: (Integral a) => a -> Double
double = fromIntegral