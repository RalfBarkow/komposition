{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ConstraintKinds  #-}
{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE ExplicitForAll   #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedLists  #-}
{-# LANGUAGE PolyKinds        #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeFamilies     #-}
{-# LANGUAGE TypeOperators    #-}
-- |
module FastCut.Application where

import           FastCut.Prelude hiding ((>>), (>>=), State)

import           Control.Lens
import qualified Data.HashMap.Strict      as HashMap
import           Data.Row.Records hiding  (map)
import           GHC.Exts                 (fromListN)
import           Motor.FSM

import           Control.Monad.Indexed.IO
import           FastCut.Focus
import           FastCut.KeyMap
import           FastCut.Project
import           FastCut.Sequence
import           FastCut.UserInterface

data AppendCommand
  = AppendClip
  | AppendGap
  | AppendSequence
  deriving (Show, Eq)

data TimelineCommand
  = FocusCommand FocusCommand
  | AppendCommand AppendCommand
  | Exit
  deriving (Show, Eq)

data LibraryCommand
  = LibraryEscape
  | LibraryUp
  | LibraryDown
  | LibrarySelect
  deriving (Show, Eq)

(>>) :: IxMonad m => m i j a -> m j k b -> m i k b
(>>) = (>>>)

(>>=) :: IxMonad m => m i j a -> (a -> m j k b) -> m i k b
(>>=) = (>>>=)

nextCommandOrBeep ::
     (UserInterface m, IxMonadIO m, HasType n (State m s) r)
  => KeyMap e
  -> Name n
  -> m r r (Maybe e)
nextCommandOrBeep (KeyMap keymap) gui =
  nextEvent gui >>>= \case
    KeyPress combo ->
      case HashMap.lookup combo keymap of
        Just (SequencedMappings keymap') -> nextCommandOrBeep keymap' gui
        Just (Mapping e) -> ireturn (Just e)
        Nothing -> beep gui >>> ireturn Nothing

nextLibraryCommand ::
     (UserInterface m, IxMonadIO m, HasType n (State m 'LibraryMode) r)
  => Name n
  -> m r r (Maybe LibraryCommand)
nextLibraryCommand =
  nextCommandOrBeep $
    KeyMap
    [ ([KeyChar 'j'], Mapping LibraryDown)
    , ([KeyChar 'k'], Mapping LibraryUp)
    , ([KeyChar 'q'], Mapping LibraryEscape)
    , ([KeyEnter], Mapping LibrarySelect)
    ]

focusClip :: Int -> [Clip a mt] -> [Clip Focused mt]
focusClip i clips =
  clips
  & map (setClipAnnotation Blurred)
  & ix i %~ setClipAnnotation Focused

selectClipFromList ::
     ( UserInterface m
     , IxMonadIO m
     , lm ~ State m 'LibraryMode
     , HasType n lm r
     , Modify n lm r ~ r
     )
  => Name n
  -> [Clip () mt]
  -> Int
  -> m r r (Maybe (Clip () mt))
selectClipFromList gui clips n = do
  updateLibrary gui (focusClip n clips)
  nextLibraryCommand gui >>>= \case
    Just LibraryEscape -> ireturn Nothing
    Just LibrarySelect -> ireturn (clips ^? element n)
    Just LibraryUp
      | n > 0 -> selectClipFromList gui clips (pred n)
      | otherwise -> continue
    Just LibraryDown
      | n < length clips - 1 -> selectClipFromList gui clips (succ n)
      | otherwise -> continue
    Nothing -> continue
  where
    continue = do
      beep gui
      selectClipFromList gui clips n

-- | Convenient type for actions that transition from timeline mode
-- into library mode, doing some user interactions, and returning back
-- to timeline mode with a value.
type ThroughLibraryMode n a
   = forall m i o lm tm.
   ( UserInterface m
     , IxMonadIO m
     , HasType n tm i
     , HasType n tm o
     , (Modify n lm i .! n) ~ lm
     , Modify n tm (Modify n lm i) ~ o
     , Modify n lm (Modify n lm i) ~ Modify n lm i
     , lm ~ State m 'LibraryMode
     , tm ~ State m 'TimelineMode
     )
   => m i o a

selectClip ::
  Name n
  -> Project
  -> Focus
  -> SMediaType mt
  -> ThroughLibraryMode n (Maybe (Clip () mt))
selectClip gui project focus' mediaType = do
  enterLibrary gui
  case mediaType of
    SVideo -> do
      clip <- selectClipFromList gui (project ^. library . videoClips) 0
      exitLibrary gui project focus'
      ireturn clip
    SAudio -> do
      clip <- selectClipFromList gui (project ^. library . audioClips) 0
      exitLibrary gui project focus'
      ireturn clip

selectClipAndAppend ::
  Name n
  -> Project
  -> Focus
  -> SMediaType mt
  -> ThroughLibraryMode n Project
selectClipAndAppend gui project focus' mediaType =
  selectClip gui project focus' mediaType >>= \case
    Just clip ->
      project
      & topSequence %~ appendAt' focus' (Right (Clip clip))
      & ireturn
    Nothing -> ireturn project

nextTimelineCommand ::
     (UserInterface m, IxMonadIO m, HasType n (State m 'TimelineMode) r)
  => Name n
  -> m r r (Maybe TimelineCommand)
nextTimelineCommand =
  nextCommandOrBeep $
  [ ([KeyChar 'h'], Mapping (FocusCommand FocusLeft))
  , ([KeyChar 'j'], Mapping (FocusCommand FocusDown))
  , ([KeyChar 'k'], Mapping (FocusCommand FocusUp))
  , ([KeyChar 'l'], Mapping (FocusCommand FocusRight))
  , ( [KeyChar 'a']
    , SequencedMappings
        [ ([KeyChar 'c'], Mapping (AppendCommand AppendClip))
        , ([KeyChar 's'], Mapping (AppendCommand AppendSequence))
        , ([KeyChar 'g'], Mapping (AppendCommand AppendGap))
        ])
  , ([KeyChar 'q'], Mapping Exit)
  ]

timelineMode ::
     (UserInterface m, IxMonadIO m)
  => Name n
  -> Focus
  -> Project
  -> m (n .== State m 'TimelineMode) Empty ()
timelineMode gui focus' project = do
  updateTimeline gui project focus'
  nextTimelineCommand gui >>>= \case
    Just (FocusCommand e) ->
      case modifyFocus (project ^. topSequence) e focus' of
        Left _err -> do
          beep gui
          timelineMode gui focus' project
        Right newFocus -> timelineMode gui newFocus project
    Just (AppendCommand cmd) ->
      case (cmd, atFocus focus' (project ^. topSequence)) of
        (AppendSequence, Just (FocusedSequence _)) ->
          project
            & topSequence %~ appendAt' focus' (Left (Sequence () []))
            & timelineMode gui focus'
        (AppendClip, Just (FocusedVideoPart _)) ->
           selectClipAndAppend gui project focus' SVideo
          >>>= timelineMode gui focus'
        (AppendClip, Just (FocusedAudioPart _)) ->
          selectClipAndAppend gui project focus' SAudio
          >>>= timelineMode gui focus'
        (AppendGap, Just _) ->
          project
            & topSequence %~ appendAt' focus' (Right (Gap () 10))
            & timelineMode gui focus'
        (c, Just f) -> do
          let ct = case f of
                FocusedSequence{} -> "sequence"
                FocusedVideoPart{} -> "video track"
                FocusedAudioPart{} -> "audio track"
          iliftIO (putStrLn ("Cannot perform " <> show c <> " when focused at " <> ct))
          timelineMode gui focus' project
        (_, Nothing) -> do
          iliftIO (putStrLn "Warning: focus is invalid.")
          timelineMode gui focus' project
    Just Exit -> exit gui
    Nothing -> do
      beep gui
      timelineMode gui focus' project
  where

fastcut :: (IxMonadIO m) => UserInterface m => Project -> m Empty Empty ()
fastcut project = do
  start #gui project initialFocus
  timelineMode #gui initialFocus project
  where
    initialFocus = SubFocus 0 SequenceFocus
