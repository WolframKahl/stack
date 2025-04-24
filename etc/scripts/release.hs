{- stack script
   --snapshot lts-23.17
   --ghc-options -Wall
-}

-- As no packages are specified in the `stack script` command in the Stack
-- interpreter options comment, Stack deduces the required packages from the
-- module imports, being: Cabal, base, bytestring, directory, extra, process,
-- shake, tar, zip-archive and zlib. These are either GHC boot packages or in
-- the snapshot. Stackage LTS Haskell 23.17 does not include boot packages
-- directly. As GHC 9.8.4 boot packages Cabal and Cabal-syntax expose modules
-- with the same names, the language extension PackageImports is required.

-- EXPERIMENTAL

-- release.hs can be run on macOS/AArch64, using a Docker image for
-- Alpine Linux/AArch64, in order to create a statically-linked Linux/AArch64
-- version of Stack:
--
-- Install pre-requisites:
--
-- > brew install docker
-- > brew install colima
--
-- Start colima (with sufficient memory for Stack's integration tests) and run
-- script:
--
-- > colima start --memory 4 # The default 2 GB is likely insufficient
-- > stack etc/scripts/release.hs check --alpine --stack-args=--docker-stack-exe=image
-- > stack etc/scripts/release.hs build --alpine --stack-args=--docker-stack-exe=image
-- > colima stop

{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE PackageImports      #-}
{-# LANGUAGE PatternSynonyms     #-}

import qualified Codec.Archive.Tar as Tar
import qualified Codec.Archive.Tar.Entry as TarEntry
import qualified Codec.Archive.Zip as Zip
import qualified Codec.Compression.GZip as GZip
import           Control.Exception ( tryJust )
import           Control.Monad ( forM, guard, when )
import qualified Data.ByteString.Lazy.Char8 as L8
import           Data.List.Extra ( isInfixOf, lower, stripPrefix, trim )
import           Data.Maybe ( fromMaybe )
import           Development.Shake
                   ( Action, Change (..), pattern Chatty, CmdOption (..), Rules
                   , ShakeOptions (..), Stdout (..), (%>), actionOnException
                   , alwaysRerun, cmd, command_, copyFileChanged
                   , getDirectoryFiles, liftIO, need, phony, putInfo
                   , removeFilesAfter, shakeArgsWith, shakeOptions, want
                   )
import           Development.Shake.FilePath
                   ( (<.>), (</>), dropFileName, exe, takeDirectory, toStandard
                   )
import           "Cabal" Distribution.PackageDescription
                   ( PackageDescription (..), packageDescription, pkgVersion
                   )
import           Distribution.Simple.PackageDescription
                   ( readGenericPackageDescription )
import           "Cabal" Distribution.System
                   ( Arch, OS (..), Platform (..), buildPlatform )
import           "Cabal" Distribution.Text ( display, simpleParse )
import           "Cabal" Distribution.Utils.ShortText ( fromShortText )
import           Distribution.Verbosity ( silent )
import           System.Console.GetOpt ( ArgDescr (..), OptDescr (..) )
import           System.Directory ( copyFile, getHomeDirectory, removeFile )
import           System.IO.Error ( isDoesNotExistError )
import           System.Process ( readProcess )

-- | Entrypoint.
main :: IO ()
main = shakeArgsWith
  shakeOptions { shakeFiles = releaseDir
               , shakeVerbosity = Chatty
               , shakeChange = ChangeModtimeAndDigestInput
               }
  options $
  \flags args -> do
  -- build the default value of type Global, with predefined constants

    -- 'stack build --dry-run' just ensures that 'stack.cabal' is generated from
    -- 'package.yaml'.
    _ <- readProcess "stack" ["build", "--dry-run"] ""
    gStackPackageDescription <-
      packageDescription <$> readGenericPackageDescription silent "stack.cabal"
    gGitRevCount <- length . lines <$> readProcess "git" ["rev-list", "HEAD"] ""
    gGitSha <- trim <$> readProcess "git" ["rev-parse", "HEAD"] ""
    gHomeDir <- getHomeDirectory

    let gAllowDirty = False
        Platform arch _ = buildPlatform
        gArch = arch
        gTargetOS = platformOS
        gBinarySuffix = ""
        gTestHaddocks = True
        gProjectRoot = "" -- Set to real value below.
        gBuildArgs = ["--flag", "stack:-developer-mode"]
        gStackArgs = []
        gCheckStackArgs = []
        gCertificateName = Nothing
        global0 = foldl
          (flip id)
          Global
            { gStackPackageDescription
            , gAllowDirty
            , gGitRevCount
            , gGitSha
            , gProjectRoot
            , gHomeDir
            , gArch
            , gTargetOS
            , gBinarySuffix
            , gTestHaddocks
            , gBuildArgs
            , gStackArgs
            , gCheckStackArgs
            , gCertificateName
            }
          flags

    -- Need to get paths after options since the '--arch' argument can effect
    -- them.
    projectRoot' <- getStackPath global0 "project-root"
    let global = global0 { gProjectRoot = projectRoot' }
    pure $ Just $ rules global args
 where
  getStackPath global path = do
    out <-
      readProcess stackProgName (stackArgs global ++ ["path", "--" ++ path]) ""
    pure $ trim $ fromMaybe out $ stripPrefix (path ++ ":") out

-- | Additional command-line options.
options :: [OptDescr (Either String (Global -> Global))]
options =
  [ Option "" [allowDirtyOptName]
      (NoArg $ Right $ \g -> g{gAllowDirty = True})
      "Allow a dirty working tree for release."
  , Option "" [archOptName]
      ( ReqArg
          ( \v -> case simpleParse v of
              Nothing -> Left $ "Unknown architecture in --arch option: " ++ v
              Just arch -> Right $ \g -> g{gArch = arch}
          )
          "ARCHITECTURE"
      )
      "Architecture to build (e.g. 'i386' or 'x86_64')."
  , Option "" [binaryVariantOptName]
      (ReqArg (\v -> Right $ \g -> g{gBinarySuffix = v}) "SUFFIX")
      "Extra suffix to add to binary executable archive filename."
  , Option "" [noTestHaddocksOptName]
      (NoArg $ Right $ \g -> g{gTestHaddocks = False})
      "Disable testing building haddocks."
  , Option "" [alpineOptName]
      ( NoArg $ Right $ \g ->
          g { gBuildArgs =
                   gBuildArgs g
                ++ [ "--flag=stack:static"
                   ]
            , gStackArgs =
                   gStackArgs g
                ++ [ "--docker"
                   , "--system-ghc"
                   , "--no-install-ghc"
                   ]
            , gCheckStackArgs =
                   gCheckStackArgs g
                ++ [ "--system-ghc"
                   , "--no-install-ghc"
                   ]
            , gTargetOS = Linux
            }
      )
      "Build a statically-linked binary using an Alpine Linux Docker image."
  , Option "" [stackArgsOptName]
      ( ReqArg
          (\v -> Right $ \g -> g{gStackArgs = gStackArgs g ++ words v})
          "\"ARG1 ARG2 ...\""
      )
      "Additional arguments to pass to 'stack'."
  , Option "" [buildArgsOptName]
      ( ReqArg
          (\v -> Right $ \g -> g{gBuildArgs = gBuildArgs g ++ words v})
          "\"ARG1 ARG2 ...\""
      )
      "Additional arguments to pass to 'stack build'."
  , Option "" [certificateNameOptName]
      (ReqArg (\v -> Right $ \g -> g{gCertificateName = Just v}) "NAME")
      "Certificate name for code signing on Windows"
  ]

-- | Shake rules.
rules :: Global -> [String] -> Rules ()
rules global args = do
  case args of
    [] -> error "No wanted target(s) specified."
    _ -> want args

  phony releasePhony $ do
    need [checkPhony]
    need [buildPhony]

  phony cleanPhony $
    removeFilesAfter releaseDir ["//*"]

  phony checkPhony $
    need [releaseCheckDir </> binaryExeFileName]

  phony buildPhony $
    mapM_ (\f -> need [releaseDir </> f]) binaryPkgFileNames

  releaseCheckDir </> binaryExeFileName %> \out -> do
    need [releaseBinDir </> binaryName </> stackExeFileName]
    Stdout dirty <- cmd "git status --porcelain"
    when (not global.gAllowDirty && not (null (trim dirty))) $
      error $ concat
        [ "Working tree is dirty.  Use --"
        , allowDirtyOptName
        , " option to continue anyway. Output:\n"
        , show dirty
        ]
    () <- cmd
      stackProgName -- Use the platform's Stack
      global.gStackArgs -- Possibly to set up a Docker container
      ["exec"] -- To execute the target Stack
      [ global.gProjectRoot </> releaseBinDir </> binaryName </>
          stackExeFileName
      ]
      ["--"]
      (stackArgs global)
      global.gCheckStackArgs -- Possible use the Docker image's GHC
      ["build"] -- To build the target Stack (Stack builds Stack)
      global.gBuildArgs
      integrationTestFlagArgs
      ["--pedantic", "--no-haddock-deps", "--test"]
      ["--haddock" | global.gTestHaddocks]
      ["stack"]
    () <- cmd
      (global.gProjectRoot </> releaseBinDir </> binaryName </>
          stackExeFileName) -- Use the target Stack
      ["exec"] -- To execute the target stack-integration-test
      [ global.gProjectRoot </> releaseBinDir </> binaryName </>
          "stack-integration-test"
      ]
    copyFileChanged (releaseBinDir </> binaryName </> stackExeFileName) out

  releaseDir </> binaryPkgZipFileName %> \out -> do
    stageFiles <- getBinaryPkgStageFiles
    putInfo $ "zip " ++ out
    liftIO $ do
      entries <- forM stageFiles $ \stageFile -> do
        Zip.readEntry
          [ Zip.OptLocation
              ( dropFileName
                  ( dropDirectoryPrefix
                      (releaseStageDir </> binaryName)
                      stageFile
                  )
              )
              False
          ]
          stageFile
      let archive = foldr Zip.addEntryToArchive Zip.emptyArchive entries
      L8.writeFile out (Zip.fromArchive archive)

  releaseDir </> binaryPkgTarGzFileName %> \out -> do
    stageFiles <- getBinaryPkgStageFiles
    writeTarGz id out releaseStageDir stageFiles

  releaseStageDir </> binaryName </> stackExeFileName %> \out -> do
    copyFileChanged (releaseDir </> binaryExeFileName) out

  releaseStageDir </> (binaryName ++ "//*") %> \out -> do
    copyFileChanged
      (dropDirectoryPrefix (releaseStageDir </> binaryName) out)
      out

  releaseDir </> binaryExeFileName %> \out -> do
    need [releaseBinDir </> binaryName </> stackExeFileName]
    (Stdout versionOut) <-
      cmd
        stackProgName -- Use the platform's Stack
        global.gStackArgs -- Possibly to set up a Docker container
        ["exec"] -- To execute the target Stack and get its version info
        (releaseBinDir </> binaryName </> stackExeFileName)
        ["--"]
        ["--version"]
    when (not global.gAllowDirty && "dirty" `isInfixOf` lower versionOut) $
      error
        (  "Refusing continue because 'stack --version' reports dirty.  Use --"
        ++ allowDirtyOptName
        ++ " option to continue anyway."
        )
    case platformOS of
      Windows -> do
        -- Windows doesn't have or need a 'strip' command, so skip it.
        -- Instead, we sign the executable
        liftIO $ copyFile (releaseBinDir </> binaryName </> stackExeFileName) out
        case global.gCertificateName of
          Nothing -> pure ()
          Just certName ->
            actionOnException
              ( command_
                  []
                  "c:\\Program Files\\Microsoft SDKs\\Windows\\v7.1\\Bin\\signtool.exe"
                  [ "sign"
                  , "/v"
                  , "/d"
                  , fromShortText $ synopsis global.gStackPackageDescription
                  , "/du"
                  , fromShortText $ homepage global.gStackPackageDescription
                  , "/n"
                  , certName
                  , "/t"
                  , "http://timestamp.verisign.com/scripts/timestamp.dll"
                  , out
                  ]
              )
              (removeFile out)
      Linux ->
        -- Using Ubuntu's strip to strip an Alpine exe doesn't work, so just copy
        liftIO $ copyFile (releaseBinDir </> binaryName </> stackExeFileName) out
      _ ->
        cmd "strip -o"
          [out, releaseBinDir </> binaryName </> stackExeFileName]

  releaseDir </> binaryInstallerFileName %> \_ -> do
    need [releaseDir </> binaryExeFileName]
    need [releaseDir </> binaryInstallerNSIFileName]

    command_ [Cwd releaseDir] "makensis.exe"
      [ "-V3"
      , binaryInstallerNSIFileName
      ]

  releaseDir </> binaryInstallerNSIFileName %> \out -> do
    need ["etc" </> "scripts" </> "build-stack-installer" <.> "hs"]
    -- Added as part of the work around for:
    -- https://github.com/commercialhaskell/stack/issues/6711
    --
    -- On Windows only, for some unidentified reason, stack script can fail when
    -- using a pre-compiled package. This can affect the script
    -- build-stack-installer.hs. The work around is to build the package
    -- required for that script using the same Stack configuration as used by
    -- the script.
    () <- cmd "stack --stack-yaml etc/scripts/stack.yaml build nsis"
    cmd "stack etc/scripts/build-stack-installer.hs"
      [ binaryExeFileName
      , binaryInstallerFileName
      , out
      , stackVersionStr global
      ] :: Action ()

  releaseBinDir </> binaryName </> stackExeFileName %> \out -> do
    alwaysRerun
    actionOnException
      ( cmd
          stackProgName -- Use the platform's Stack
          (stackArgs global)
          ["--local-bin-path=" ++ takeDirectory out]
          global.gStackArgs -- Possibly to set up a Docker container
          "install" -- To build and install Stack to that local bin path
          global.gBuildArgs
          integrationTestFlagArgs
          "--pedantic"
          "stack"
      )
      (tryJust (guard . isDoesNotExistError) (removeFile out))

 where
  integrationTestFlagArgs =
    -- Explicitly enabling 'hide-dependency-versions' and 'supported-build' to
    -- work around https://github.com/commercialhaskell/stack/issues/4960
    [ "--flag=stack:integration-tests"
    , "--flag=stack:hide-dependency-versions"
    , "--flag=stack:supported-build"
    ]

  getBinaryPkgStageFiles = do
    docFiles <- getDocFiles
    let stageFiles = concat
          [ [releaseStageDir </> binaryName </> stackExeFileName]
          , map ((releaseStageDir </> binaryName) </>) docFiles
          ]
    need stageFiles
    pure stageFiles

  getDocFiles = getDirectoryFiles "." ["LICENSE", "*.md", "doc//*.md"]

  releasePhony = "release"
  checkPhony = "check"
  cleanPhony = "clean"
  buildPhony = "build"

  releaseCheckDir = releaseDir </> "check"
  releaseStageDir = releaseDir </> "stage"
  releaseBinDir = releaseDir </> "bin"

  binaryPkgFileNames =
    case global.gTargetOS of
      Windows ->
        [ binaryExeFileName
        , binaryPkgZipFileName
        , binaryPkgTarGzFileName
        , binaryInstallerFileName
        ]
      Linux -> [binaryExeFileName, binaryPkgTarGzFileName]
      _ -> [binaryExeFileName, binaryPkgTarGzFileName]
  binaryPkgZipFileName = binaryName <.> zipExt
  binaryPkgTarGzFileName = binaryName <.> tarGzExt
  binaryExeFileName = binaryName ++ "-bin" <.> exe
  -- Prefix with 'installer-' so it doesn't get included in release artifacts
  -- (due to NSIS limitation, needs to be in same directory as executable)
  binaryInstallerNSIFileName = "installer-" ++ binaryName <.> nsiExt
  binaryInstallerFileName = binaryName ++ "-installer" <.> exe
  binaryName = concat
    [ stackProgName
    , "-"
    , stackVersionStr global
    , "-"
    , display global.gTargetOS
    , "-"
    , display global.gArch
    , if null global.gBinarySuffix then "" else "-" ++ global.gBinarySuffix
    ]
  stackExeFileName = stackProgName <.> exe

  zipExt = ".zip"
  tarGzExt = tarExt <.> gzExt
  gzExt = ".gz"
  tarExt = ".tar"
  nsiExt = ".nsi"

-- | Create a .tar.gz files from files.  The paths should be absolute, and will
-- be made relative to the base directory in the tarball.
writeTarGz ::
     (FilePath -> FilePath)
  -> FilePath
  -> FilePath
  -> [FilePath]
  -> Action ()
writeTarGz fixPath out baseDir inputFiles = liftIO $ do
  content <- Tar.pack baseDir $ map (dropDirectoryPrefix baseDir) inputFiles
  L8.writeFile out $ GZip.compress $ Tar.write $ map fixPath' content
 where
  fixPath' :: Tar.Entry -> Tar.Entry
  fixPath' entry =
    case TarEntry.toTarPath isDir $ fixPath $ TarEntry.entryPath entry of
      Left e -> error $ show (Tar.entryPath entry, e)
      Right tarPath -> entry { TarEntry.entryTarPath = tarPath }
   where
    isDir =
      case TarEntry.entryContent entry of
        TarEntry.Directory -> True
        _ -> False

-- | Drops a directory prefix from a path. The prefix automatically has a path
-- separator character appended. Fails if the path does not begin with the
-- prefix.
dropDirectoryPrefix :: FilePath -> FilePath -> FilePath
dropDirectoryPrefix prefix path =
  case stripPrefix (toStandard prefix ++ "/") (toStandard path) of
    Nothing -> error
      (  "dropDirectoryPrefix: cannot drop "
      ++ show prefix
      ++ " from "
      ++ show path
      )
    Just stripped -> stripped

-- | String representation of Stack package version.
stackVersionStr :: Global -> String
stackVersionStr =
  display . pkgVersion . package . gStackPackageDescription

-- | Current operating system.
platformOS :: OS
platformOS =
  let Platform _ os = buildPlatform
  in  os

-- | Directory in which to store build and intermediate files.
releaseDir :: FilePath
releaseDir = "_release"

-- | @--allow-dirty@ command-line option name.
allowDirtyOptName :: String
allowDirtyOptName = "allow-dirty"

-- | @--arch@ command-line option name.
archOptName :: String
archOptName = "arch"

-- | @--binary-variant@ command-line option name.
binaryVariantOptName :: String
binaryVariantOptName = "binary-variant"

-- | @--no-test-haddocks@ command-line option name.
noTestHaddocksOptName :: String
noTestHaddocksOptName = "no-test-haddocks"

-- | @--stack-args@ command-line option name.
stackArgsOptName :: String
stackArgsOptName = "stack-args"

-- | @--build-args@ command-line option name.
buildArgsOptName :: String
buildArgsOptName = "build-args"

-- | @--alpine@ command-line option name.
alpineOptName :: String
alpineOptName = "alpine"

-- | @--certificate-name@ command-line option name.
certificateNameOptName :: String
certificateNameOptName = "certificate-name"

-- | Arguments to pass to all 'stack' invocations.
stackArgs :: Global -> [String]
stackArgs global = [ "--arch=" ++ display global.gArch
                   , "--interleaved-output"
                   ]

-- | Name of the 'stack' program.
stackProgName :: FilePath
stackProgName = "stack"

-- | Global values and options.
data Global = Global
  { gStackPackageDescription :: !PackageDescription
  , gAllowDirty :: !Bool
  , gGitRevCount :: !Int
  , gGitSha :: !String
  , gProjectRoot :: !FilePath
  , gHomeDir :: !FilePath
  , gArch :: !Arch
  , gTargetOS :: !OS
  , gBinarySuffix :: !String
  , gTestHaddocks :: !Bool
  , gBuildArgs :: [String]
  , gStackArgs :: [String]
  , gCheckStackArgs :: [String]
  , gCertificateName :: !(Maybe String)
  }
  deriving Show
