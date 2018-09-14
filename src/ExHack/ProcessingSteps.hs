{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module ExHack.ProcessingSteps (
    generateDb,
    parseStackage,
    dlAssets,
    genGraphDep,
    saveGraphDep,
    retrievePkgsExports,
    indexSymbols
) where

import           Control.Lens                   (view)
import           Control.Monad                  (foldM_)
import           Control.Monad.Catch            (MonadCatch, MonadThrow,
                                                 displayException, handleAll,
                                                 throwM)
import           Control.Monad.IO.Class         (liftIO)
import           Control.Monad.Reader.Class     (asks)
import qualified Data.ByteString                as BS (readFile)
import qualified Data.ByteString.Lazy           as BL (writeFile)
import qualified Data.HashMap.Strict            as HM (HashMap, elems, empty,
                                                       filterWithKey, insert,
                                                       lookup)
import qualified Data.HashSet                   as HS (foldl', unions)
import           Data.List                      (foldl')
import           Data.Maybe                     (fromJust)
import qualified Data.Text                      as T (pack, unpack)
import qualified Data.Text.IO                   as T (readFile)
import           Database.Selda                 (SeldaM)
import           Database.Selda.SQLite          (withSQLite)
import           Network.HTTP.Client            (Manager, httpLbs,
                                                 managerSetProxy, newManager,
                                                 parseRequest_,
                                                 proxyEnvironment, responseBody)
import           Network.HTTP.Client.TLS        (tlsManagerSettings)
import           System.FilePath                ((<.>), (</>))

import           ExHack.Cabal.Cabal             (buildPackage)
import           ExHack.Cabal.CabalParser       (getSuccParse, parseCabalFile)
import           ExHack.Data.Db                 (getPkgImportScopes, initDb,
                                                 saveModuleUnifiedSymbols,
                                                 savePackageDeps,
                                                 savePackageMods, savePackages)
import           ExHack.Ghc                     (getModImports, getModSymbols,
                                                 unLoc)
import           ExHack.Hackage.Hackage         (findComponentRoot,
                                                 getPackageExports,
                                                 unpackHackageTarball)
import           ExHack.ModulePaths             (toModFilePath)
import           ExHack.Stackage.StackageParser (getHackageUrls,
                                                 parseStackageYaml)
import           ExHack.Types                   (CabalBuildError (..),
                                                 CabalFilesDir (..),
                                                 ComponentRoot (..),
                                                 DatabaseHandle,
                                                 DatabaseStatus (..),
                                                 ImportsScope,
                                                 IndexedModuleNameT (..),
                                                 IndexedSym (..),
                                                 LocatedSym (..), ModuleName,
                                                 ModuleNameT (..),
                                                 MonadLog (..), MonadStep,
                                                 Package (allModules, tarballPath),
                                                 PackageComponent (..),
                                                 PackageDlDesc,
                                                 PackageDlDesc (..),
                                                 PackageExports (..),
                                                 PackageFilePath (..),
                                                 SourceCodeFile (..),
                                                 StackageFile (..), SymName,
                                                 TarballDesc (..),
                                                 TarballsDir (..),
                                                 UnifiedSym (..), WorkDir (..),
                                                 getModNameT, getName,
                                                 getPackageNameT, logInfo,
                                                 packagedlDescName)
import           ExHack.Utils                   (Has (..), foldM')

-- | `Step` 1: database generation.
--
--   This function creates a new SQLite database initialized according
--   to ex-hack's internal SQL scheme.
generateDb :: forall c m. 
    (Has c (DatabaseHandle 'New), 
     MonadStep c m) 
    => m (DatabaseHandle 'Initialized)
generateDb = do
    logInfoTitle "[Step 1] Generating database scheme."
    fp <- asks (view hasLens)
    withSQLite fp initDb
    pure fp

-- | `Step` 2: stackage file parsing.
--
--   This function parses the stackage file that will be used to 
--   generate the packages dependancy graph.
parseStackage :: forall c m.
    (Has c StackageFile,
     MonadStep c m)
    => m [PackageDlDesc]
parseStackage = do
    logInfoTitle "[Step 2] Parsing Stackage file"
    (StackageFile stackageYaml) <- asks (view hasLens)
    let packages = fromJust $ parseStackageYaml stackageYaml 
    pure $ getHackageUrls packages

-- | `Step` 3: assets downloading.
--
--   This function downloads both the cabal files and the taballs of the packages.
--   Everything will be downloaded from the <https://hackage.haskell.org> mirror.
dlAssets :: forall c m.
    (Has c TarballsDir,
     Has c CabalFilesDir,
     MonadStep c m)
    => [PackageDlDesc] -> m ()
dlAssets packages = do
    logInfoTitle "[Step 3] Downloading hackage assets (cabal files, tarballs)."
    let settings = managerSetProxy
            (proxyEnvironment Nothing)
            tlsManagerSettings
    tbd <- asks (view hasLens)
    cd <- asks (view hasLens)
    m <- liftIO $ newManager settings
    _ <- foldr (dlFoldCabalFiles cd tbd m (length packages)) (return 1) packages
    return ()
  where
    dlFoldCabalFiles :: CabalFilesDir -> TarballsDir -> Manager -> Int -> PackageDlDesc -> m Int -> m Int
    dlFoldCabalFiles !cd !td man totalSteps !p step = handleAll logErrors $ do 
        step' <- step
        let !pn = packagedlDescName p
        logInfoProgress 3 totalSteps step' $ "Downloading " <> pn <> " assets."
        downloadHackageFiles cd td man p
        return $ step' + 1
      where
        logErrors e = do
            logError $ "[Step 3] ERROR while downloading " <> packagedlDescName p 
                        <> " assets: " <> T.pack (displayException e)
            step' <- step
            pure (step' + 1)
    downloadHackageFiles :: CabalFilesDir -> TarballsDir -> Manager -> PackageDlDesc -> m ()
    downloadHackageFiles 
      (CabalFilesDir cabalFilesDir) (TarballsDir tarballsDir) man 
      (PackageDlDesc (name, cabalUrl, tarballUrl)) = 
        liftIO $ do
            f <- httpLbs (parseRequest_ $ T.unpack cabalUrl) man 
            BL.writeFile (cabalFilesDir </> T.unpack name <.> "cabal") $ responseBody f 
            f' <-  httpLbs (parseRequest_ $ T.unpack tarballUrl) man
            BL.writeFile (tarballsDir </> T.unpack name <.> "tar.gz") $ responseBody f' 
            return ()

-- | `Step` 4: Dependencies graph generation.
--
--   This function generates the packages dependancy graph.
--
genGraphDep :: forall c m.
    (Has c TarballsDir,
     Has c CabalFilesDir,
     Has c (DatabaseHandle 'Initialized),
     MonadStep c m)
    => [PackageDlDesc] -> m [Package]
genGraphDep pd = do
    logInfoTitle "[Step 4] Generating dependencies graph."
    tbd <- asks (view hasLens)
    cd <- asks (view hasLens)
    logInfo "[+] Parsing cabal files."
    (_,pkgs) <- foldM' (readPkgsFiles cd tbd (length pd)) (1,[]) pd
    pure $ getSuccParse (parseCabalFile <$> pkgs)
  where
    readPkgsFiles :: CabalFilesDir -> TarballsDir -> Int -> (Int, [TarballDesc])
                  -> PackageDlDesc -> m (Int, [TarballDesc])
    readPkgsFiles (CabalFilesDir cabalFilesDir) (TarballsDir tarballsDir) !totalSteps (!step, xs) p = 
        handleAll logErrors $ do
            logInfoProgress 4 totalSteps step $ "Reading " <> packagedlDescName p <> " cabal file."
            let tp = tarballsDir </> T.unpack (packagedlDescName p) <.> "tar.gz"
            cf <- liftIO $ T.readFile $ cabalFilesDir </> T.unpack (packagedlDescName p) <.> "cabal"
            pure (step + 1, TarballDesc (tp,cf) : xs)
      where
        logErrors e = do
            logError $ "[Step 4] ERROR cannot read " <> packagedlDescName p
                       <> " cabal file: " <> T.pack (displayException e)
            pure (step + 1, xs)

-- | `Step` 5: Save dependancies graph.
-- 
--   This step takes the previously generated dependancies graph and saves it
--   in the database.
--
--   Caution: this step can be **really** long.
saveGraphDep :: forall c m.
    (Has c TarballsDir,
     Has c CabalFilesDir,
     Has c (DatabaseHandle 'Initialized),
     MonadStep c m)
    => [Package] -> m (DatabaseHandle 'DepsGraph)
saveGraphDep pkgs = do
    logInfoTitle "[Step 5] Saving dependencies graph."
    dbHandle <- asks (view hasLens)
    liftIO $ withSQLite dbHandle $ do
        logInfo "[+] Saving packages to DB (may take some time)..."
        savePackages pkgs
        logInfo "[+] Done."
        logInfo "[+] Saving dependancies to DB..."
        -- TODO: maybe speedup this insert by caching the packages ids
        -- in a hasmap in the memory. (or use sqlite in memory system????)
        foldM_ (foldInsertDep (length pkgs)) 1 pkgs
        logInfo "[+] Done."
        return ()
    pure dbHandle 
  where
    foldInsertDep :: Int -> Int -> Package -> SeldaM Int
    foldInsertDep totalDeps step pkg = handleAll logErrors $ do 
        savePackageDeps pkg
        logInfoProgress 5 totalDeps step $ "Saving " <> getName pkg <> " dependancies to DB."
        pure $ step + 1
      where
        logErrors e = do
            logError $ "[Step 5] ERROR cannot insert " <> getName pkg <> " dependancies to DB: "
                <> T.pack (displayException e)
            pure $ step + 1

-- | `Step` 6: extracting and indexing modules exports.
retrievePkgsExports :: forall c m.
    (Has c WorkDir,
     Has c (DatabaseHandle 'DepsGraph),
     MonadStep c m)
   => [Package] -> m (DatabaseHandle 'PkgExports, [PackageExports])
retrievePkgsExports pkgs = do
    logInfoTitle "[Step 6] Retrieving modules exports."
    dbHandle <- asks (view hasLens)
    wd <- asks (view hasLens) 
    (_, pkgsExports) <- foldM' (getPkgExports (length pkgs) wd) (1, []) pkgs
    logInfo "[Step 6] Saving modules exports to database."
    _ <- liftIO $ withSQLite dbHandle $
            foldM_ (savePackageModsLogProgress (length pkgsExports)) 1 pkgsExports 
    pure (dbHandle, pkgsExports)
  where
    savePackageModsLogProgress :: Int -> Int -> PackageExports -> SeldaM Int 
    savePackageModsLogProgress !totalSteps !step pe@(PackageExports (p,_,_)) = 
        handleAll logErrors $ do
            logInfoProgress 6 totalSteps step $ "Saving " <> getName p <> " exports to database."
            savePackageMods pe
            pure $ step + 1
      where
        logErrors e = do
            logError $ "[Step 6] ERROR cannot save exports of " <> getName p 
                        <> " in database: " <> T.pack (displayException e)
            pure $ step + 1
    getPkgExports :: Int -> WorkDir -> (Int, [PackageExports]) -> Package -> m (Int,[PackageExports])
    getPkgExports totalSteps (WorkDir wd) (!nb, xs) p = handleAll logErrors $ do
        logInfoProgress 6 totalSteps nb $ "Retrieving "<> getName p <> " exports." 
        tb <- liftIO . BS.readFile $ tarballPath p
        pfp <- unpackHackageTarball wd tb
        cr <- buildPackage pfp
        maybe (pure ()) (\(errCode, errStr) -> throwM $ CabalBuildError errCode errStr) cr 
        x <- getPackageExports pfp p
        pure (nb + 1,  x : xs)
      where
        logErrors e = do
            logError $ "[Step 6] ERROR cannot get exports for " <> getName p <> ": " 
                     <> T.pack (displayException e)
            pure (nb + 1, xs)
            
-- | `Step` 7: Indexes the code source symbols in the database.
--
-- For each package, component and module, this step will:
--
-- 1. Retrieve the imported symbols and try to match them to the previously
--    indexed package exports.
-- 2. Use GHC parser to get this file symbols.
-- 3. Unify these symbols to the imported one.
-- 4. We save each unified occurence in the database.
indexSymbols :: forall c m.
    (MonadStep c m,
     MonadCatch m,
     MonadThrow m,
     Has c (DatabaseHandle 'PkgExports))
  => [PackageExports] -> m ()
indexSymbols pkgs = do
    logInfoTitle "[Step 7] Indexing used symbols."
    dbh <- asks (view hasLens)
    foldM_ (indexPackage dbh (length pkgs)) 1 pkgs 
  where
    indexPackage :: DatabaseHandle 'PkgExports -> Int -> Int -> PackageExports -> m Int 
    indexPackage !dbh nb cur (PackageExports (p, pfp, _)) = do
        logInfoProgress 7 nb cur $ "Indexing " <> getName p <> " used symbols."
        is <- liftIO $ withSQLite dbh $ getPkgImportScopes p
        indexComponent dbh p pfp is `mapM_` allModules p 
        pure $ cur + 1
    indexComponent :: DatabaseHandle 'PkgExports -> Package -> PackageFilePath -> ImportsScope 
                   -> PackageComponent -> m ()
    indexComponent dbh p pfp is pc = do
        mfps <- findModuleFilePath pfp (roots pc) `mapM` mods pc
        indexModule dbh p pfp is `mapM_` mfps
    indexModule :: DatabaseHandle 'PkgExports -> Package -> PackageFilePath -> ImportsScope 
                -> (ModuleName, ComponentRoot) -> m ()
    indexModule dbh p pfp is (mn,cr) = handleAll logErrors $ do
        imports <- getModImports pfp cr mn 
        -- fis: filtered import scope according to this module imports
        -- isyms: imported symbols hashmap on which we will perform the unification
        let !fis = HM.filterWithKey (\(IndexedModuleNameT (n, _)) _ -> n `elem` imports) is
            !isyms = HS.unions $ HM.elems fis
            !isymsMap = HS.foldl' (\hm is'@(IndexedSym (n, _)) -> HM.insert n is' hm) HM.empty isyms 
        syms <- getModSymbols p pfp cr mn
        fileContent <- liftIO $ T.readFile $ toModFilePath pfp cr mn
        let !file = SourceCodeFile fileContent (getModNameT mn) (getPackageNameT p)
            !unsyms = unifySymbols isymsMap syms
        withSQLite dbh $ saveModuleUnifiedSymbols unsyms file 
      where
        logErrors e = do
            let (ModuleNameT mnt) = getModNameT mn
            logError $ "[Step 7] ERROR while indexing module " <> mnt <> " from package "
                     <> getName p <> ": " <> T.pack (displayException e)
                    
    findModuleFilePath :: PackageFilePath -> [ComponentRoot] -> ModuleName -> m (ModuleName, ComponentRoot)
    findModuleFilePath pfp crs mn = do
        cr <- findComponentRoot pfp crs mn
        pure (mn, cr)
    unifySymbols :: HM.HashMap SymName IndexedSym -> [LocatedSym] -> [UnifiedSym]
    unifySymbols isyms = foldl' foldLSym []
      where
        foldLSym xs ls@(LocatedSym (_, _, locSym)) = 
            maybe xs (\is -> UnifiedSym(is,ls) : xs) (HM.lookup (unLoc locSym) isyms) 
