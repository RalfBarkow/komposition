{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE ExplicitForAll        #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedLabels      #-}
{-# LANGUAGE OverloadedLists       #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE RebindableSyntax      #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
module FastCut.Application where

import           FastCut.Prelude            hiding (State, cancel, (>>), (>>=))

import           Control.Lens
import           Data.Row.Records           hiding (map)
import           Data.String                (fromString)
import           GHC.Exts                   (fromListN)
import           Motor.FSM
import           Text.Printf

import           Control.Monad.Indexed.IO
import           FastCut.Composition
import           FastCut.Composition.Insert
import           FastCut.Focus
import           FastCut.KeyMap
import           FastCut.Library
import           FastCut.MediaType
import           FastCut.Project
import           FastCut.UserInterface

(>>) :: IxMonad m => m i j a -> m j k b -> m i k b
(>>) = (>>>)

(>>=) :: IxMonad m => m i j a -> (a -> m j k b) -> m i k b
(>>=) = (>>>=)

keymaps :: SMode m -> KeyMap (Event m)
keymaps =
  fmap CommandKeyMappedEvent .
  \case
    STimelineMode ->
      [ ([KeyChar 'h'], Mapping (FocusCommand FocusLeft))
      , ([KeyChar 'j'], Mapping (FocusCommand FocusDown))
      , ([KeyChar 'k'], Mapping (FocusCommand FocusUp))
      , ([KeyChar 'l'], Mapping (FocusCommand FocusRight))
      , ([KeyChar 'i'], Mapping Import)
      , ( [KeyChar 'a']
        , SequencedMappings
            [ ([KeyChar 'c'], Mapping (AppendCommand AppendClip))
            , ([KeyChar 'g'], Mapping (AppendCommand AppendGap))
            , ([KeyChar 'p'], Mapping (AppendCommand AppendComposition))
            ])
      , ([KeyChar 'q'], Mapping Exit)
      ]
    SLibraryMode ->
      [ ([KeyChar 'j'], Mapping LibraryDown)
      , ([KeyChar 'k'], Mapping LibraryUp)
      , ([KeyChar 'q'], Mapping Cancel)
      , ([KeyEnter], Mapping LibrarySelect)
      ]
    SImportMode ->
      [ ([KeyChar 'q'], Mapping Cancel)
      ]

selectAssetFromList ::
     (UserInterface m, IxMonadIO m, Modify n (State m LibraryMode) r ~ r)
  => Name n
  -> [Asset mt]
  -> Int
  -> Actions m '[ n := Remain (State m LibraryMode)] r (Maybe (Asset mt))
selectAssetFromList gui assets n = do
  updateLibrary gui assets n
  nextEvent gui >>>= \case
    CommandKeyMappedEvent Cancel -> ireturn Nothing
    CommandKeyMappedEvent LibrarySelect -> ireturn (assets ^? element n)
    CommandKeyMappedEvent LibraryUp
      | n > 0 -> selectAssetFromList gui assets (pred n)
      | otherwise -> continue
    CommandKeyMappedEvent LibraryDown
      | n < length assets - 1 -> selectAssetFromList gui assets (succ n)
      | otherwise -> continue
  where
    continue = selectAssetFromList gui assets n

-- | Convenient type for actions that transition from one mode
-- into another mode, doing some user interactions, and returning back
-- to the first mode with a value.
type ThroughMode base through n a
   = forall m i o lm tm.
   ( UserInterface m
     , IxMonadIO m
     , HasType n tm i
     , HasType n tm o
     , (Modify n lm i .! n) ~ lm
     , Modify n tm (Modify n lm i) ~ o
     , Modify n lm (Modify n lm i) ~ Modify n lm i
     , lm ~ State m through
     , tm ~ State m base
     )
   => m i o a

selectAsset ::
  Name n
  -> Project
  -> Focus ft
  -> SMediaType mt
  -> ThroughMode TimelineMode LibraryMode n (Maybe (Asset mt))
selectAsset gui project focus' mediaType =
  case mediaType of
    SVideo -> do
      enterLibrary gui (project ^. library . videoAssets) 0
      asset' <- selectAssetFromList gui (project ^. library . videoAssets) 0
      returnToTimeline gui project focus'
      ireturn asset'
    SAudio -> do
      enterLibrary gui (project ^. library . audioAssets) 0
      asset' <- selectAssetFromList gui (project ^. library . audioAssets) 0
      returnToTimeline gui project focus'
      ireturn asset'

selectAssetAndAppend ::
  Name n
  -> Project
  -> Focus ft
  -> SMediaType mt
  -> ThroughMode TimelineMode LibraryMode n Project
selectAssetAndAppend gui project focus' mediaType =
  selectAsset gui project focus' mediaType >>= \case
    Just asset' ->
      project
      & timeline %~ insert_ focus' (insertionOf asset') RightOf
      & ireturn
    Nothing -> ireturn project
  where
    insertionOf a = case mediaType of
      SVideo -> InsertVideoPart (Clip () a)
      SAudio -> InsertAudioPart (Clip () a)

type SplitScenes = Bool

data ImportFileForm = ImportFileForm
  { selectedFile :: Maybe FilePath
  , splitScenes  :: SplitScenes
  }

importFile ::
  Name n
  -> Project
  -> Focus ft
  -> ThroughMode TimelineMode ImportMode n (Maybe (FilePath, SplitScenes))
importFile gui project focus' = do
  enterImport gui
  f <-
    awaitFileToImport
      ImportFileForm {selectedFile = Nothing, splitScenes = False}
  returnToTimeline gui project focus'
  ireturn f
  where
    awaitFileToImport mf = do
      cmd <- nextEvent gui
      case (cmd, mf) of
        (CommandKeyMappedEvent Cancel, _) -> ireturn Nothing
        (ImportClicked, ImportFileForm {selectedFile = Just file, ..}) ->
          ireturn (Just (file, splitScenes))
        (ImportClicked, form) -> awaitFileToImport form
        (ImportFileSelected file, form) ->
          awaitFileToImport (form {selectedFile = Just file})

prettyFocusedAt :: FocusedAt a -> Text
prettyFocusedAt =
  \case
    FocusedSequence {} -> "sequence"
    FocusedParallel {} -> "parallel"
    FocusedVideoPart {} -> "video track"
    FocusedAudioPart {} -> "audio track"

append ::
     (UserInterface m, IxMonadIO m)
  => Name n
  -> Project
  -> Focus ft
  -> AppendCommand
  -> m (n .== State m 'TimelineMode) Empty ()
append gui project focus' cmd =
  case (cmd, atFocus focus' (project ^. timeline)) of
    (AppendComposition, Just (FocusedSequence _)) ->
      selectAsset gui project focus' SVideo >>= \case
        Just asset' ->
          project & timeline %~
          insert_
            focus'
            (InsertParallel (Parallel () [Clip () asset'] []))
            RightOf &
          timelineMode gui focus'
        Nothing -> continue
    (AppendClip, Just (FocusedVideoPart _)) ->
      selectAssetAndAppend gui project focus' SVideo >>>=
      timelineMode gui focus'
    (AppendClip, Just (FocusedAudioPart _)) ->
      selectAssetAndAppend gui project focus' SAudio >>>=
      timelineMode gui focus'
    (AppendGap, Just _) ->
      project & timeline %~ insert_ focus' (InsertVideoPart (Gap () 10)) RightOf &
      timelineMode gui focus'
    (c, Just f) -> do
      iliftIO
        (putStrLn
           ("Cannot perform " <> show c <> " when focused at " <>
            prettyFocusedAt f))
      continue
    (_, Nothing) -> do
      iliftIO (putStrLn ("Warning: focus is invalid." :: Text))
      continue
  where
    continue = timelineMode gui focus' project

data Confirmation
  = Yes
  | No
  deriving (Show, Eq, Enum)

instance DialogChoice Confirmation where
  toButtonLabel = \case
    Yes -> "Yes"
    No -> "No"

timelineMode ::
     (UserInterface m, IxMonadIO m)
  => Name n
  -> Focus ft
  -> Project
  -> m (n .== State m 'TimelineMode) Empty ()
timelineMode gui focus' project = do
  updateTimeline gui project focus'
  nextEvent gui >>>= \case
    CommandKeyMappedEvent (FocusCommand cmd) ->
      case modifyFocus (project ^. timeline) cmd focus' of
        Left err -> do
          printUnexpectedFocusError err cmd
          continue
        Right newFocus -> timelineMode gui newFocus project
    CommandKeyMappedEvent (AppendCommand cmd) -> append gui project focus' cmd
    CommandKeyMappedEvent Import ->
      importFile gui project focus' >>>= \case
        Just (file, splitScenes) -> do
          iliftIO (putStrLn ("Importing file '" <> file <> "' with split scenes: " <>  show splitScenes))
          continue
        Nothing -> continue
    CommandKeyMappedEvent Cancel -> continue
    CommandKeyMappedEvent Exit ->
      dialog gui "Confirm Exit" "Are you sure you want to exit?" [No, Yes] >>>= \case
        Just Yes -> exit gui
        Just No -> continue
        Nothing -> continue
  where
    continue = timelineMode gui focus' project
    printUnexpectedFocusError err cmd =
      case err of
        UnhandledFocusModification {} ->
          iliftIO
            (printf
               "Error: could not handle focus modification %s\n"
               (show cmd :: Text))
        _ -> ireturn ()

fastcut :: (IxMonadIO m) => UserInterface m => Project -> m Empty Empty ()
fastcut project = do
  start #gui keymaps project initialFocus
  timelineMode #gui initialFocus project
  where
    initialFocus = SequenceFocus 0 Nothing
