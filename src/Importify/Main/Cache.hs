-- | Contains implementation of @importify cache@ command.

module Importify.Main.Cache
       ( doCache
       ) where

import           Universum

import           Data.Aeson                      (encode)
import qualified Data.ByteString.Lazy            as BS
import qualified Data.Map                        as Map

import           Distribution.PackageDescription (GenericPackageDescription, Library)
import           Language.Haskell.Exts           (Extension, Module, ModuleName (..),
                                                  SrcSpanInfo)
import           Language.Haskell.Names          (writeSymbols)
import           Path                            (Abs, Dir, Path, Rel, fromAbsDir,
                                                  fromAbsFile, parseAbsDir, parseRelDir,
                                                  parseRelFile, (</>))
import           System.Directory                (createDirectoryIfMissing,
                                                  getCurrentDirectory, listDirectory,
                                                  removeDirectoryRecursive)
import           System.FilePath                 (dropExtension, takeFileName)
import           Turtle                          (cd, shell)

import           Importify.Cabal                 (getExtensionMaps, getLibs, getLibs,
                                                  modulePaths, readCabal,
                                                  splitOnExposedAndOther, withLibrary)
import           Importify.CPP                   (parseModuleFile)
import           Importify.Paths                 (cacheDir, cachePath, extensionsFile,
                                                  guessCabalName, modulesFile,
                                                  symbolsPath, targetsFile)
import           Importify.Resolution            (resolveModules)

-- | Caches packages information into local .importify directory.
doCache :: FilePath -> Bool -> IO ()
doCache filepath preserve = do
    cabalDesc <- readCabal filepath

    curDir           <- getCurrentDirectory
    projectPath      <- parseAbsDir curDir
    let importifyPath = projectPath </> cachePath
    let importifyDir  = fromAbsDir importifyPath

    -- TODO: error if not inside project directory?
    createDirectoryIfMissing True importifyDir  -- creates ./.importify
    cd $ fromString cacheDir    -- cd to ./.importify/

    -- Extension maps
    let (targetMaps, extensionMaps) = getExtensionMaps cabalDesc
    BS.writeFile targetsFile    $ encode targetMaps
    BS.writeFile extensionsFile $ encode extensionMaps

    -- Libraries
    let projectName = dropExtension $ takeFileName filepath
    let libs = filter (\p -> p /= "base" && p /= projectName) $ getLibs cabalDesc
    print libs

    -- download & unpack sources, then cache and delete
    dependenciesResolutionMap <- forM libs $
        collectDependenciesResolution importifyPath preserve

    let importsMap = Map.unions dependenciesResolutionMap
    BS.writeFile modulesFile $ encode importsMap

    cd ".."

collectDependenciesResolution :: Path Abs Dir
                              -> Bool
                              -> String
                              -> IO (Map String String)
collectDependenciesResolution importifyPath preserve libName = do
        _exitCode            <- shell ("stack unpack " <> toText libName) empty
        localPackages        <- listDirectory (fromAbsDir importifyPath)
        let maybePackage      = find (libName `isPrefixOf`) localPackages
        let downloadedPackage = fromMaybe (error "Package wasn't downloaded!")
                                          maybePackage  -- TODO: this is not fine

        packagePath      <- parseRelDir downloadedPackage
        let cabalFileName = guessCabalName libName
        packageCabalDesc <- readCabal $ fromAbsFile
                                      $ importifyPath </> packagePath </> cabalFileName

        let symbolsCachePath = importifyPath </> symbolsPath
        packageModules <- createProjectCache packageCabalDesc
                                             symbolsCachePath
                                             packagePath
                                             libName
                                             downloadedPackage

        unless preserve $  -- TODO: use bracket here
            removeDirectoryRecursive downloadedPackage

        pure $ Map.fromList packageModules

createProjectCache :: GenericPackageDescription
                   -> Path Abs Dir
                   -> Path Rel Dir
                   -> String
                   -> String
                   -> IO [(String, String)]
createProjectCache packageCabalDesc symbolsCachePath packagePath libName downloadedPackage =
    withLibrary packageCabalDesc $ \library cabalExtensions -> do
        -- creates ./.importify/symbols/<package>/
        let packageCachePath = symbolsCachePath </> packagePath
        createDirectoryIfMissing True $ fromAbsDir packageCachePath

        (errors, libModules) <- parsedModulesWithErrors packagePath
                                                        library
                                                        cabalExtensions
        reportErrorsIfAny errors libName

        let (exposedModules, otherModules) = splitOnExposedAndOther library libModules
        let resolvedModules = resolveModules exposedModules otherModules

        forM resolvedModules $ \(ModuleName () moduleTitle, resolvedSymbols) -> do
            modSymbolsPath     <- parseRelFile $ moduleTitle ++ ".symbols"
            let moduleCachePath = packageCachePath </> modSymbolsPath

            -- creates ./.importify/symbols/<package>/<Module.Name>.symbols
            writeSymbols (fromAbsFile moduleCachePath) resolvedSymbols

            pure (moduleTitle, downloadedPackage)

parsedModulesWithErrors :: Path Rel Dir
                        -> Library
                        -> [Extension]
                        -> IO ([Text], [Module SrcSpanInfo])
parsedModulesWithErrors packagePath library cabalExtensions = do
    modPaths   <- modulePaths packagePath library
    modEithers <- mapM (parseModuleFile cabalExtensions) modPaths
    pure $ partitionEithers modEithers

reportErrorsIfAny :: [Text] -> String -> IO ()
reportErrorsIfAny errors libName = whenNotNull errors $ \messages -> do
    putText $ " * Next errors occured during caching of package: " <> toText libName
    forM_ messages putText
