{-|
Functions to import and export tasks
-}
module ImportExport where

import Protolude (
  Applicative (pure),
  Bool (..),
  Char,
  Either (..),
  Eq ((==)),
  FilePath,
  Foldable (foldl),
  Functor (fmap),
  Hashable (hash),
  IO,
  Integral (toInteger),
  Maybe (..),
  Num (abs),
  Semigroup ((<>)),
  Text,
  Traversable (sequence),
  die,
  fromMaybe,
  isJust,
  putErrLn,
  rightToMaybe,
  show,
  stderr,
  toStrict,
  ($),
  (&),
  (+),
  (.),
  (<$>),
  (<&>),
  (=<<),
  (||),
 )
import Protolude qualified as P

import Config (Config (dataDir, dbName))
import Control.Arrow ((>>>))
import Control.Monad.Catch (catchAll)
import Data.Aeson (Value)
import Data.Aeson as Aeson (
  Value (Array, Object, String),
  eitherDecode,
  encode,
 )
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseMaybe)
import Data.ByteString.Lazy qualified as BSL
import Data.Csv qualified as Csv
import Data.Hourglass (
  TimeFormat (toFormat),
  timePrint,
 )
import Data.Text qualified as T
import Data.Text.Lazy.Encoding qualified as TL
import Data.ULID (ulidFromInteger)
import Data.ULID.TimeStamp (getULIDTimeStamp)
import Data.Vector qualified as V
import Data.Yaml (ParseException (InvalidYaml), YamlException (YamlException, YamlParseException), YamlMark (YamlMark))
import Data.Yaml qualified as Yaml
import Database.SQLite.Simple as Sql (Connection, query_)
import FullTask (FullTask)
import ImportTask (ImportTask (..), emptyImportTask, importUtcFormat, setMissingFields)
import Lib (
  execWithConn,
  execWithTask,
  insertNotes,
  insertRecord,
  insertTags,
  updateTask,
 )
import Note (Note (..))
import Prettyprinter (
  Doc,
  Pretty (pretty),
  annotate,
  dquotes,
  hardline,
  vsep,
  (<+>),
 )
import Prettyprinter.Render.Terminal (AnsiStyle, Color (Red), color, hPutDoc)
import System.Directory (createDirectoryIfMissing, listDirectory, removeFile)
import System.FilePath (isExtensionOf, takeExtension, (</>))
import System.Posix.User (getEffectiveUserName)
import System.Process (readProcess)
import Task (Task (body, closed_utc, metadata, modified_utc, ulid, user), setMetadataField, taskToEditableYaml)
import Text.Editor (runUserEditorDWIM, yamlTemplate)
import Text.Parsec.Rfc2822 (GenericMessage (..), message)
import Text.Parsec.Rfc2822 qualified as Email
import Text.ParserCombinators.Parsec as Parsec (parse)
import Text.PortableLines.ByteString.Lazy (lines8)
import Time.System (dateCurrent, timeCurrent)
import Utils (
  IdText,
  emptyUlid,
  setDateTime,
  ulidTextToDateTime,
  zeroUlidTxt,
  zonedTimeToDateTime,
  (<$$>),
 )


insertImportTask :: Connection -> ImportTask -> IO (Doc AnsiStyle)
insertImportTask connection importTask = do
  effectiveUserName <- getEffectiveUserName
  let taskNorm =
        importTask.task
          { Task.user =
              if importTask.task.user == ""
                then T.pack effectiveUserName
                else importTask.task.user
          }
  insertRecord "tasks" connection taskNorm
  tagWarnings <-
    insertTags
      connection
      (ulidTextToDateTime taskNorm.ulid)
      taskNorm
      importTask.tags
  noteWarnings <-
    insertNotes
      connection
      (ulidTextToDateTime taskNorm.ulid)
      taskNorm
      importTask.notes
  pure $
    tagWarnings
      <$$> noteWarnings
      <$$> "📥 Imported task"
      <+> dquotes (pretty taskNorm.body)
      <+> "with ulid"
      <+> dquotes (pretty taskNorm.ulid)
      <+> hardline


importJson :: Config -> Connection -> IO (Doc AnsiStyle)
importJson _ connection = do
  content <- BSL.getContents

  case Aeson.eitherDecode content of
    Left error -> die $ T.pack error <> " in task \n" <> show content
    Right importTaskRec -> do
      importTaskNorm <- importTaskRec & setMissingFields
      insertImportTask connection importTaskNorm


