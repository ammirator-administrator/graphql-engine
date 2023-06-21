{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Hasura.Backends.DataConnector.Adapter.Schema () where

--------------------------------------------------------------------------------

import Control.Lens ((^.))
import Data.Aeson qualified as J
import Data.Has
import Data.HashMap.Strict.Extended qualified as HashMap
import Data.List.NonEmpty qualified as NE
import Data.Scientific (fromFloatDigits)
import Data.Sequence qualified as Seq
import Data.Text.Casing (GQLNameIdentifier, fromAutogeneratedName, fromCustomName)
import Data.Text.Extended (toTxt, (<<>), (<>>))
import Data.Traversable (mapAccumL)
import Hasura.Backends.DataConnector.API qualified as API
import Hasura.Backends.DataConnector.Adapter.Backend (CustomBooleanOperator (..), columnTypeToScalarType, lookupGraphQLType)
import Hasura.Backends.DataConnector.Adapter.Types qualified as DC
import Hasura.Backends.DataConnector.Adapter.Types.Mutations qualified as DC
import Hasura.Base.Error
import Hasura.Function.Cache qualified as RQL
import Hasura.GraphQL.Parser.Class
import Hasura.GraphQL.Schema.Backend (BackendSchema (..), BackendTableSelectSchema (..), BackendUpdateOperatorsSchema (..), ComparisonExp, MonadBuildSchema)
import Hasura.GraphQL.Schema.BoolExp qualified as GS.BE
import Hasura.GraphQL.Schema.Build qualified as GS.B
import Hasura.GraphQL.Schema.Common qualified as GS.C
import Hasura.GraphQL.Schema.Parser qualified as P
import Hasura.GraphQL.Schema.Select qualified as GS.S
import Hasura.GraphQL.Schema.Table qualified as GS.T
import Hasura.GraphQL.Schema.Typename qualified as GS.N
import Hasura.GraphQL.Schema.Update qualified as GS.U
import Hasura.GraphQL.Schema.Update.Batch qualified as GS.U.B
import Hasura.Name qualified as Name
import Hasura.Prelude
import Hasura.RQL.IR.BoolExp qualified as IR
import Hasura.RQL.IR.Delete qualified as IR
import Hasura.RQL.IR.Insert qualified as IR
import Hasura.RQL.IR.Root qualified as IR
import Hasura.RQL.IR.Select qualified as IR
import Hasura.RQL.IR.Update qualified as IR
import Hasura.RQL.IR.Value qualified as IR
import Hasura.RQL.Types.Backend qualified as RQL
import Hasura.RQL.Types.BackendType (BackendType (..))
import Hasura.RQL.Types.Column qualified as RQL
import Hasura.RQL.Types.Common qualified as RQL
import Hasura.RQL.Types.ComputedField as RQL
import Hasura.RQL.Types.NamingCase
import Hasura.RQL.Types.Schema.Options qualified as Options
import Hasura.RQL.Types.Source qualified as RQL
import Hasura.RQL.Types.SourceCustomization qualified as RQL
import Hasura.Table.Cache qualified as RQL
import Language.GraphQL.Draft.Syntax qualified as GQL
import Witch qualified

--------------------------------------------------------------------------------

instance BackendSchema 'DataConnector where
  -- top level parsers
  buildTableQueryAndSubscriptionFields = GS.B.buildTableQueryAndSubscriptionFields

  buildTableRelayQueryFields = experimentalBuildTableRelayQueryFields

  buildFunctionQueryFields = buildFunctionQueryFields'
  buildFunctionRelayQueryFields _ _ _ _ _ = pure []
  buildFunctionMutationFields _ _ _ _ = pure []
  buildTableInsertMutationFields = buildTableInsertMutationFields'
  buildTableUpdateMutationFields = buildTableUpdateMutationFields'
  buildTableDeleteMutationFields = buildTableDeleteMutationFields'
  buildTableStreamingSubscriptionFields _ _ _ _ = pure []

  -- backend extensions
  relayExtension = Nothing
  nodesAggExtension = Just ()
  streamSubscriptionExtension = Nothing

  -- individual components
  columnParser = columnParser'
  enumParser = enumParser'
  possiblyNullable = possiblyNullable'
  scalarSelectionArgumentsParser _ = pure Nothing
  orderByOperators = orderByOperators'
  comparisonExps = comparisonExps'

  countTypeInput = countTypeInput'

  -- aggregateOrderByCountType is only used when generating Relay schemas, and Data Connector backends do not yet support Relay
  -- If/when we want to support this we would need to add something to Capabilities to tell HGE what (integer-like) scalar
  -- type should be used to represent the result of a count aggregate in relay order-by queries.
  aggregateOrderByCountType =
    error "aggregateOrderByCountType: not implemented for Data Connector backend"

  computedField =
    error "computedField: not implemented for the Data Connector backend."

instance BackendTableSelectSchema 'DataConnector where
  tableArguments = tableArgs'
  selectTable = GS.S.defaultSelectTable
  selectTableAggregate = GS.S.defaultSelectTableAggregate
  tableSelectionSet = GS.S.defaultTableSelectionSet

instance BackendUpdateOperatorsSchema 'DataConnector where
  type UpdateOperators 'DataConnector = DC.UpdateOperator

  parseUpdateOperators = parseUpdateOperators'

--------------------------------------------------------------------------------

buildFunctionQueryFields' ::
  forall r m n.
  ( MonadError QErr m,
    P.MonadMemoize m,
    MonadParse n,
    Has (RQL.SourceInfo 'DataConnector) r,
    Has GS.C.SchemaContext r,
    Has Options.SchemaOptions r
  ) =>
  RQL.MkRootFieldName ->
  DC.FunctionName ->
  RQL.FunctionInfo 'DataConnector ->
  DC.TableName ->
  GS.C.SchemaT
    r
    m
    [ P.FieldParser
        n
        ( IR.QueryDB
            'DataConnector
            (IR.RemoteRelationshipField IR.UnpreparedValue)
            (IR.UnpreparedValue 'DataConnector)
        )
    ]
buildFunctionQueryFields' mkRootFieldName functionName functionInfo tableName = do
  let -- Implementation modified from buildFunctionQueryFieldsPG
      funcDesc =
        Just
          . GQL.Description
          $ flip fromMaybe (RQL._fiComment functionInfo <|> RQL._fiDescription functionInfo)
          $ "execute function "
          <> functionName
          <<> " which returns "
          <>> tableName

      queryResultType =
        case RQL._fiJsonAggSelect functionInfo of
          RQL.JASMultipleRows -> IR.QDBMultipleRows
          RQL.JASSingleObject -> IR.QDBSingleRow

  catMaybes
    <$> sequenceA
      [ GS.C.optionalFieldParser queryResultType $ selectFunction mkRootFieldName functionInfo funcDesc
      -- TODO: Aggregations are not currently supported.
      -- See: GS.C.optionalFieldParser (QDBAggregation) $ selectFunctionAggregate mkRootFieldName functionInfo funcAggDesc
      ]

-- | User-defined function (AKA custom function) -- Modified from PG variant.
selectFunction ::
  forall r m n.
  ( MonadBuildSchema 'DataConnector r m n
  ) =>
  RQL.MkRootFieldName ->
  -- | SQL function info
  RQL.FunctionInfo 'DataConnector -> -- TODO: The function return type should have already been resolved by this point - Into TableName

  -- | field description, if any
  Maybe GQL.Description ->
  GS.C.SchemaT r m (Maybe (P.FieldParser n (GS.C.SelectExp 'DataConnector)))
selectFunction mkRootFieldName fi@RQL.FunctionInfo {..} description = runMaybeT do
  sourceInfo :: RQL.SourceInfo 'DataConnector <- asks getter
  roleName <- GS.C.retrieve GS.C.scRole
  let customization = RQL._siCustomization sourceInfo
      tCase = RQL._rscNamingConvention customization
  tableInfo <- lift $ GS.C.askTableInfo _fiReturnType
  selectPermissions <- hoistMaybe $ GS.T.tableSelectPermissions roleName tableInfo
  selectionSetParser <- MaybeT $ returnFunctionParser tableInfo
  lift do
    stringifyNumbers <- GS.C.retrieve Options.soStringifyNumbers
    tableArgsParser <- tableArguments tableInfo
    functionArgsParser <- customFunctionArgs fi _fiGQLName _fiGQLArgsName
    let argsParser = liftA2 (,) functionArgsParser tableArgsParser
        functionFieldName = RQL.runMkRootFieldName mkRootFieldName _fiGQLName
    pure
      $ P.subselection functionFieldName description argsParser selectionSetParser
      <&> \((funcArgs, tableArgs''), fields) ->
        IR.AnnSelectG
          { IR._asnFields = fields,
            IR._asnFrom = IR.FromFunction _fiSQLName funcArgs Nothing,
            IR._asnPerm = GS.S.tablePermissionsInfo selectPermissions,
            IR._asnArgs = tableArgs'',
            IR._asnStrfyNum = stringifyNumbers,
            IR._asnNamingConvention = Just tCase
          }
  where
    returnFunctionParser =
      case _fiJsonAggSelect of
        RQL.JASSingleObject -> tableSelectionSet
        RQL.JASMultipleRows -> GS.S.tableSelectionList

-- Modified version of the PG Reference: customSQLFunctionArgs.

-- | The custom SQL functions' input "args" field parser
-- > function_name(args: function_args)
customFunctionArgs ::
  (MonadBuildSchema 'DataConnector r m n) =>
  RQL.FunctionInfo 'DataConnector ->
  GQL.Name ->
  GQL.Name ->
  GS.C.SchemaT r m (P.InputFieldsParser n (RQL.FunctionArgsExp 'DataConnector (IR.UnpreparedValue 'DataConnector)))
customFunctionArgs RQL.FunctionInfo {..} functionName functionArgsName =
  functionArgs'
    ( FTACustomFunction
        $ RQL.CustomFunctionNames
          { cfnFunctionName = functionName,
            cfnArgsName = functionArgsName
          }
    )
    _fiInputArgs

-- NOTE: Modified version of server/src-lib/Hasura/Backends/Postgres/Schema/Select.hs ~ functionArgs
functionArgs' ::
  forall r m n.
  (MonadBuildSchema 'DataConnector r m n) =>
  FunctionTrackedAs 'DataConnector ->
  Seq.Seq (RQL.FunctionInputArgument 'DataConnector) ->
  GS.C.SchemaT r m (P.InputFieldsParser n (RQL.FunctionArgsExp 'DataConnector (IR.UnpreparedValue 'DataConnector)))
functionArgs' functionTrackedAs (toList -> inputArgs) = do
  sourceInfo :: RQL.SourceInfo 'DataConnector <- asks getter
  let customization = RQL._siCustomization sourceInfo
      tCase = RQL._rscNamingConvention customization
      mkTypename = GS.N.runMkTypename $ RQL._rscTypeNames customization
      (names, session, optional, mandatory) = mconcat $ snd $ mapAccumL splitArguments 1 inputArgs
      defaultArguments = RQL.FunctionArgsExp (snd <$> session) HashMap.empty
  if
    | length session > 1 ->
        throw500 "there shouldn't be more than one session argument"
    | null optional && null mandatory ->
        pure $ pure defaultArguments
    | otherwise -> do
        argumentParsers <- sequenceA $ optional <> mandatory
        objectName <-
          mkTypename
            . RQL.applyTypeNameCaseIdentifier tCase
            <$> case functionTrackedAs of
              FTAComputedField computedFieldName _sourceName tableName -> do
                tableInfo <- GS.C.askTableInfo tableName
                computedFieldGQLName <- GS.C.textToName $ computedFieldNameToText computedFieldName
                tableGQLName <- GS.T.getTableIdentifierName @'DataConnector tableInfo
                pure $ RQL.mkFunctionArgsTypeName computedFieldGQLName tableGQLName
              FTACustomFunction (CustomFunctionNames {cfnArgsName}) ->
                pure $ fromCustomName cfnArgsName
        let fieldName = Name._args
            fieldDesc =
              case functionTrackedAs of
                FTAComputedField computedFieldName _sourceName tableName ->
                  GQL.Description
                    $ "input parameters for computed field "
                    <> computedFieldName
                    <<> " defined on table "
                    <>> tableName
                FTACustomFunction (CustomFunctionNames {cfnFunctionName}) ->
                  GQL.Description $ "input parameters for function " <>> cfnFunctionName
            objectParser =
              P.object objectName Nothing (sequenceA argumentParsers) `P.bind` \arguments -> do
                let foundArguments = HashMap.fromList $ catMaybes arguments <> session
                    argsWithNames = zip names inputArgs

                -- All args have names in DC for now
                named <- HashMap.fromList . catMaybes <$> traverse (namedArgument foundArguments) argsWithNames
                pure $ RQL.FunctionArgsExp [] named

        pure $ P.field fieldName (Just fieldDesc) objectParser
  where
    sessionPlaceholder :: DC.ArgumentExp (IR.UnpreparedValue b)
    sessionPlaceholder = DC.AEInput IR.UVSession

    splitArguments ::
      Int ->
      RQL.FunctionInputArgument 'DataConnector ->
      ( Int,
        ( [Text], -- graphql names, in order
          [(Text, DC.ArgumentExp (IR.UnpreparedValue 'DataConnector))], -- session argument
          [GS.C.SchemaT r m (P.InputFieldsParser n (Maybe (Text, DC.ArgumentExp (IR.UnpreparedValue 'DataConnector))))], -- optional argument
          [GS.C.SchemaT r m (P.InputFieldsParser n (Maybe (Text, DC.ArgumentExp (IR.UnpreparedValue 'DataConnector))))] -- mandatory argument
        )
      )
    splitArguments positionalIndex (RQL.IASessionVariables name) =
      let argName = RQL.getFuncArgNameTxt name
       in (positionalIndex, ([argName], [(argName, sessionPlaceholder)], [], []))
    splitArguments positionalIndex (RQL.IAUserProvided arg@(API.FunctionArg faName _faType _faOptional)) =
      let (argName, newIndex) = (faName, positionalIndex) -- Names are currently always present
       in -- NOTE: Positional defaults are not implemented here, but named arguments should support this.
          -- See:  `if Postgres.unHasDefault $ Postgres.faHasDefault arg`
          (newIndex, ([argName], [], [], [parseArgument arg argName]))

    parseArgument :: RQL.FunctionArgument 'DataConnector -> Text -> GS.C.SchemaT r m (P.InputFieldsParser n (Maybe (Text, DC.ArgumentExp (IR.UnpreparedValue 'DataConnector))))
    parseArgument (API.FunctionArg faName faType _faOptional) name = do
      typedParser <- columnParser (RQL.ColumnScalar $ Witch.from faType) (GQL.Nullability True)
      fieldName <- GS.C.textToName name
      let argParser = P.fieldOptional fieldName Nothing typedParser
      pure $ argParser `GS.C.mapField` ((faName,) . DC.AEInput . IR.mkParameter)

    namedArgument ::
      HashMap Text (DC.ArgumentExp (IR.UnpreparedValue 'DataConnector)) ->
      (Text, RQL.FunctionInputArgument 'DataConnector) ->
      n (Maybe (Text, DC.ArgumentExp (IR.UnpreparedValue 'DataConnector)))
    namedArgument dictionary (name, inputArgument) = case inputArgument of
      RQL.IASessionVariables _ -> pure $ Just (name, sessionPlaceholder)
      RQL.IAUserProvided (API.FunctionArg _faName _faType faOptional) -> case HashMap.lookup name dictionary of
        Just parsedValue -> pure $ Just (name, parsedValue) -- Names are currently always present
        Nothing ->
          if faOptional
            then pure Nothing
            else P.parseErrorWith P.NotSupported "Non default arguments cannot be omitted"

buildTableInsertMutationFields' ::
  (MonadBuildSchema 'DataConnector r m n) =>
  RQL.MkRootFieldName ->
  GS.C.Scenario ->
  RQL.TableName 'DataConnector ->
  RQL.TableInfo 'DataConnector ->
  GQLNameIdentifier ->
  GS.C.SchemaT r m [P.FieldParser n (IR.AnnotatedInsert 'DataConnector (IR.RemoteRelationshipField IR.UnpreparedValue) (IR.UnpreparedValue 'DataConnector))]
buildTableInsertMutationFields' mkRootFieldName scenario tableName tableInfo gqlName = do
  API.Capabilities {..} <- DC._scCapabilities . RQL._siConfiguration @('DataConnector) <$> asks getter
  case _cMutations >>= API._mcInsertCapabilities of
    Just _insertCapabilities -> GS.B.buildTableInsertMutationFields mkBackendInsertParser mkRootFieldName scenario tableName tableInfo gqlName
    Nothing -> pure []

mkBackendInsertParser ::
  (MonadBuildSchema 'DataConnector r m n) =>
  RQL.TableInfo 'DataConnector ->
  GS.C.SchemaT r m (P.InputFieldsParser n (DC.BackendInsert (IR.UnpreparedValue 'DataConnector)))
mkBackendInsertParser _tableInfo =
  pure $ pure DC.BackendInsert

buildTableUpdateMutationFields' ::
  (MonadBuildSchema 'DataConnector r m n) =>
  GS.C.Scenario ->
  RQL.TableInfo 'DataConnector ->
  GQLNameIdentifier ->
  GS.C.SchemaT r m [P.FieldParser n (IR.AnnotatedUpdateG 'DataConnector (IR.RemoteRelationshipField IR.UnpreparedValue) (IR.UnpreparedValue 'DataConnector))]
buildTableUpdateMutationFields' scenario tableInfo gqlName = do
  API.Capabilities {..} <- DC._scCapabilities . RQL._siConfiguration @('DataConnector) <$> asks getter
  case _cMutations >>= API._mcUpdateCapabilities of
    Just _updateCapabilities -> do
      updateRootFields <- GS.B.buildSingleBatchTableUpdateMutationFields DC.SingleBatch scenario tableInfo gqlName
      updateManyRootField <- GS.U.B.updateTableMany DC.MultipleBatches scenario tableInfo gqlName
      pure $ updateRootFields ++ (maybeToList updateManyRootField)
    Nothing -> pure []

parseUpdateOperators' ::
  forall m n r.
  (MonadBuildSchema 'DataConnector r m n) =>
  RQL.TableInfo 'DataConnector ->
  RQL.UpdPermInfo 'DataConnector ->
  GS.C.SchemaT r m (P.InputFieldsParser n (HashMap (RQL.Column 'DataConnector) (DC.UpdateOperator (IR.UnpreparedValue 'DataConnector))))
parseUpdateOperators' tableInfo updatePermissions = do
  capabilities <- DC._scCapabilities . RQL._siConfiguration @('DataConnector) <$> asks getter
  let scalarTypeCapabilities = API.unScalarTypesCapabilities . API._cScalarTypes $ capabilities
  -- Group all the custom operators by operator name
  let customOperatorCapabilities =
        scalarTypeCapabilities
          & HashMap.toList
          >>= ( \(scalarType, API.ScalarTypeCapabilities {..}) ->
                  let scalarType' = Witch.from scalarType
                   in API.unUpdateColumnOperators _stcUpdateColumnOperators
                        & HashMap.toList
                        <&> (\(operatorName, operatorDefinition) -> HashMap.singleton operatorName (HashMap.singleton scalarType' operatorDefinition))
              )
          & HashMap.unionsWith (<>)
  let customOperators =
        customOperatorCapabilities
          & HashMap.toList
          <&> (\(operatorName, operatorUsages) -> DC.UpdateCustomOperator operatorName <$> updateCustomOp operatorName operatorUsages)
  GS.U.buildUpdateOperators
    (DC.UpdateSet <$> GS.U.presetColumns updatePermissions)
    ((DC.UpdateSet <$> GS.U.setOp) : customOperators)
    tableInfo

updateCustomOp ::
  forall m n r.
  (MonadBuildSchema 'DataConnector r m n) =>
  API.UpdateColumnOperatorName ->
  HashMap DC.ScalarType API.UpdateColumnOperatorDefinition ->
  GS.U.UpdateOperator 'DataConnector r m n (IR.UnpreparedValue 'DataConnector)
updateCustomOp (API.UpdateColumnOperatorName operatorName) operatorUsages = GS.U.UpdateOperator {..}
  where
    extractColumnScalarType :: RQL.ColumnInfo 'DataConnector -> Maybe DC.ScalarType
    extractColumnScalarType RQL.ColumnInfo {..} =
      case ciType of
        RQL.ColumnScalar columnScalarType -> Just columnScalarType
        RQL.ColumnEnumReference _enumReference -> Nothing

    updateOperatorApplicableColumn :: RQL.ColumnInfo 'DataConnector -> Bool
    updateOperatorApplicableColumn columnInfo =
      -- ColumnEnumReferences are not supported at this time
      extractColumnScalarType columnInfo
        <&> (\columnScalarType -> HashMap.member columnScalarType operatorUsages)
        & fromMaybe False

    -- Prepend the operator name with underscore
    operatorGraphqlFieldIdentifier :: GQLNameIdentifier
    operatorGraphqlFieldIdentifier =
      fromAutogeneratedName $ GQL.addSuffixes $$(GQL.litName "_") [GQL.convertNameToSuffix operatorName]

    updateOperatorParser ::
      GQLNameIdentifier ->
      RQL.TableName 'DataConnector ->
      NonEmpty (RQL.ColumnInfo 'DataConnector) ->
      GS.C.SchemaT r m (P.InputFieldsParser n (HashMap (RQL.Column 'DataConnector) (IR.UnpreparedValue 'DataConnector)))
    updateOperatorParser tableGQLName tableName columns = do
      let operatorIdentifier = fromAutogeneratedName operatorName

      let typedParser :: RQL.ColumnInfo 'DataConnector -> GS.C.SchemaT r m (P.Parser 'P.Both n (IR.UnpreparedValue 'DataConnector))
          typedParser columnInfo = do
            columnScalarType <- extractColumnScalarType columnInfo `onNothing` throw400 NotSupported "updateOperatorParser: Enum column types not supported"
            argumentType <-
              ( HashMap.lookup columnScalarType operatorUsages
                  <&> (\API.UpdateColumnOperatorDefinition {..} -> RQL.ColumnScalar $ Witch.from _ucodArgumentType)
                )
                -- This shouldn't happen 😬 because updateOperatorApplicableColumn should protect this
                -- parser from being used with unsupported column types
                `onNothing` throw500 ("updateOperatorParser: Unable to find argument type for update column operator " <> toTxt operatorName <> " used with column scalar type " <> toTxt columnScalarType)

            fmap IR.mkParameter
              <$> columnParser'
                argumentType
                (GQL.Nullability $ RQL.ciIsNullable columnInfo)

      GS.U.updateOperator
        tableGQLName
        operatorIdentifier
        operatorGraphqlFieldIdentifier
        typedParser
        columns
        (GQL.Description $ "applies the " <> toTxt operatorName <> " operator with the given values to the specified columns")
        (GQL.Description $ "input type for applying the " <> toTxt operatorName <> " operator to columns in table " <> toTxt tableName)

buildTableDeleteMutationFields' ::
  (MonadBuildSchema 'DataConnector r m n) =>
  RQL.MkRootFieldName ->
  GS.C.Scenario ->
  RQL.TableName 'DataConnector ->
  RQL.TableInfo 'DataConnector ->
  GQLNameIdentifier ->
  GS.C.SchemaT r m [P.FieldParser n (IR.AnnDelG 'DataConnector (IR.RemoteRelationshipField IR.UnpreparedValue) (IR.UnpreparedValue 'DataConnector))]
buildTableDeleteMutationFields' mkRootFieldName scenario tableName tableInfo gqlName = do
  API.Capabilities {..} <- DC._scCapabilities . RQL._siConfiguration @('DataConnector) <$> asks getter
  case _cMutations >>= API._mcDeleteCapabilities of
    Just _deleteCapabilities -> GS.B.buildTableDeleteMutationFields mkRootFieldName scenario tableName tableInfo gqlName
    Nothing -> pure []

experimentalBuildTableRelayQueryFields ::
  (MonadBuildSchema 'DataConnector r m n) =>
  RQL.MkRootFieldName ->
  RQL.TableName 'DataConnector ->
  RQL.TableInfo 'DataConnector ->
  GQLNameIdentifier ->
  NESeq (RQL.ColumnInfo 'DataConnector) ->
  GS.C.SchemaT r m [P.FieldParser n a]
experimentalBuildTableRelayQueryFields _mkRootFieldName _tableName _tableInfo _gqlName _pkeyColumns =
  pure []

columnParser' ::
  (MonadBuildSchema 'DataConnector r m n) =>
  RQL.ColumnType 'DataConnector ->
  GQL.Nullability ->
  GS.C.SchemaT r m (P.Parser 'P.Both n (IR.ValueWithOrigin (RQL.ColumnValue 'DataConnector)))
columnParser' columnType nullability = case columnType of
  RQL.ColumnScalar scalarType@(DC.ScalarType name) ->
    P.memoizeOn 'columnParser' (scalarType, nullability)
      $ GS.C.peelWithOrigin
      . fmap (RQL.ColumnValue columnType)
      . possiblyNullable' scalarType nullability
      <$> do
        gqlName <-
          GQL.mkName name
            `onNothing` throw400 ValidationFailed ("The column type name " <> name <<> " is not a valid GraphQL name")
        scalarTypesCapabilities <- GS.C.askScalarTypeParsingContext @'DataConnector
        let graphQLType = lookupGraphQLType scalarTypesCapabilities scalarType
        pure $ case graphQLType of
          Nothing -> P.jsonScalar gqlName (Just "A custom scalar type")
          Just DC.GraphQLInt -> (J.Number . fromIntegral) <$> P.namedInt gqlName
          Just DC.GraphQLFloat -> (J.Number . fromFloatDigits) <$> P.namedFloat gqlName
          Just DC.GraphQLString -> J.String <$> P.namedString gqlName
          Just DC.GraphQLBoolean -> J.Bool <$> P.namedBoolean gqlName
          Just DC.GraphQLID -> J.String <$> P.namedIdentifier gqlName
  RQL.ColumnEnumReference (RQL.EnumReference tableName enumValues customTableName) ->
    case nonEmpty (HashMap.toList enumValues) of
      Just enumValuesList ->
        GS.C.peelWithOrigin
          . fmap (RQL.ColumnValue columnType)
          <$> enumParser' tableName enumValuesList customTableName nullability
      Nothing -> throw400 ValidationFailed "empty enum values"

enumParser' ::
  (MonadError QErr m) =>
  RQL.TableName 'DataConnector ->
  NonEmpty (RQL.EnumValue, RQL.EnumValueInfo) ->
  Maybe GQL.Name ->
  GQL.Nullability ->
  GS.C.SchemaT r m (P.Parser 'P.Both n (RQL.ScalarValue 'DataConnector))
enumParser' _tableName _enumValues _customTableName _nullability =
  throw400 NotSupported "This column type is unsupported by the Data Connector backend"

possiblyNullable' ::
  (MonadParse m) =>
  RQL.ScalarType 'DataConnector ->
  GQL.Nullability ->
  P.Parser 'P.Both m J.Value ->
  P.Parser 'P.Both m J.Value
possiblyNullable' _scalarType (GQL.Nullability isNullable)
  | isNullable = fmap (fromMaybe J.Null) . P.nullable
  | otherwise = id

orderByOperators' :: RQL.SourceInfo 'DataConnector -> NamingCase -> (GQL.Name, NonEmpty (P.Definition P.EnumValueInfo, (RQL.BasicOrderType 'DataConnector, RQL.NullsOrderType 'DataConnector)))
orderByOperators' RQL.SourceInfo {_siConfiguration} _tCase =
  let dcName = DC._scDataConnectorName _siConfiguration
      orderBy = GQL.addSuffixes (DC.unDataConnectorName dcName) [$$(GQL.litSuffix "_order_by")]
   in (orderBy,)
        $
        -- NOTE: NamingCase is not being used here as we don't support naming conventions for this DB
        NE.fromList
          [ ( define $$(GQL.litName "asc") "in ascending order",
              (DC.Ascending, ())
            ),
            ( define $$(GQL.litName "desc") "in descending order",
              (DC.Descending, ())
            )
          ]
  where
    define name desc = P.Definition name (Just desc) Nothing [] P.EnumValueInfo

comparisonExps' ::
  forall m n r.
  (MonadBuildSchema 'DataConnector r m n) =>
  RQL.ColumnType 'DataConnector ->
  GS.C.SchemaT r m (P.Parser 'P.Input n [ComparisonExp 'DataConnector])
comparisonExps' columnType = do
  collapseIfNull <- GS.C.retrieve Options.soDangerousBooleanCollapse
  sourceInfo :: RQL.SourceInfo 'DataConnector <- asks getter
  let dataConnectorName = sourceInfo ^. RQL.siConfiguration . DC.scDataConnectorName
      tCase = RQL._rscNamingConvention $ RQL._siCustomization sourceInfo
  P.memoizeOn 'comparisonExps' (dataConnectorName, columnType) do
    typedParser <- columnParser' columnType (GQL.Nullability False)
    let name = GQL.addSuffixes (P.getName typedParser) [$$(GQL.litSuffix "_"), GQL.convertNameToSuffix (DC.unDataConnectorName dataConnectorName), $$(GQL.litSuffix "_comparison_exp")]
        desc =
          GQL.Description
            $ "Boolean expression to compare columns of type "
            <> P.getName typedParser
            <<> ". All fields are combined with logical 'AND'."
        columnListParser = fmap IR.openValueOrigin <$> P.list typedParser
    customOperators <- (fmap . fmap . fmap) IR.ABackendSpecific <$> mkCustomOperators sourceInfo tCase collapseIfNull (P.getName typedParser)
    pure
      $ P.object name (Just desc)
      $ fmap catMaybes
      $ sequenceA
      $ concat
        [ GS.BE.equalityOperators
            tCase
            collapseIfNull
            (IR.mkParameter <$> typedParser)
            (mkListLiteral <$> columnListParser),
          GS.BE.comparisonOperators
            tCase
            collapseIfNull
            (IR.mkParameter <$> typedParser),
          customOperators
        ]
  where
    mkListLiteral :: [RQL.ColumnValue 'DataConnector] -> IR.UnpreparedValue 'DataConnector
    mkListLiteral columnValues =
      IR.UVLiteral $ DC.ArrayLiteral (columnTypeToScalarType columnType) (RQL.cvValue <$> columnValues)

    mkCustomOperators ::
      RQL.SourceInfo 'DataConnector ->
      NamingCase ->
      Options.DangerouslyCollapseBooleans ->
      GQL.Name ->
      GS.C.SchemaT r m [P.InputFieldsParser n (Maybe (CustomBooleanOperator (IR.UnpreparedValue 'DataConnector)))]
    mkCustomOperators sourceInfo tCase collapseIfNull typeName = do
      let capabilities = sourceInfo ^. RQL.siConfiguration . DC.scCapabilities
      case HashMap.lookup (DC.fromGQLType typeName) (API.unScalarTypesCapabilities $ API._cScalarTypes capabilities) of
        Nothing -> pure []
        Just API.ScalarTypeCapabilities {..} -> do
          traverse (mkCustomOperator tCase collapseIfNull) $ HashMap.toList $ fmap Witch.from $ API.unComparisonOperators $ _stcComparisonOperators

    mkCustomOperator ::
      NamingCase ->
      Options.DangerouslyCollapseBooleans ->
      (GQL.Name, DC.ScalarType) ->
      GS.C.SchemaT r m (P.InputFieldsParser n (Maybe (CustomBooleanOperator (IR.UnpreparedValue 'DataConnector))))
    mkCustomOperator tCase collapseIfNull (operatorName, argType) = do
      argParser <- mkArgParser argType
      pure
        $ GS.BE.mkBoolOperator tCase collapseIfNull (fromCustomName operatorName) Nothing
        $ CustomBooleanOperator (GQL.unName operatorName)
        . Just
        . Right
        <$> argParser

    mkArgParser :: DC.ScalarType -> GS.C.SchemaT r m (P.Parser 'P.Both n (IR.UnpreparedValue 'DataConnector))
    mkArgParser argType =
      fmap IR.mkParameter
        <$> columnParser'
          (RQL.ColumnScalar argType)
          (GQL.Nullability True)

tableArgs' ::
  forall r m n.
  (MonadBuildSchema 'DataConnector r m n) =>
  RQL.TableInfo 'DataConnector ->
  GS.C.SchemaT r m (P.InputFieldsParser n (IR.SelectArgsG 'DataConnector (IR.UnpreparedValue 'DataConnector)))
tableArgs' tableInfo = do
  whereParser <- GS.S.tableWhereArg tableInfo
  orderByParser <- GS.S.tableOrderByArg tableInfo
  let mkSelectArgs whereArg orderByArg limitArg offsetArg =
        IR.SelectArgs
          { _saWhere = whereArg,
            _saOrderBy = orderByArg,
            _saLimit = limitArg,
            _saOffset = offsetArg,
            _saDistinct = Nothing
          }
  pure
    $ mkSelectArgs
    <$> whereParser
    <*> orderByParser
    <*> GS.S.tableLimitArg
    <*> GS.S.tableOffsetArg

countTypeInput' ::
  (MonadParse n) =>
  Maybe (P.Parser 'P.Both n DC.ColumnName) ->
  P.InputFieldsParser n (IR.CountDistinct -> DC.CountAggregate)
countTypeInput' = \case
  Just columnEnum -> mkCountAggregate <$> P.fieldOptional Name._column Nothing columnEnum
  Nothing -> pure $ mkCountAggregate Nothing
  where
    mkCountAggregate :: Maybe DC.ColumnName -> IR.CountDistinct -> DC.CountAggregate
    mkCountAggregate Nothing _ = DC.StarCount
    mkCountAggregate (Just column) IR.SelectCountDistinct = DC.ColumnDistinctCount column
    mkCountAggregate (Just column) IR.SelectCountNonDistinct = DC.ColumnCount column
