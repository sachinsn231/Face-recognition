module Image (
    -- * Types & constructors
      Image, Pixel (..) 
    -- * Functions
    , load, save, getPixel, getSize
) where

import Control.Monad
import Data.Array (Array, listArray, (!), (//), bounds, assocs)
import Data.Word
import Ix
import System.FilePath.Posix (takeExtension)

import qualified Graphics.GD as GD

import Primitives

type Image = Array Point Pixel
data Pixel = Pixel {
      red :: Word8, green :: Word8, blue :: Word8
    s} deriving (Eq, Show)

-- Max image width or height (resize before processing).
maxImageSize = Just 320

-- | Loads an image at system path and detects image's type.
-- The second parameter resize the image before processing.
load :: FilePath -> Maybe Size -> IO Image
load path size = do
    GD.withImage openImage $ \image -> 
        GD.withImage (resizeImage image) $ \image' ->
            imageToArray image'
  where
    openImage =
        case takeExtension path of
            (_:ext) | ext `elem` ["jpeg", "jpg"] -> GD.loadJpegFile path
                    | ext == "png" -> GD.loadPngFile path
                    | ext == "gif" -> GD.loadGifFile path
                    | otherwise -> error $ path ++ ": format not supported."
      
    resizeImage image = do
        case size of
            Just (Size w h) -> -- Force image size
                GD.resizeImage (fromIntegral w) (fromIntegral h) image
            Nothing -> -- Use maxImageSize
                case maxImageSize of
                    Just maxSize -> do
                        (w, h) <- GD.imageSize image
                        
                        if w > h && w > maxSize then do
                            GD.resizeImage maxSize (h * maxSize `quot` w) image
                        else if h > maxSize then do
                            GD.resizeImage (w * maxSize `quot` h) maxSize image
                        else return image
                    Nothing -> return image
                    
    imageToArray image = do
        (w, h) <- GD.imageSize image
        xs <- forM (range ((0, 0), (w-1, h-1))) $ \coords ->
            fmap fromGDColor $ GD.getPixel coords image

        let lastPoint = Point (fromIntegral w - 1) (fromIntegral h - 1)
        return $ listArray (Point 0 0, lastPoint) xs

-- | Save an image
save :: FilePath -> Image -> IO ()
save path array = do
    -- Transform the array into GD's image and save
    GD.withImage (GD.newImage size) $ \image -> do
        arrayToImage image
    
        case takeExtension path of
            (_:ext) | ext `elem` ["jpeg", "jpg"] ->
                        GD.saveJpegFile (-1) path image
                    | ext == "png" -> GD.savePngFile path image
                    | ext == "gif" -> GD.saveGifFile path image
    
  where
    arrayToImage image = do
        forM_ (assocs array) $ \(coord, pix) -> do
            GD.setPixel (toGDPoint coord) (toGDColor pix) image
    
    size :: (Int, Int)
    size = let Size w h = getSize array
           in (fromIntegral w, fromIntegral h)

-- | Get a pixel from the image
getPixel :: Image -> Point -> Pixel
getPixel image coord = image ! coord
    
-- | Get image's size
getSize :: Image -> Size
getSize image = 
    let Point w h = snd $ bounds $ image
    in Size (w+1) (h+1)

toGDColor :: Pixel -> GD.Color
toGDColor pixel = GD.rgb r g b
  where
    r = fromIntegral $ red pixel
    g = fromIntegral $ green pixel
    b = fromIntegral $ blue pixel

fromGDColor :: GD.Color -> Pixel
fromGDColor color =
    Pixel { red = r', green = g', blue = b' }
  where
    (r, g, b, _) = GD.toRGBA color
    r' = fromIntegral r
    g' = fromIntegral g
    b' = fromIntegral b
    
toGDPoint :: Point -> GD.Point
toGDPoint (Point x y) = (fromIntegral x, fromIntegral y)

fromGDPoint :: GD.Point -> Point
fromGDPoint (x, y) = Point (fromIntegral x) (fromIntegral y)