importEml :: Config -> Connection -> IO (Doc AnsiStyle)
importEml _ connection = do
  content <- BSL.getContents

  case Parsec.parse message "<stdin>" content of
    Left error -> die $ show error
    Right email -> insertImportTask connection $ emailToImportTask email


emailToImportTask :: GenericMessage BSL.ByteString -> ImportTask
emailToImportTask email@(Message headerFields msgBody) =
  let
    addBody (ImportTask task notes tags) =
      ImportTask
        task
          { Task.body =
              task.body
                <> ( msgBody
                      & lines8
                      <&> (TL.decodeUtf8 >>> toStrict)
                      & T.unlines
                      & T.dropEnd 1
                   )
          }
        notes
        tags

    namesToJson names =
      Array $
        V.fromList $
          names
            <&> ( \(Email.NameAddr name emailAddress) ->
                    Object $
                      KeyMap.fromList
                        [ ("name", Aeson.String $ T.pack $ fromMaybe "" name)
                        , ("email", Aeson.String $ T.pack emailAddress)
                        ]
                )

    addHeaderToTask :: ImportTask -> Email.Field -> ImportTask
    addHeaderToTask impTask@(ImportTask task notes tags) headerValue =
      case headerValue of
        Email.Date emailDate ->
          let
            utc = zonedTimeToDateTime emailDate
            ulidGeneratedRes =
              (email & show :: Text)
                & (hash >>> toInteger >>> abs >>> ulidFromInteger)
            ulidCombined =
              (ulidGeneratedRes & P.fromRight emptyUlid)
                `setDateTime` utc
          in
            ImportTask
              task
                { Task.ulid = T.toLower $ show ulidCombined
                , Task.modified_utc =
                    T.pack $ timePrint (toFormat importUtcFormat) utc
                }
              notes
              tags
        Email.From names ->
          ImportTask
            (setMetadataField "from" (namesToJson names) task)
            notes
            tags
        Email.To names ->
          ImportTask
            (setMetadataField "to" (namesToJson names) task)
            notes
            tags
        Email.MessageID msgId ->
          ImportTask
            (setMetadataField "messageId" (Aeson.String $ T.pack msgId) task)
            notes
            tags
        Email.Subject subj ->
          ImportTask
            task{Task.body = task.body <> T.pack subj}
            notes
            tags
        Email.Keywords kwords ->
          ImportTask
            task
            notes
            (tags <> fmap (T.unwords . fmap T.pack) kwords)
        Email.Comments cmnts ->
          ImportTask
            (setMetadataField "comments" (Aeson.String $ T.pack cmnts) task)
            notes
            tags
        _ -> impTask
  in
    foldl addHeaderToTask (addBody emptyImportTask) headerFields


isDirError :: FilePath -> P.SomeException -> IO (Doc AnsiStyle)
isDirError filePath exception = do
  if "is a directory" `T.isInfixOf` show exception
    then do
      hPutDoc stderr $
        annotate (color Red) $
          ("ERROR: \"" <> pretty filePath <> "\" is a directory. ")
            <> "Use `importdir` instead."
      die ""
    else die $ show exception


importFile :: Config -> Connection -> FilePath -> IO (Doc AnsiStyle)
importFile _ conn filePath = do
  catchAll
    ( do
        content <- BSL.readFile filePath
        let fileExt = filePath & takeExtension
        case fileExt of
          ".json" -> do
            let decodeResult = Aeson.eitherDecode content
            case decodeResult of
              Left error ->
                die $ T.pack error <> " in task \n" <> show content
              Right importTaskRec -> do
                importTaskNorm <- importTaskRec & setMissingFields
                insertImportTask conn importTaskNorm
          ".eml" ->
            case Parsec.parse message filePath content of
              Left error -> die $ show error
              Right email -> insertImportTask conn $ emailToImportTask email
          _ ->
            die $ T.pack $ "File type " <> fileExt <> " is not supported"
    )
    (isDirError filePath)


filterImportable :: FilePath -> Bool
filterImportable filePath =
  (".json" `isExtensionOf` filePath)
    || (".eml" `isExtensionOf` filePath)


importDir :: Config -> Connection -> FilePath -> IO (Doc AnsiStyle)
importDir conf connection dirPath = do
  files <- listDirectory dirPath
  resultDocs <-
    files
      & P.filter filterImportable
      <&> (dirPath </>)
      & P.mapM (importFile conf connection)
  pure $ P.fold resultDocs


