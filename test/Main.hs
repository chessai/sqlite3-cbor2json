{-# language
    CApiFFI
  , DerivingStrategies
  , DerivingVia
  , ForeignFunctionInterface
  , ImportQualifiedPost
  , LambdaCase
  , OverloadedRecordDot
  , OverloadedStrings
  , PatternSynonyms
#-}

module Main (main) where

import System.Exit (exitFailure)
import Data.Text (Text)
import Control.Monad (foldM, when, void)
import Data.Bits (Bits, Ior(..))
import Codec.CBOR.Term (Term(..))
import Codec.CBOR.Term qualified as CBOR
import Codec.CBOR.Write qualified as CBOR
import Data.ByteString qualified as BS
import Database.SQLite3.Bindings (c_sqlite3_enable_load_extension)
import Database.SQLite3.Bindings.Types (CDatabase, CError(..), decodeError)
import Database.SQLite3.Direct (Utf8(..), Database(..), Error)
import Database.SQLite3.Direct qualified as Direct
import Foreign (Ptr, alloca, nullPtr)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt(..))
import Foreign.Storable (peek)
import Database.SQLite.Simple (Only(..), execute, execute_, query_)
import Database.SQLite.Simple.Internal (Connection(..))

foreign import ccall "sqlite3_open_v2"
  c_sqlite3_open_v2 :: CString -> Ptr (Ptr CDatabase) -> CInt -> CString -> IO CError

foreign import ccall "sqlite3_close_v2"
  c_sqlite3_close_v2 :: Ptr CDatabase -> IO CError

-- | Flags for SQLite File Open Operations.
--
--   You can use the Semigroup instance ('<>') to combine flags.
--   The Semigroup instance is equivalent to using bitwise-OR ('.|.')
--
--   Some flags may not be suitable without a VFS.
--   See https://www.sqlite.org/c3ref/c_open_autoproxy.html for more details.
newtype SQLiteFlag = SQLiteFlag CInt
  deriving newtype (Eq, Ord, Bits)
  deriving (Semigroup) via (Ior CInt)

-- | Ok for sqlite3_open_v2()
pattern SQLITE_OPEN_READONLY :: SQLiteFlag
pattern SQLITE_OPEN_READONLY = SQLiteFlag 0x00000001

-- | Ok for sqlite3_open_v2()
pattern SQLITE_OPEN_READWRITE :: SQLiteFlag
pattern SQLITE_OPEN_READWRITE = SQLiteFlag 0x00000002

-- | Ok for sqlite3_open_v2()
pattern SQLITE_OPEN_CREATE :: SQLiteFlag
pattern SQLITE_OPEN_CREATE = SQLiteFlag 0x00000004

-- | VFS only
pattern SQLITE_OPEN_DELETEONCLOSE :: SQLiteFlag
pattern SQLITE_OPEN_DELETEONCLOSE = SQLiteFlag 0x00000008

-- | VFS only
pattern SQLITE_OPEN_EXCLUSIVE :: SQLiteFlag
pattern SQLITE_OPEN_EXCLUSIVE = SQLiteFlag 0x00000010

-- | VFS only
pattern SQLITE_OPEN_AUTOPROXY :: SQLiteFlag
pattern SQLITE_OPEN_AUTOPROXY = SQLiteFlag 0x00000020

-- | Ok for sqlite3_open_v2()
pattern SQLITE_OPEN_URI :: SQLiteFlag
pattern SQLITE_OPEN_URI = SQLiteFlag 0x00000040

-- | Ok for sqlite3_open_v2()
pattern SQLITE_OPEN_MEMORY :: SQLiteFlag
pattern SQLITE_OPEN_MEMORY = SQLiteFlag 0x00000080

-- | VFS only
pattern SQLITE_OPEN_MAIN_DB :: SQLiteFlag
pattern SQLITE_OPEN_MAIN_DB = SQLiteFlag 0x00000100

-- | VFS only
pattern SQLITE_OPEN_TEMP_DB :: SQLiteFlag
pattern SQLITE_OPEN_TEMP_DB = SQLiteFlag 0x00000200

-- | VFS only
pattern SQLITE_OPEN_TRANSIENT_DB :: SQLiteFlag
pattern SQLITE_OPEN_TRANSIENT_DB = SQLiteFlag 0x00000400

-- | VFS only
pattern SQLITE_OPEN_MAIN_JOURNAL :: SQLiteFlag
pattern SQLITE_OPEN_MAIN_JOURNAL = SQLiteFlag 0x00000800

-- | VFS only
pattern SQLITE_OPEN_TEMP_JOURNAL :: SQLiteFlag
pattern SQLITE_OPEN_TEMP_JOURNAL = SQLiteFlag 0x00001000

-- | VFS only
pattern SQLITE_OPEN_SUBJOURNAL :: SQLiteFlag
pattern SQLITE_OPEN_SUBJOURNAL = SQLiteFlag 0x00002000

-- | VFS only
pattern SQLITE_OPEN_SUPER_JOURNAL :: SQLiteFlag
pattern SQLITE_OPEN_SUPER_JOURNAL = SQLiteFlag 0x00004000

-- | Ok for sqlite3_open_v2()
pattern SQLITE_OPEN_NOMUTEX :: SQLiteFlag
pattern SQLITE_OPEN_NOMUTEX = SQLiteFlag 0x00008000

