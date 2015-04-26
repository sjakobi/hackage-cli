#!/usr/bin/env runghc

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Main where

import qualified Blaze.ByteString.Builder as Builder
import           Control.DeepSeq
import           Control.Exception
import           Control.Lens
import           Control.Monad
import           Control.Monad.State.Strict
import           Data.Bits
import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import           Data.Char (isSpace, toLower)
import           Data.List.Split
import           Data.Maybe
import           Data.Monoid
import           Data.Version (showVersion)
import           Network.Http.Client
import           Network.NetRc
import           Numeric.Natural (Natural)
import           OpenSSL (withOpenSSL)
import           Options.Applicative as OA
import           System.Directory
import qualified System.IO.Streams as Streams
import           Text.HTML.TagSoup

import qualified Distribution.PackageDescription.Parse as C
import qualified Distribution.Verbosity as C
import qualified Distribution.PackageDescription as C
import qualified Distribution.Package as C

import qualified Paths_hackage_cli

type PkgName = ByteString
type PkgVer  = ByteString
type PkgRev  = Word

type HIO = StateT HConn IO

data HConn = HConn
    { _hcMkConn :: IO Connection
    , _hcConn   :: Maybe Connection
    , _hcReqCnt :: Natural -- ^ requests submitted on current 'Connection'
    , _hcRspCnt :: Natural -- ^ responses read from current 'Connection'
    }

makeLenses ''HConn

-- | Requests that can be issued in current connection before exhausting the 50-req/conn server limit
hcReqLeft :: Getter HConn Natural -- (Natural -> f Natural) -> HConn -> f HConn
hcReqLeft g = hcReqCnt (g . f)
  where
    f n | n > lim   = 0
        | otherwise = lim - n
    lim = 50

setUA :: RequestBuilder ()
setUA = setHeader "User-Agent" uaStr
  where
    uaStr = "hackage-cli/" <> (BS8.pack $ showVersion Paths_hackage_cli.version)

hackageSendGET :: ByteString -> ByteString -> HIO ()
hackageSendGET p a = do
    q1 <- liftIO $ buildRequest $ do
        http GET p
        setUA
        setAccept a

    lft <- use hcReqLeft
    unless (lft > 0) $
        fail "hackageSendGET: request budget exhausted for current connection"

    c <- openHConn
    liftIO $ sendRequest c q1 emptyBody
    hcReqCnt += 1

hackageRecvResp :: HIO ByteString
hackageRecvResp = do
    c <- openHConn
    reqCnt <- use hcReqCnt
    rspCnt <- use hcRspCnt
    unless (reqCnt > rspCnt) $
        fail "hackageRecvResp: not response available to receive"

    resp <- liftIO $ receiveResponse c concatHandler'
    hcRspCnt += 1

    return resp

data DryWetRun = DryRun | WetRun

hackagePostCabal :: (ByteString,ByteString) -> (PkgName,PkgVer) -> ByteString -> DryWetRun -> HIO ByteString
hackagePostCabal cred (pkgn,pkgv) rawcab dry = do
    when (boundary `BS.isInfixOf` rawcab) $ fail "WTF... cabal file contains boundary-pattern"

    q1 <- liftIO $ buildRequest $ do
        http POST urlpath
        setUA
        uncurry setAuthorizationBasic cred
        setAccept "application/json" -- wishful thinking
        setContentType ("multipart/form-data; boundary="<>boundary)

    c <- reOpenHConn

    liftIO $ sendRequest c q1 (bsBody body)

    resp <- liftIO $ try (receiveResponse c concatHandler)
    closeHConn

    case resp of
        Right bs -> do
            -- liftIO $ BS.writeFile "raw.out" bs
            return (BS8.unlines [ h2 <> ":\n" <> renderTags ts | (h2, ts) <- scrape200 bs ])
        Left (HttpClientError _code bs) -> do
            -- Hackage currently timeouts w/ 503 guru meditation errors,
            -- which usually means that the transaction has succeeded
            -- liftIO $ BS.writeFile "raw.out" bs
            return bs
  where
    urlpath = mconcat [ "/package/", pkgn, "-", pkgv, "/", pkgn, ".cabal/edit" ]

    bsBody :: ByteString -> Streams.OutputStream Builder.Builder -> IO ()
    bsBody bs o = Streams.write (Just (Builder.fromByteString bs)) o

    isDry DryRun = True
    isDry WetRun = False

    body = mconcat
           [ "--", boundary, "\r\n"
           , "Content-Disposition: form-data; name=", "\"", if isDry dry then "review" else "publish", "\"", "\r\n"
           , "\r\n"
           , if isDry dry then "Review changes" else "Publish new revision", "\r\n"
           , "--", boundary, "\r\n"
           , "Content-Disposition: form-data; name=\"cabalfile\"", "\r\n"
           , "\r\n"
           , rawcab, "\r\n"
           , "--", boundary, "--", "\r\n"
           ]

    boundary = "4d5bb1565a084d78868ff0178bdf4f61"

    -- scrape200 :: ByteString -> (Bool, h2parts)
    scrape200 html = h2parts
      where
        tags = parseTags (html :: ByteString)

        h2parts = [ (t,map cleanText $ takeWhile (/= TagClose "form") xs)
                  | (TagOpen "h2" _: TagText t: TagClose "h2": xs) <- partitions (== TagOpen "h2" []) tags
                  , t /= "Advice on adjusting version constraints" ]

        cleanText (TagText t)
          | t' == "", '\n' `BS8.elem` t = TagText "\n"
          | otherwise               = TagText t
          where
            t' = fst . BS8.spanEnd (=='\n') . BS8.dropWhile (=='\n') $ t
        cleanText x = x

