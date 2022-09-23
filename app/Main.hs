{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MonoLocalBinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use =<<" #-}

module Main (main) where

import Control.Applicative ((<**>))
import Control.Arrow ((>>>))
import Control.Lens ((^.))
import Control.Monad (join)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Short as SBS
import Data.Char (toLower)
import Data.Compact (compact, getCompact)
import Data.Compact.Streaming
import Data.Function ((&))
import Data.Generics.Labels ()
import GHC.Generics (Generic)
import Network.Simple.TCP (HostPreference (..), connect, serve)
import Network.Socket (PortNumber)
import Network.Streaming
import qualified Options.Applicative as Opts
import qualified Streaming.ByteString as Q
import qualified Streaming.Prelude as S
import System.IO (BufferMode (..), hSetBuffering, stdout)
import UnliftIO.Async
import UnliftIO.Exception

newtype CommonCfg = CommonCfg {checkType :: Bool}
  deriving (Show, Eq, Ord, Generic)

data ServerCfg = ServerCfg {commonCfg :: !CommonCfg, port :: !PortNumber}
  deriving (Show, Eq, Ord, Generic)

data ClientCfg = ClientCfg
  { commonCfg :: !CommonCfg
  , serverAddress :: !String
  , serverPort :: !PortNumber
  }
  deriving (Show, Eq, Ord, Generic)

data Mode = Server ServerCfg | Client ClientCfg
  deriving (Show, Eq, Ord, Generic)

data Command = Hello | Message SBS.ShortByteString | Bye
  deriving (Show, Eq, Ord, Generic)

data Response = Welcome | WhatDoYouMean SBS.ShortByteString | MissYou
  deriving (Show, Eq, Ord, Generic)

commonCfgP :: Opts.Parser CommonCfg
commonCfgP = do
  checkType <- not <$> Opts.switch (Opts.long "no-typecheck" <> Opts.help "Disables type check")
  pure CommonCfg {..}

clientCfgP :: Opts.ParserInfo ClientCfg
clientCfgP =
  Opts.info (p <**> Opts.helper) $ Opts.progDesc "Client"
  where
    p = do
      commonCfg <- commonCfgP
      serverAddress <-
        Opts.strArgument $
          Opts.metavar "ADDR"
            <> Opts.help "The address of the server"
            <> Opts.showDefault
            <> Opts.value "127.0.0.1"
      serverPort <-
        Opts.argument Opts.auto $
          Opts.metavar "PORT"
            <> Opts.help "The address of the server"
            <> Opts.showDefault
            <> Opts.value defaultPort
      pure ClientCfg {..}

serverCfgP :: Opts.ParserInfo ServerCfg
serverCfgP =
  Opts.info (p <**> Opts.helper) $ Opts.progDesc "Server"
  where
    p = do
      commonCfg <- commonCfgP
      port <-
        Opts.argument Opts.auto $
          Opts.metavar "PORT"
            <> Opts.help "The port number to bind on"
            <> Opts.showDefault
            <> Opts.value defaultPort
      pure ServerCfg {..}

defaultPort :: PortNumber
defaultPort = 5192

modeP :: Opts.ParserInfo Mode
modeP =
  Opts.info
    ( Opts.helper
        <*> Opts.hsubparser
          ( mconcat
              [ Opts.command "server" $ Server <$> serverCfgP
              , Opts.command "client" $ Client <$> clientCfgP
              ]
          )
    )
    $ Opts.progDesc "Simple server-cleint echoing example using compact normal form RPC"

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  Opts.execParser modeP >>= \case
    Server sc -> runServer sc
    Client cc -> runClient cc

runClient :: ClientCfg -> IO ()
runClient cfg = do
  putStrLn "Client Mode."
  connect (cfg ^. #serverAddress) (show $ cfg ^. #serverPort) $ \(conn, addr) -> do
    loop conn addr
  where
    loop conn addr = do
      putStrLn $ "Connected to: " <> show addr
      logging conn `concurrently_` sending conn
    sending conn =
      (S.yield Hello >> S.map parseCommand S.stdinLn)
        & S.break (== Bye)
        & fmap (S.take 1)
        & join
        & S.mapM compact
        & encodes
        & toSocket conn
    logging =
      fromSocket
        >>> decoder
        >>> S.map getCompact
        >>> S.mapM_ (putStrLn . ("<<< " <>) . show)

    encodes = S.chain (print . getCompact) >>> S.subst encoder >>> Q.concat
    encoder
      | cfg ^. #commonCfg . #checkType = encodeCompact @Command
      | otherwise = unsafeEncodeCompactWithoutType
    decoder
      | cfg ^. #commonCfg . #checkType = decodeCompacts @Response
      | otherwise = unsafeDecodeCompactsWithoutTypecheck

parseCommand :: String -> Command
parseCommand inp@('/' : rest) =
  case map toLower rest of
    "bye" -> Bye
    "hello" -> Hello
    _ -> Message $ SBS.toShort $ BS.pack inp
parseCommand cmd = Message $ SBS.toShort $ BS.pack cmd

runServer :: ServerCfg -> IO ()
runServer cfg = do
  putStrLn "Server Mode"
  serve (Host "127.0.0.1") (show $ cfg ^. #port) $ \(sock, addr) -> do
    putStrLn $ "New client: " <> show addr
    fromSocket sock
      & decoder
      & S.map getCompact
      & S.chain (putStrLn . ((show addr <> ": ") <>) . show)
      & S.break (== Bye)
      & fmap (S.take 1)
      & join
      & S.map \case
        Hello -> Welcome
        Message bs -> WhatDoYouMean bs
        Bye -> MissYou
      & S.mapM compact
      & encodes
      & toSocket sock
  where
    encodes = S.subst encoder >>> Q.concat
    encoder
      | cfg ^. #commonCfg . #checkType = encodeCompact @Response
      | otherwise = unsafeEncodeCompactWithoutType
    decoder
      | cfg ^. #commonCfg . #checkType = decodeCompacts @Command
      | otherwise = unsafeDecodeCompactsWithoutTypecheck