ingestFile :: Config -> Connection -> FilePath -> IO (Doc AnsiStyle)
ingestFile _config connection filePath = do
  catchAll
    ( do
        content <- BSL.readFile filePath
        resultDocs <- case takeExtension filePath of
          ".json" -> do
            let decodeResult = Aeson.eitherDecode content
            case decodeResult of
              Left error ->
                die $ T.pack error <> " in task \n" <> show content
              Right importTaskRec -> do
                importTaskNorm <- importTaskRec & setMissingFields
                sequence
                  [ insertImportTask connection importTaskNorm
                  , editTaskByTask OpenEditor connection importTaskNorm.task
                  ]
          ".eml" ->
            case Parsec.parse message filePath content of
              Left error -> die $ show error
              Right email -> do
                let taskRecord@ImportTask{task} = emailToImportTask email
                sequence
                  [ insertImportTask connection taskRecord
                  , editTaskByTask OpenEditor connection task
                  ]
          fileExt ->
            die $ T.pack $ "File type " <> fileExt <> " is not supported"

        removeFile filePath

        pure $
          P.fold resultDocs
            <> ("❌ Deleted file" <+> dquotes (pretty filePath))
    )
    (isDirError filePath)


ingestDir :: Config -> Connection -> FilePath -> IO (Doc AnsiStyle)
ingestDir conf connection dirPath = do
  files <- listDirectory dirPath
  resultDocs <-
    files
      & P.filter filterImportable
      <&> (dirPath </>)
      & P.mapM (ingestFile conf connection)
  pure $ P.fold resultDocs


-- TODO: Use Task instead of FullTask to fix broken notes export
dumpCsv :: Config -> IO (Doc AnsiStyle)
dumpCsv conf = do
  execWithConn conf $ \connection -> do
    rows :: [FullTask] <- query_ connection "SELECT * FROM tasks_view"
    pure $ pretty $ TL.decodeUtf8 $ Csv.encodeDefaultOrderedByName rows


dumpNdjson :: Config -> IO (Doc AnsiStyle)
dumpNdjson conf = do
  -- TODO: Use Task instead of FullTask to fix broken notes export
  execWithConn conf $ \connection -> do
    tasks :: [FullTask] <- query_ connection "SELECT * FROM tasks_view"
    pure $
      vsep $
        fmap (pretty . TL.decodeUtf8 . Aeson.encode) tasks


dumpJson :: Config -> IO (Doc AnsiStyle)
dumpJson conf = do
  -- TODO: Use Task instead of FullTask to fix broken notes export
  execWithConn conf $ \connection -> do
    tasks :: [FullTask] <- query_ connection "SELECT * FROM tasks_view"
    pure $ pretty $ fmap (TL.decodeUtf8 . Aeson.encode) tasks


dumpSql :: Config -> IO (Doc AnsiStyle)
dumpSql conf = do
  result <-
    readProcess
      "sqlite3"
      [ conf.dataDir </> conf.dbName
      , ".dump"
      ]
      []
  pure $ pretty result


backupDatabase :: Config -> IO (Doc AnsiStyle)
backupDatabase conf = do
  now <- timeCurrent

  let
    fileUtcFormat = toFormat ("YYYY-MM-DDtHMI" :: [Char])
    backupDirName = "backups"
    backupDirPath = conf.dataDir </> backupDirName
    backupFilePath = backupDirPath </> timePrint fileUtcFormat now <> ".db"

  -- Create directory (and parents because of True)
  createDirectoryIfMissing True backupDirPath

  result <-
    pretty
      <$> readProcess
        "sqlite3"
        [ conf.dataDir </> conf.dbName
        , ".backup '" <> backupFilePath <> "'"
        ]
        []

  pure $
    result
      <> hardline
      <> pretty
        ( "✅ Backed up database \""
            <> conf.dbName
            <> "\" to \""
            <> backupFilePath
            <> "\""
        )


data EditMode
  = ApplyPreEdit (P.ByteString -> P.ByteString)
  | OpenEditor
  | OpenEditorRequireEdit


{-| Edit the task until it is valid YAML and can be decoded.
| Return the the tuple `(task, valid YAML content)`
-}
editUntilValidYaml
  :: EditMode
  -> Connection
  -> P.ByteString
  -> P.ByteString
  -> IO (Either ParseException (ImportTask, P.ByteString))