fetchVersions :: PkgName -> HIO [PkgVer]
fetchVersions pkgn = do
    hackageSendGET ("/package/" <> pkgn) "text/html"
    resp <- hackageRecvResp
    liftIO $ evaluate $ scrapeVersions resp

fetchCabalFile :: PkgName -> PkgVer -> HIO ByteString
fetchCabalFile pkgn pkgv = do
    hackageSendGET urlpath "text/plain"
    hackageRecvResp
  where
    urlpath = mconcat ["/package/", pkgn, "-", pkgv, "/", pkgn, ".cabal"]

fetchCabalFiles :: PkgName -> [PkgVer] -> HIO [(PkgVer,ByteString)]
fetchCabalFiles pkgn pkgvs0 = do
    -- HTTP pipelining
    tmp <- go [] pkgvs0
    return (concat . reverse $ tmp)
  where
    go acc [] = pure acc
    go acc vs0 = do
        (_,lft) <- getHConn
        let (vs,vs') = nsplitAt lft vs0
        when (null vs) $ fail "fetchCabalFiles: the impossible happened"

        -- HTTP-pipeline requests; compensates a bit for SSL-induced latency
        mcabs <- forM (mkPipeline 4 vs) $ \case
            Left pkgv -> do -- request
                let urlpath = mconcat ["/package/", pkgn, "-", pkgv, "/", pkgn, ".cabal"]
                -- liftIO $ putStrLn $ show urlpath
                hackageSendGET urlpath "text/plain"
                return Nothing

            Right pkgv -> do -- response
                -- liftIO $ putStrLn ("read " ++ show pkgv)
                resp <- hackageRecvResp
                return $ Just (pkgv, resp)

        go (catMaybes mcabs : acc) vs'

-- Left means request; Right means receive
mkPipeline :: Natural -> [a] -> [Either a a]
mkPipeline maxQ vs
  | not postCond = error "mkPipeline: internal error" -- paranoia
  | otherwise    = concat [ map Left rqs1
                          , concat [ [Left v1, Right v2] | (v1,v2) <- zip rqs2 res2 ]
                          , map Right res3
                          ]
  where
    (rqs1,rqs2) = nsplitAt n vs
    (res2,res3) = nsplitAt m vs

    postCond = sameLen rqs2 res2 && sameLen rqs1 res3

    l = nlength vs
    n = min l maxQ
    m = l-n

    sameLen [] []         = True
    sameLen (_:xs) (_:ys) = sameLen xs ys
    sameLen [] (_:_)      = False
    sameLen (_:_) []      = False

-- | Insert or replace existing "x-revision" line
--
-- NOTE: Supports only simplified (i.e. without the @{;}@-layout) Cabal file grammar
cabalEditXRev :: PkgRev -> ByteString -> ByteString
cabalEditXRev xrev oldcab = BS8.unlines ls'
  where
    ls = BS8.lines oldcab

    xrevLine = "x-revision: " <> BS8.pack (show xrev) <> (if isCRLF then "\r" else "")

    -- | Try to detect if line contains the given field.
    -- I.e. try to match  @<field-name-ci> WS* ':' ...@
    matchFieldCI :: ByteString -> ByteString -> Bool
    matchFieldCI fname line
      | ':' `BS8.elem` line = fname == BS8.map toLower fname'
      | otherwise = False
      where
        fname' = fst . BS8.spanEnd isSpace . BS8.takeWhile (/=':') $ line

    -- simple heuristic
    isCRLF = case ls of
        []     -> False
        ("":_) -> False
        (l1:_) -> BS8.last l1 == '\r'

    ls' = case break (matchFieldCI "x-revision") ls of
        (_,[]) -> ls'' -- x-rev not found; try to insert after version-field instead
        (xs,_:ys) -> xs++ xrevLine:ys

    ls'' = case break (matchFieldCI "version") ls of
        (_,[]) -> error "cabalEditXRev: unsupported cabal grammar; version field not found"
        (xs,v:ys) -> xs ++ v:xrevLine:ys

fetchAllCabalFiles :: PkgName -> HIO [(PkgVer,ByteString)]
fetchAllCabalFiles pkgn = do
    vs <- fetchVersions pkgn
    liftIO $ putStrLn ("Found " ++ show (length vs) ++ " package versions for " ++ show pkgn ++ ", downloading now...")
    fetchCabalFiles pkgn vs
    -- forM vs $ \v -> (,) v <$> fetchCabalFile c pkgn v

scrapeVersions :: ByteString -> [PkgVer]
scrapeVersions html = force vs
  where
    [vs] = mapMaybe getVerRow $ partitions (== TagOpen "tr" []) $ parseTags html

    getVerRow (TagOpen "tr" _ : TagOpen "th" _ : TagText "Versions" : TagClose "th" : TagOpen "td" _ : ts)
        | last ts == TagClose "tr" = Just (map go $ chunksOf 4 $ init $ init ts)
    getVerRow _ = Nothing

    go [TagOpen "a" _, TagText verStr, TagClose "a", TagText ", "] = verStr
    go [TagOpen "strong" _, TagText verStr, TagClose "strong"] = verStr
    go _ = error "unexpected HTML structure structure"

closeHConn :: HIO ()
closeHConn = do
    mhc <- use hcConn
    forM_ mhc $ \hc -> do
        liftIO $ closeConnection hc
        hcConn   .= Nothing

        reqCnt <- use hcReqCnt
        rspCnt <- use hcRspCnt
        unless (reqCnt == rspCnt) $
            liftIO $ putStrLn $ concat ["warning: req-cnt=", show reqCnt, " rsp-cnt=", show rspCnt]

        hcReqCnt .= 0
        hcRspCnt .= 0

openHConn :: HIO Connection
openHConn = do
    use hcConn >>= \case
        Just c -> return c
        Nothing -> do
            mkConn <- use hcMkConn
            c <- liftIO mkConn
            hcConn   .= Just c
            hcReqCnt .= 0 -- redundant
            hcRspCnt .= 0 -- redundant
            return c

reOpenHConn :: HIO Connection
reOpenHConn = closeHConn >> openHConn

getHConn :: HIO (Connection,Natural)
getHConn = do
    lft <- use hcReqLeft
    c <- if (lft > 0) then openHConn else reOpenHConn
    (,) c <$> use hcReqLeft

nlength :: [a] -> Natural
nlength = fromIntegral . length

nsplitAt :: Natural -> [a] -> ([a],[a])
nsplitAt n = splitAt i
  where
    i = fromMaybe (error "nsplitAt: overflow") $ toIntegralSized n

----------------------------------------------------------------------------
-- CLI Interface

data Options = Options
  { optVerbose :: !Bool
  , optHost    :: !Hostname
  , optCommand :: !Command
  } deriving Show

data PullCOptions = PullCOptions
  { optPCPkgName :: PkgName
  } deriving Show

data PushCOptions = PushCOptions
  { optPCIncrRev :: !Bool
  , optPCDry     :: !Bool
  , optPCFiles   :: [FilePath]
  } deriving Show

data Command
    = PullCabal !PullCOptions
    | PushCabal !PushCOptions
    deriving Show

optionsParserInfo :: ParserInfo Options
optionsParserInfo
    = info (helper <*> verOption <*> oParser)
           (fullDesc
            <> header "hackage-cli - CLI tool for Hackage"
            <> footer "\
              \ Each command has a sub-`--help` text. Hackage credentials are expected to be \
              \ stored in an `${HOME}/.netrc`-entry for the respective Hackage hostname. \
              \ E.g. \"machine hackage.haskell.org login MyUserName password TrustNo1\". \
              \ ")

  where
    bstr = BS8.pack <$> str

    pullcoParser = PullCabal . PullCOptions <$> OA.argument bstr (metavar "PKGNAME")
    pushcoParser = PushCabal <$> (PushCOptions
                                  <$> switch (long "incr-rev" <> help "increment x-revision field")
                                  <*> switch (long "dry"      <> help "upload in review-mode")
                                  <*> some (OA.argument str (metavar "CABALFILES...")))

    oParser
        = Options <$> switch (long "verbose" <> help "enable verbose output")
                  <*> option bstr (long "hostname"  <> metavar "HOSTNAME" <> value "hackage.haskell.org"
                                   <> help "Hackage hostname" <> showDefault)
                  <*> subparser (command "pull-cabal" (info (helper <*> pullcoParser)
                                                       (progDesc "download .cabal files for a package"))
                                 <> command "push-cabal" (info (helper <*> pushcoParser)
                                                          (progDesc "upload revised .cabal files"))
                                )

    verOption = infoOption verMsg (long "version" <> help "output version information and exit")
      where
        verMsg = "hackage-cli " <> showVersion Paths_hackage_cli.version

----------------------------------------------------------------------------

main :: IO ()
main = do
    opts <- execParser optionsParserInfo
    withOpenSSL (mainWithOptions opts)

mainWithOptions :: Options -> IO ()
mainWithOptions Options {..} = do
   case optCommand of
       PullCabal (PullCOptions {..}) -> do
           let pkgn = optPCPkgName

           cs <- runHConn (fetchAllCabalFiles pkgn)

           forM_ cs $ \(v,raw) -> do
               let fn = BS8.unpack $ pkgn <> "-" <> v <> ".cabal"

               doesFileExist fn >>= \case
                   False -> do
                       BS.writeFile fn raw
                       putStrLn ("saved " ++ fn ++ " (" ++ show (BS.length raw) ++ " bytes)")
                   True -> do
                       putStrLn ("WARNING: skipped existing " ++ fn)

           return ()

       PushCabal (PushCOptions {..}) -> do
           (username,password) <- maybe (fail "missing Hackage credentials") return =<< getHackageCreds
           putStrLn $ "Using Hackage credentials for username " ++ show username

           forM_ optPCFiles $ \fn -> do
               (pkgn,pkgv,xrev) <- pkgDescToPkgIdXrev <$> C.readPackageDescription C.deafening fn
               putStrLn $ concat [ "Pushing ", show fn
                                 , " (", BS8.unpack pkgn, "-", BS8.unpack pkgv, "~", show xrev, ")"
                                 , if optPCDry then " [review-mode]" else "", " ..."
                                 ]

               let editCab | optPCIncrRev = cabalEditXRev (xrev+1)
                           | otherwise    = id
               rawcab <- editCab <$> BS.readFile fn
               tmp <- runHConn (hackagePostCabal (username,password) (pkgn,pkgv) rawcab
                                                 (if optPCDry then DryRun else WetRun))
               BS8.putStrLn tmp

   return ()
  where
    mkHConn = do
        sslCtx <- baselineContextSSL
        pure $ HConn (openConnectionSSL sslCtx optHost 443) Nothing 0 0

    runHConn act = do
        hc0 <- mkHConn
        flip evalStateT hc0 $ do
            res <- act
            closeHConn
            return res

    getHackageCreds :: IO (Maybe (ByteString,ByteString))
    getHackageCreds = do
        readUserNetRc >>= \case
            Nothing -> pure Nothing
            Just (Left _) -> fail "Invalid ${HOME}/.netrc found"
            Just (Right (NetRc {..})) -> do
                evaluate $ fmap (\NetRcHost{..} -> (nrhLogin,nrhPassword)) $ listToMaybe (filter ((== optHost) . nrhName) nrHosts)


    pkgDescToPkgIdXrev pdesc = force (BS8.pack pkgn, BS8.pack $ showVersion pkgv, read xrev :: PkgRev)
      where
        C.PackageIdentifier (C.PackageName pkgn) pkgv = C.package . C.packageDescription $ pdesc
        xrev = fromMaybe "0" . lookup "x-revision" . C.customFieldsPD . C.packageDescription $ pdesc
