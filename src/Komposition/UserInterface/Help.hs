{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedLabels      #-}
{-# LANGUAGE OverloadedLists       #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TypeOperators         #-}
module Komposition.UserInterface.Help where

import           Komposition.Prelude

import           Data.Row.Records
import           Motor.FSM

import           Komposition.KeyMap
import           Komposition.UserInterface
import           Komposition.UserInterface.WindowUserInterface

data HelpEvent
  = HelpClosed

class HelpView markup where
  helpView :: [ModeKeyMap] -> markup Modal HelpEvent

help
  :: ( IxMonad m
     , HelpView (WindowMarkup m)
     , WindowUserInterface m
     , HasType parent (Window m parentWindow parentEvent) r
     )
  => Name parent
  -> [ModeKeyMap]
  -> m r r (Maybe c)
help parent keyMap =
  withNewModalWindow parent #help (helpView keyMap) helpKeyMap
    $    nextEvent #help
    >>>= \case
           HelpClosed -> ireturn Nothing
  where
    helpKeyMap :: KeyMap HelpEvent
    helpKeyMap = KeyMap
      [([KeyChar 'q'], Mapping HelpClosed), ([KeyEscape], Mapping HelpClosed)]