editUntilValidYaml editMode conn initialYaml wipYaml = do
  yamlAfterEdit <- case editMode of
    ApplyPreEdit editFunc -> pure $ editFunc wipYaml
    OpenEditor -> runUserEditorDWIM yamlTemplate wipYaml
    OpenEditorRequireEdit -> runUserEditorDWIM yamlTemplate wipYaml

  if yamlAfterEdit == initialYaml
    then pure $ Left $ InvalidYaml $ Just $ YamlException $ case editMode of
      -- Content doesn't have to be changed -> log nothing
      OpenEditor -> ""
      _ -> "⚠️ Nothing changed"
    else do
      case yamlAfterEdit & Yaml.decodeEither' of
        Left error -> do
          case error of
            -- Adjust the line and column numbers to be 1-based
            InvalidYaml
              (Just (YamlParseException prblm ctxt (YamlMark idx line col))) ->
                let yamlMark = YamlMark (idx + 1) (line + 1) (col + 1)
                in  putErrLn $
                      Yaml.prettyPrintParseException
                        ( InvalidYaml
                            (Just (YamlParseException prblm ctxt yamlMark))
                        )
                        <> "\n"
            _ ->
              putErrLn $ Yaml.prettyPrintParseException error <> "\n"
          editUntilValidYaml editMode conn initialYaml yamlAfterEdit
        ---
        Right newTask -> do
          pure $ Right (newTask, yamlAfterEdit)


editTaskByTask :: EditMode -> Connection -> Task -> IO (Doc AnsiStyle)
editTaskByTask editMode conn taskToEdit = do
  taskYaml <- taskToEditableYaml conn taskToEdit
  taskYamlTupleRes <- editUntilValidYaml editMode conn taskYaml taskYaml
  case taskYamlTupleRes of
    Left error -> case error of
      InvalidYaml (Just (YamlException "")) -> pure P.mempty
      _ -> pure $ pretty $ Yaml.prettyPrintParseException error
    Right (importTaskRec, newContent) -> do
      effectiveUserName <- getEffectiveUserName
      now <- getULIDTimeStamp <&> (show >>> T.toLower)
      let
        parseMetadata :: Value -> Parser Bool
        parseMetadata val = case val of
          Object obj -> do
            let mdataMaybe = KeyMap.lookup "metadata" obj
            pure $ case mdataMaybe of
              Just (Object _) -> True
              _ -> False
          _ -> pure False

        hasMetadata =
          parseMaybe parseMetadata
            =<< rightToMaybe (Yaml.decodeEither' newContent)

        taskFixed =
          importTaskRec.task
            { Task.user =
                if importTaskRec.task.user == ""
                  then T.pack effectiveUserName
                  else importTaskRec.task.user
            , Task.metadata =
                if hasMetadata == Just True
                  then importTaskRec.task.metadata
                  else Nothing
            , -- Set to previous value to force SQL trigger to update it
              Task.modified_utc = taskToEdit.modified_utc
            }
        notesCorrectUtc =
          importTaskRec.notes
            <&> ( \note ->
                    note
                      { Note.ulid =
                          if zeroUlidTxt `T.isPrefixOf` note.ulid
                            then note.ulid & T.replace zeroUlidTxt now
                            else note.ulid
                      }
                )

      updateTask conn taskFixed

      -- TODO: Remove after it was added to `createSetClosedUtcTrigger`
      -- Update again with the same `state` field to avoid firing
      -- SQL trigger which would overwrite the `closed_utc` field.
      P.when (isJust taskFixed.closed_utc) $ do
        now_ <- dateCurrent
        updateTask
          conn
          taskFixed
            { Task.modified_utc =
                now_
                  & timePrint (toFormat importUtcFormat)
                  & T.pack
            }

      tagWarnings <- insertTags conn Nothing taskFixed importTaskRec.tags
      noteWarnings <- insertNotes conn Nothing taskFixed notesCorrectUtc
      pure $
        tagWarnings
          <$$> noteWarnings
          <$$> "✏️  Edited task"
          <+> dquotes (pretty taskFixed.body)
          <+> "with ulid"
          <+> dquotes (pretty taskFixed.ulid)
          <+> hardline


editTask :: Config -> Connection -> IdText -> IO (Doc AnsiStyle)
editTask conf conn idSubstr = do
  execWithTask conf conn idSubstr $ \taskToEdit -> do
    editTaskByTask OpenEditorRequireEdit conn taskToEdit
