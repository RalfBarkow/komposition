{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE OverloadedLabels           #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RebindableSyntax           #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

-- | A declarative GTK implementation of the 'UserInterface' protocol.
module Komposition.UserInterface.GtkInterface
  ( runGtkUserInterface
  )
where

import           Komposition.Prelude                                      hiding (state)
import qualified Prelude

import           Control.Monad                                            (void)
import           Control.Monad.Indexed                                    ()
import           Control.Monad.Indexed.Trans
import           Control.Monad.Reader
import           Data.Row.Records                                         (Empty)
import           Data.String
import qualified Data.Text                                                as Text
import           Data.Time.Clock                                          (diffTimeToPicoseconds)
import qualified GI.Gdk                                                   as Gdk
import qualified GI.GLib.Constants                                        as GLib
import qualified GI.Gst                                                   as Gst
import           GI.Gtk                                                   (AttrOp (..))
import qualified GI.Gtk                                                   as Gtk
import qualified GI.Gtk.Declarative                                       as Declarative
import qualified GI.Gtk.Declarative.Bin                                   as Declarative
import           Motor.FSM                                                hiding
                                                                           ((:=))
import qualified Motor.FSM                                                as FSM
import           Pipes
import           Pipes.Safe                                               (runSafeT,
                                                                           tryP)
import           Text.Printf

import           Control.Monad.Indexed.IO
import           Komposition.Progress
import           Komposition.UserInterface
import           Komposition.UserInterface.GtkInterface.EventListener

import qualified Komposition.UserInterface.GtkInterface.HelpView          as View
import qualified Komposition.UserInterface.GtkInterface.ImportView        as View
import qualified Komposition.UserInterface.GtkInterface.LibraryView       as View
import qualified Komposition.UserInterface.GtkInterface.TimelineView      as View
import qualified Komposition.UserInterface.GtkInterface.WelcomeScreenView as View

-- initializeWindow :: Typeable mode => Env -> Declarative.Widget (Event mode) -> IO Gtk.Window
-- initializeWindow Env {cssPath, screen} obj =
--   runUI $ do
--     window' <- Gtk.windowNew Gtk.WindowTypeToplevel
--     Gtk.windowSetTitle window' "Komposition"
--     void $ Gtk.onWidgetDestroy window' Gtk.mainQuit
--     cssProviderVar <- newMVar Nothing
--     reloadCssProvider cssProviderVar
--     void $
--       window' `Gtk.onWidgetKeyPressEvent` \eventKey -> do
--         keyVal <- Gdk.getEventKeyKeyval eventKey
--         case keyVal of
--           Gdk.KEY_F5 -> reloadCssProvider cssProviderVar
--           _          -> return ()
--         return False
--     windowStyle <- Gtk.widgetGetStyleContext window'
--     Gtk.styleContextAddClass windowStyle "komposition"
--     Gtk.containerAdd window' =<< Gtk.toWidget =<< Declarative.create obj
--     Gtk.widgetShowAll window'
--     return window'
--   where
--     cssPriority = fromIntegral Gtk.STYLE_PROVIDER_PRIORITY_USER
--     reloadCssProvider var =
--       void . forkIO $ do
--         cssProvider <-
--           runUI $ do
--             p <- Gtk.cssProviderNew
--             flip catch (\(e :: SomeException) -> print e) $ do
--               Gtk.cssProviderLoadFromPath p (Text.pack cssPath)
--               Gtk.styleContextAddProviderForScreen screen p cssPriority
--             return p
--         tryTakeMVar var >>= \case
--           Just (Just p) ->
--             runUI (Gtk.styleContextRemoveProviderForScreen screen p)
--           _ -> return ()
--         putMVar var (Just cssProvider)

data Env = Env { cssPath :: FilePath, screen :: Gdk.Screen }

newtype GtkUserInterface m i o a = GtkUserInterface
  (FSM m i o a) deriving (IxFunctor, IxPointed, IxApplicative, IxMonad, MonadFSM, IxMonadTrans)

runGtkUserInterface' :: Monad m => GtkUserInterface m Empty Empty a -> m a
runGtkUserInterface' (GtkUserInterface a) = FSM.runFSM a

instance MonadIO m => IxMonadIO (GtkUserInterface m) where
  iliftIO = ilift . liftIO

deriving instance Monad m => Functor (GtkUserInterface m i i)
deriving instance Monad m => Applicative (GtkUserInterface m i i)
deriving instance Monad m => Monad (GtkUserInterface m i i)

data GtkWindow event = GtkWindow
  { markup       :: GtkWindowMarkup event
  , gtkWidget    :: Gtk.Window
  , windowEvents :: EventListener event
  }

data GtkWindowMarkup event where
   GtkWindowMarkup
    :: Declarative.BinChild Gtk.Window Declarative.Widget
    => Declarative.Bin Gtk.Window Declarative.Widget event
    -> GtkWindowMarkup event

unGtkWindowMarkup
  :: GtkWindowMarkup event
  -> Declarative.Bin Gtk.Window Declarative.Widget event
unGtkWindowMarkup (GtkWindowMarkup decl) = decl

asGtkWindow :: GtkWindow event -> IO Gtk.Window
asGtkWindow (GtkWindow _ w _) = Gtk.unsafeCastTo Gtk.Window w

instance (MonadIO m, MonadReader Env m) => WindowUserInterface (GtkUserInterface m) where
  type Window (GtkUserInterface m) = GtkWindow
  type WindowMarkup (GtkUserInterface m) = GtkWindowMarkup

  newWindow name markup'@(GtkWindowMarkup decl) keyMap =
    ilift ask >>>= \env ->
      (FSM.new name =<<< irunUI (do
        w <- Declarative.create decl
        win <- Gtk.unsafeCastTo Gtk.Window w
        -- Set up CSS provider
        loadCss env win
        -- Set up event listeners
        viewEvents <- subscribeToDeclarativeWidget decl w
        keyEvents <- applyKeyMap keyMap =<< subscribeKeyEvents w
        allEvents <- mergeEvents viewEvents keyEvents
        -- And show recursively as this is a new widget tree
        #showAll w
        return (GtkWindow markup' win allEvents)))

  patchWindow name (GtkWindowMarkup decl) =
    FSM.get name >>>= \w ->
      FSM.enter name =<<<
        case Declarative.patch (unGtkWindowMarkup (markup w)) decl of
          Declarative.Modify f -> irunUI $ do
            f =<< Gtk.toWidget (gtkWidget w)
            return w
          Declarative.Replace create' -> irunUI $ do
            Gtk.widgetDestroy (gtkWidget w)
            gtkWidget' <- create'
            gtkWindow' <- Gtk.unsafeCastTo Gtk.Window gtkWidget'
            viewEvents <- subscribeToDeclarativeWidget decl gtkWidget'
            return (GtkWindow (GtkWindowMarkup decl) gtkWindow' viewEvents)
          Declarative.Keep -> return w

  destroyWindow name =
    FSM.get name >>>= \w ->
      irunUI (Gtk.widgetDestroy (gtkWidget w)) >>> FSM.delete name

  withNewWindow name markup keymap action =
    call $
      newWindow name markup keymap
      >>> action
      >>>= \x ->
        destroyWindow name
        >>> ireturn x

  nextEvent name =
    FSM.get name >>>= (iliftIO . readEvent . windowEvents)

  nextEventOrTimeout n t = FSM.get n >>>= \w -> iliftIO $ do
    let microseconds = round (fromIntegral (diffTimeToPicoseconds t) / 1000000 :: Double)
    race
      (threadDelay microseconds)
      (readEvent (windowEvents w)) >>= \case
        Left () -> return Nothing
        Right e -> return (Just e)

  setTransientFor childName parentName =
    FSM.get childName >>>= \child' ->
      FSM.get parentName >>>= \parent -> irunUI $ do
        childWindow <- asGtkWindow child'
        parentWindow <- asGtkWindow parent
        Gtk.windowSetTransientFor childWindow (Just parentWindow)

  chooseFile n mode title defaultDir =
    FSM.get n >>>= \w -> iliftIO $ do
    response <- newEmptyMVar
    runUI $ do

      d <- Gtk.new Gtk.FileChooserNative []
      chooser <- Gtk.toFileChooser d
      void (Gtk.fileChooserSetCurrentFolder chooser defaultDir)
      Gtk.fileChooserSetDoOverwriteConfirmation chooser True
      Gtk.fileChooserSetAction chooser (modeToAction mode)
      Gtk.nativeDialogSetTitle d title
      Gtk.nativeDialogSetTransientFor d (Just (gtkWidget w))
      Gtk.nativeDialogSetModal d True
      res <- Gtk.nativeDialogRun d
      case toEnum (fromIntegral res) of
        Gtk.ResponseTypeAccept -> Gtk.fileChooserGetFilename d >>= putMVar response
        Gtk.ResponseTypeCancel -> putMVar response Nothing
        _ -> putMVar response Nothing
      Gtk.nativeDialogDestroy d
    takeMVar response
    where
      modeToAction = \case
        Open File ->  Gtk.FileChooserActionOpen
        Save File -> Gtk.FileChooserActionSave
        Open Directory ->  Gtk.FileChooserActionSelectFolder
        Save Directory -> Gtk.FileChooserActionCreateFolder

  progressBar n title producer =
    FSM.get n >>>= \w -> iliftIO $ do
      result <- newEmptyMVar
      runUI $ do
        d <-
          Gtk.new
            Gtk.Dialog
            [ #title := title
            , #transientFor := gtkWidget w
            , #modal := True
            ]
        content      <- Gtk.dialogGetContentArea d
        contentStyle <- Gtk.widgetGetStyleContext content
        Gtk.styleContextAddClass contentStyle "progress-bar"

        pb <- Gtk.new Gtk.ProgressBar [#showText := True]
        msgLabel <- Gtk.new Gtk.Label []
        let updateProgress = forever $ do
              ProgressUpdate msg fraction <- await
              liftIO . runUI $ do
                Gtk.set pb [#fraction := fraction, #text := printFractionAsPercent fraction ]
                Gtk.set msgLabel [#label := msg]
        #packStart content pb False False 10
        #packStart content msgLabel False False 10
        Gtk.set content [#widthRequest := 300]
        #showAll d

        a <- async $ do
          r <- runSafeT (runEffect (tryP (producer >-> updateProgress)))
          void (tryPutMVar result (Just r))
          runUI $ #destroy d

        void . Gtk.on d #destroy $ do
          cancel a
          void (tryPutMVar result Nothing)

      readMVar result

  previewStream = undefined

  beep _ = iliftIO (runUI Gdk.beep)

instance UserInterfaceMarkup GtkWindowMarkup where
  welcomeView = GtkWindowMarkup View.welcomeScreenView
  timelineView = GtkWindowMarkup . View.timelineView
  libraryView = GtkWindowMarkup . View.libraryView
  importView = GtkWindowMarkup . View.importView
  -- dialogView = GtkWindowMarkup . View.dialogView
  helpView = GtkWindowMarkup . View.helpView

runGtkUserInterface
  :: FilePath -> GtkUserInterface (ReaderT Env IO) Empty Empty () -> IO ()
runGtkUserInterface cssPath ui = do
  void $ Gst.init Nothing
  void $ Gtk.init Nothing
  screen  <- maybe (fail "No screen?!") return =<< Gdk.screenGetDefault

  appLoop <- async $ do
    runReaderT (runGtkUserInterface' ui) Env {..}
    Gtk.mainQuit
  Gtk.main
  cancel appLoop

printFractionAsPercent :: Double -> Text
printFractionAsPercent fraction =
  toS (printf "%.0f%%" (fraction * 100) :: Prelude.String)

runUI :: IO a -> IO a
runUI f = do
  ret <- newEmptyMVar
  void . Gdk.threadsAddIdle GLib.PRIORITY_DEFAULT $ do
    f >>= putMVar ret
    return False
  takeMVar ret

irunUI :: IxMonadIO m => IO a -> m i i a
irunUI = iliftIO . runUI

loadCss :: Env -> Gtk.Window -> IO ()
loadCss Env { cssPath, screen } window' = do
  cssProviderVar <- newMVar Nothing
  reloadCssProvider cssProviderVar
  void $ window' `Gtk.onWidgetKeyPressEvent` \eventKey -> do
    keyVal <- Gdk.getEventKeyKeyval eventKey
    case keyVal of
      Gdk.KEY_F5 -> reloadCssProvider cssProviderVar
      _          -> return ()
    return False
  where
    cssPriority = fromIntegral Gtk.STYLE_PROVIDER_PRIORITY_USER
    reloadCssProvider var = void . forkIO $ do
      cssProvider <- runUI $ do
        p <- Gtk.cssProviderNew
        flip catch (\(e :: SomeException) -> print e) $ do
          Gtk.cssProviderLoadFromPath p (Text.pack cssPath)
          Gtk.styleContextAddProviderForScreen screen p cssPriority
        return p
      tryTakeMVar var >>= \case
        Just (Just p) ->
          runUI (Gtk.styleContextRemoveProviderForScreen screen p)
        _ -> return ()
      putMVar var (Just cssProvider)