-- | Ok for sqlite3_open_v2()
pattern SQLITE_OPEN_FULLMUTEX :: SQLiteFlag
pattern SQLITE_OPEN_FULLMUTEX = SQLiteFlag 0x00010000

-- | Ok for sqlite3_open_v2()
pattern SQLITE_OPEN_SHAREDCACHE :: SQLiteFlag
pattern SQLITE_OPEN_SHAREDCACHE = SQLiteFlag 0x00020000

-- | Ok for sqlite3_open_v2()
pattern SQLITE_OPEN_PRIVATECACHE :: SQLiteFlag
pattern SQLITE_OPEN_PRIVATECACHE = SQLiteFlag 0x00040000

-- | VFS only
pattern SQLITE_OPEN_WAL :: SQLiteFlag
pattern SQLITE_OPEN_WAL = SQLiteFlag 0x00080000

-- | Ok for sqlite3_open_v2()
pattern SQLITE_OPEN_NOFOLLOW :: SQLiteFlag
pattern SQLITE_OPEN_NOFOLLOW = SQLiteFlag 0x01000000

-- | Extended result codes
pattern SQLITE_OPEN_EXRESCODE :: SQLiteFlag
pattern SQLITE_OPEN_EXRESCODE = SQLiteFlag 0x02000000

-- Returns a Database handle, or an Error+ErrorMsg.
open_v2 :: ()
  => Utf8
     -- ^ Database filename (UTF-8)
  -> SQLiteFlag
     -- ^ SQLite Flags
  -> Maybe Utf8
     -- ^ name of VFS module to use
  -> [Ptr CDatabase -> IO CError]
     -- ^ extensions to load.
     --   these are loaded from left to right.
     --   we short-circuit on the first failure.
  -> IO (Either (Error, Utf8) Database)
open_v2 (Utf8 h) (SQLiteFlag flag) mzvfs exts = do
  BS.useAsCString h $ \path -> do
    useAsMaybeCString mzvfs $ \zvfs -> do
      alloca $ \database -> do
        rc <- c_sqlite3_open_v2 path database flag zvfs
        dbPtr <- peek database
        let db = Database dbPtr

        -- sqlite3_open_v2 returns a sqlite3 even on failure.
        -- that's where we get a more descriptive error message.
        case toResult () rc of
          Left err -> do
            onErr err db
          Right () -> do
            when (db == Database nullPtr) $ do
              error "sqlite3_open_v2() unexpectedly returned NULL"

            foldM
              (\r ext -> case r of
                  Left x -> do
                    pure (Left x)
                  Right _ -> do
                    putStrLn "going to load the extension"
                    loadExtension db ext >>= \case
                      Left err -> onErr err db
                      Right _ -> pure (Right db)
                )
              (Right db)
              exts
  where
    onErr :: Error -> Database -> IO (Either (Error, Utf8) x)
    onErr err db = do
      msg <- Direct.errmsg db -- This returns "out of memory" if db is null
      _ <- Direct.close db -- This is harmless if db is null
      pure $ Left (err, msg)

    useAsMaybeCString :: Maybe Utf8 -> (CString -> IO a) -> IO a
    useAsMaybeCString m f = case m of
      Just (Utf8 b) -> BS.useAsCString b f
      Nothing -> f nullPtr

close_v2 :: Database -> IO (Either Error ())
close_v2 (Database db) = do
  toResult () <$> c_sqlite3_close_v2 db

loadExtension :: Database -> (Ptr CDatabase -> IO CError) -> IO (Either Error ())
loadExtension (Database db) ext = do
  toResult () <$> ext db

toResult :: a -> CError -> Either Error a
toResult a = \case
  CError 0 -> Right a
  code     -> Left (decodeError code)

main :: IO ()
main = do
  let tm = TMap
        [ (TString "positive integers", TList (map TInt [0, 128, 512, 65_536]))
        , (TString "negative integers", TList (map (TInt . negate) [2, 128, 512, 65_536]))
        , (TString "byte strings", TBytes "foo")
        , (TString "UTF-8 strings", TString "bar")
        , (TString "arrays", TList (map TInt [1, 2, 3, 4]))
        , (TString "maps", TMap
                             [ (TString "do you know", TString "love apples")
                             , (TString "gods of death", TString "have red hands")
                             ])
        , (TString "tagged values", TMap
                                      [ (TString "URL", TTagged 32 (TString "http://www.example.com"))
                                      , (TString "Bytes", TTagged 24 (TBytes "jazz"))
                                      ])
        , (TString "floats", TFloat pi)
        , (TString "bools", TList [TBool True, TBool False])
        , (TString "nulls", TNull)
        ]

  conn@(Connection db) <- do
    let flags = SQLITE_OPEN_READWRITE <> SQLITE_OPEN_CREATE <> SQLITE_OPEN_FULLMUTEX
    open_v2 "test.sqlite" flags Nothing [] >>= \case
      Right db -> pure (Connection db)
      Left _ -> do
        putStrLn "an error occurred"
        exitFailure

  execute_ conn "CREATE TABLE IF NOT EXISTS test (id INTEGER PRIMARY KEY, data BLOB)"
  execute_ conn "DELETE from test"
  execute conn "INSERT INTO test (data) VALUES (?)" (Only (CBOR.toStrictByteString (CBOR.encodeTerm tm)))

  void $ close_v2 db
