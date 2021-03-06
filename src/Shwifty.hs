{-# language
    AllowAmbiguousTypes
  , BangPatterns
  , CPP
  , DataKinds
  , DeriveFoldable
  , DeriveFunctor
  , DeriveGeneric
  , DeriveTraversable
  , DerivingStrategies
  , DuplicateRecordFields
  , FlexibleContexts
  , FlexibleInstances
  , GADTs
  , KindSignatures
  , LambdaCase
  , MultiParamTypeClasses
  , NamedFieldPuns
  , OverloadedStrings
  , PolyKinds
  , RecordWildCards
  , ScopedTypeVariables
  , TemplateHaskell
  , TypeApplications
  , TypeFamilies
  , ViewPatterns
#-}

{-# options_ghc
  -Wall
#-}

-- | The Shwifty library allows generation of
--   Swift types (structs and enums) from Haskell
--   ADTs, using Template Haskell. The main
--   entry point to the library should be
--   'getShwifty'.
module Shwifty
  ( -- * Classes for conversion
    ToSwift(..)
  , ToSwiftData(..)

    -- * Generating instances
  , getShwifty
  , getShwiftyWith

    -- * Types
  , Ty(..)
  , SwiftData(..)
  , Protocol(..)

    -- * Options for encoding types
    -- ** Option type
  , Options
    -- ** Actual Options
  , fieldLabelModifier
  , constructorModifier
  , optionalExpand
  , indent
  , generateToSwift
  , generateToSwiftData
  , dataProtocols
  , dataRawValue
    -- ** Default 'Options'
  , defaultOptions

    -- * Pretty-printing
  , prettyTy
  , prettySwiftData
  , prettySwiftDataWith
    -- ** Re-exports
  , X
  ) where

#include "MachDeps.h"

import Control.Monad.Except
import Data.CaseInsensitive (CI)
import Data.Foldable (foldlM,foldr',foldl')
import Data.Functor ((<&>))
import Data.Int (Int8,Int16,Int32,Int64)
import Data.List (intercalate)
import Data.List.NonEmpty ((<|), NonEmpty(..))
import Data.Maybe (mapMaybe, catMaybes)
import Data.Proxy (Proxy(..))
import Data.Vector (Vector)
import Data.Void (Void)
import Data.Word (Word8,Word16,Word32,Word64)
import GHC.Generics (Generic)
import GHC.TypeLits (Symbol, KnownSymbol, symbolVal)
import Language.Haskell.TH hiding (stringE)
import Language.Haskell.TH.Datatype
import Prelude hiding (Enum(..))
import Data.UUID.Types (UUID)
import Data.Time (UTCTime)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Char as Char
import qualified Data.List as L
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as M
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as TS
import qualified Data.Text.Lazy as TL

-- | An AST representing a Swift type.
data Ty
  = Unit
    -- ^ Unit (Unit/Void in swift). Empty struct type.
  | Bool
    -- ^ Bool
  | Character
    -- ^ Character
  | String
    -- ^ String
  | I
    -- ^ signed machine integer
  | I8
    -- ^ signed 8-bit integer
  | I16
    -- ^ signed 16-bit integer
  | I32
    -- ^ signed 32-bit integer
  | I64
    -- ^ signed 64-bit integer
  | U
    -- ^ unsigned machine integer
  | U8
    -- ^ unsigned 8-bit integer
  | U16
    -- ^ unsigned 16-bit integer
  | U32
    -- ^ unsigned 32-bit integer
  | U64
    -- ^ unsigned 64-bit integer
  | F32
    -- ^ 32-bit floating point
  | F64
    -- ^ 64-bit floating point
  | Decimal
    -- ^ Increased-precision floating point
  | BigSInt32
    -- ^ 32-bit big integer
  | BigSInt64
    -- ^ 64-bit big integer
  | UUID
    -- ^ UUID type
  | Date
    -- ^ Date
  | Tuple2 Ty Ty
    -- ^ 2-tuple
  | Tuple3 Ty Ty Ty
    -- ^ 3-tuple
  | Optional Ty
    -- ^ Maybe type
  | Result Ty Ty
    -- ^ Either type
  | Dictionary Ty Ty
    -- ^ Dictionary type
  | Array Ty
    -- ^ array type
  | App Ty Ty
    -- ^ function type
  | Poly String
    -- ^ polymorphic type variable
  | Concrete
      { name :: String
        -- ^ the name of the type
      , tyVars :: [Ty]
        -- ^ the type's type variables
      }
    -- ^ a concrete type variable, and its
    --   type variables. Will typically be generated
    --   by 'getShwifty'.
  deriving stock (Eq, Show, Read, Generic)

-- | A Swift datatype, either a struct (product type)
--   or enum (sum type). Haskll types are
--   sums-of-products, so the way we differentiate
--   when doing codegen,
--   is that types with a single constructor
--   will be converted to a struct, and those with
--   two or more constructors will be converted to an
--   enum. Types with 0 constructors
--   (such as Haskell's 'Void') are not allowed.
--
--   /Note/: There seems to be a haddock bug related
--   to `-XDuplicateRecordFields` which
--   causes the haddocks for the fields of 'SwiftEnum'
--   to refer to struct.
data SwiftData
  = SwiftStruct
      { name :: String
        -- ^ The name of the struct
      , tyVars :: [String]
        -- ^ The struct's type variables
      , protocols :: [Protocol]
        -- ^ The protocols which the struct
        --   implements
      , fields :: [(String, Ty)]
        -- ^ The fields of the struct. the pair
        --   is interpreted as (name, type).
      }
  | SwiftEnum
      { name :: String
        -- ^ The name of the enum
      , tyVars :: [String]
        -- ^ The enum's type variables
      , protocols :: [Protocol]
        -- ^ The protocols which the enum
        --   implements
      , cases :: [(String, [(Maybe String, Ty)])]
        -- ^ The cases of the enum. the type
        --   can be interpreted as
        --   (name, [(label, type)]).
      , rawValue :: Maybe Ty
        -- ^ The rawValue of an enum. See
        --   https://developer.apple.com/documentation/swift/rawrepresentable/1540698-rawvalue
        --
        --   Typically the 'Ty' will be
        --   'I' or 'String'.
        --
        --   /Note/: Currently, nothing will prevent
        --   you from putting something
        --   nonsensical here.
      }
  deriving stock (Eq, Read, Show, Generic)

-- | The class for things which can be converted to
--   'SwiftData'.
--
--   Typically the instance will be generated by
--   'getShwifty'.
class ToSwiftData a where
  toSwiftData :: Proxy a -> SwiftData

-- | Swift protocols.
--   Only a few are supported right now.
data Protocol
  = Hashable
    -- ^ The 'Hashable' protocol.
    --   See https://developer.apple.com/documentation/swift/hashable
  | Codable
    -- ^ The 'Codable' protocol.
    --   See https://developer.apple.com/documentation/swift/hashable
  | Equatable
    -- ^ The 'Equatable' protocol.
    --   See https://developer.apple.com/documentation/swift/hashable
  | Comparable
    -- ^ The 'Comparable' protocol.
    --   See https://developer.apple.com/documentation/swift/hashable
  deriving stock (Eq, Read, Show, Generic)

-- | Options that specify how to
--   encode your 'SwiftData' to a swift type.
--
--   Options can be set using record syntax on
--   'defaultOptions' with the fields below.
data Options = Options
  { fieldLabelModifier :: String -> String
    -- ^ Function applied to field labels.
    --   Handy for removing common record prefixes,
    --   for example. The default ('id') makes no
    --   changes.
  , constructorModifier :: String -> String
    -- ^ Function applied to constructor names.
    --   The default ('id') makes no changes.
  , optionalExpand :: Bool
    -- ^ Whether or not to truncate Optional types.
    --   Normally, an Optional ('Maybe') is encoded
    --   as "A?", which is syntactic sugar for
    --   "Optional<A>". The default value ('False')
    --   will keep it as sugar. A value of 'True'
    --   will expand it to be desugared.
  , indent :: Int
    -- ^ Number of spaces to indent field names
    --   and cases. The default is 4.
  , generateToSwift :: Bool
    -- ^ Whether or not to generate a 'ToSwift'
    --   instance. Sometime this can be desirable
    --   if you want to define the instance by hand,
    --   or the instance exists elsewhere.
    --   The default is 'True', i.e., to generate
    --   the instance.
  , generateToSwiftData :: Bool
    -- ^ Whether or not to generate a 'ToSwiftData'
    --   instance. Sometime this can be desirable
    --   if you want to define the instance by hand,
    --   or the instance exists elsewhere.
    --   The default is 'True', i.e., to generate
    --   the instance.
  , dataProtocols :: [Protocol]
    -- ^ Protocols to add to a type.
    --   The default ('[]') will add none.
  , dataRawValue :: Maybe Ty
    -- ^ The rawValue of an enum. See
    --   https://developer.apple.com/documentation/swift/rawrepresentable/1540698-rawvalue
    --
    --   The default ('Nothing') will not
    --   include any rawValue.
    --
    --   Typically, if the type does have
    --   a rawValue', the 'Ty' will be
    --   'I' or 'Str'.
    --
    --   /Note/: Currently, nothing will prevent
    --   you from putting something
    --   nonsensical here.
  }

-- | The default 'Options'.
--
-- @
-- defaultOptions :: Options
-- defaultOptions = Options
--   { fieldLabelModifier = id
--   , constructorModifier = id
--   , optionalExpand= False
--   , indent = 4
--   , generateToSwift = True
--   , generateToSwiftData = True
--   , dataProtocols = []
--   , dataRawValue = Nothing
--   }
-- @
--
defaultOptions :: Options
defaultOptions = Options
  { fieldLabelModifier = id
  , constructorModifier = id
  , optionalExpand = False
  , indent = 4
  , generateToSwift = True
  , generateToSwiftData = True
  , dataProtocols = []
  , dataRawValue = Nothing
  }

-- | The class for things which can be converted to
--   a Swift type ('Ty').
--
--   Typically the instance will be generated by
--   'getShwifty'.
class ToSwift a where
  toSwift :: Proxy a -> Ty

data SingSymbol (x :: Symbol)
instance KnownSymbol x => ToSwift (SingSymbol x) where
  toSwift _ = Poly (symbolVal (Proxy @x))

-- | A filler type to be used when pretty-printing.
--   The codegen used by shwifty doesn't look at
--   at what a type's type variables are instantiated
--   to, but rather at the type's top-level
--   definition. However,
--   to make GHC happy, you will have to fill in type
--   variables with unused types. To get around this,
--   you could also use something like
--   `-XQuantifiedConstraints`, or existential types,
--   but we leave that to the user to handle.
type X = Void

instance ToSwift () where
  toSwift = const Unit

instance ToSwift Bool where
  toSwift = const Bool

instance ToSwift UUID where
  toSwift = const UUID

instance ToSwift UTCTime where
  toSwift = const Date

instance forall a b. (ToSwift a, ToSwift b) => ToSwift (a -> b) where
  toSwift = const (App (toSwift (Proxy @a)) (toSwift (Proxy @b)))

instance forall a. ToSwift a => ToSwift (Maybe a) where
  toSwift = const (Optional (toSwift (Proxy @a)))

-- | /Note/: In Swift, the ordering of the type
--   variables is flipped - Shwifty has made the
--   design choice to flip them for you. If you
--   take issue with this, please open an issue
--   for discussion on GitHub.
instance forall a b. (ToSwift a, ToSwift b) => ToSwift (Either a b) where
  toSwift = const (Result (toSwift (Proxy @b)) (toSwift (Proxy @a)))

instance ToSwift Integer where
  toSwift = const
#if WORD_SIZE_IN_BITS == 32
    BigSInt32
#else
    BigSInt64
#endif

instance ToSwift Int   where toSwift = const I
instance ToSwift Int8  where toSwift = const I8
instance ToSwift Int16 where toSwift = const I16
instance ToSwift Int32 where toSwift = const I32
instance ToSwift Int64 where toSwift = const I64

instance ToSwift Word   where toSwift = const U
instance ToSwift Word8  where toSwift = const U8
instance ToSwift Word16 where toSwift = const U16
instance ToSwift Word32 where toSwift = const U32
instance ToSwift Word64 where toSwift = const U64

instance ToSwift Float  where toSwift = const F32
instance ToSwift Double where toSwift = const F64

instance ToSwift Char where toSwift = const Character

instance forall a. ToSwift a => ToSwift (Vector a) where
  toSwift = const (Array (toSwift (Proxy @a)))

instance {-# overlappable #-} forall a. ToSwift a => ToSwift [a] where
  toSwift = const (Array (toSwift (Proxy @a)))

instance {-# overlapping #-} ToSwift [Char] where toSwift = const String

instance ToSwift TL.Text where toSwift = const String
instance ToSwift TS.Text where toSwift = const String

instance ToSwift BL.ByteString where toSwift = const String
instance ToSwift BS.ByteString where toSwift = const String

instance ToSwift (CI s) where toSwift = const String

instance forall k v. (ToSwift k, ToSwift v) => ToSwift (M.Map k v) where toSwift = const (Dictionary (toSwift (Proxy @k)) (toSwift (Proxy @v)))

instance forall k v. (ToSwift k, ToSwift v) => ToSwift (HM.HashMap k v) where toSwift = const (Dictionary (toSwift (Proxy @k)) (toSwift (Proxy @v)))

instance forall a b. (ToSwift a, ToSwift b) => ToSwift ((,) a b) where
  toSwift = const (Tuple2 (toSwift (Proxy @a)) (toSwift (Proxy @b)))

instance forall a b c. (ToSwift a, ToSwift b, ToSwift c) => ToSwift ((,,) a b c) where
  toSwift = const (Tuple3 (toSwift (Proxy @a)) (toSwift (Proxy @b)) (toSwift (Proxy @c)))

labelCase :: Maybe String -> Ty -> String
labelCase Nothing ty = prettyTy ty
labelCase (Just label) ty = "_ " ++ label ++ ": " ++ prettyTy ty

prettyTypeHeader :: String -> [String] -> String
prettyTypeHeader name [] = name
prettyTypeHeader name tyVars = name ++ "<" ++ intercalate ", " tyVars ++ ">"

-- | Pretty-print a 'Ty'.
prettyTy :: Ty -> String
prettyTy = \case
  String -> "String"
  Unit -> "()"
  Bool -> "Bool"
  Character -> "Character"
  UUID -> "UUID"
  Date -> "Date"
  Tuple2 e1 e2 -> "(" ++ prettyTy e1 ++ ", " ++ prettyTy e2 ++ ")"
  Tuple3 e1 e2 e3 -> "(" ++ prettyTy e1 ++ ", " ++ prettyTy e2 ++ ", " ++ prettyTy e3 ++ ")"
  Optional e -> prettyTy e ++ "?"
  Result e1 e2 -> "Result<" ++ prettyTy e1 ++ ", " ++ prettyTy e2 ++ ">"
  Dictionary e1 e2 -> "Dictionary<" ++ prettyTy e1 ++ ", " ++ prettyTy e2 ++ ">"
  Array e -> "Array<" ++ prettyTy e ++ ">"
  App e1 e2 -> "((" ++ prettyTy e1 ++ ") -> " ++ prettyTy e2 ++ ")"
  I -> "Int"
  I8 -> "Int8"
  I16 -> "Int16"
  I32 -> "Int32"
  I64 -> "Int64"
  U -> "UInt"
  U8 -> "UInt8"
  U16 -> "UInt16"
  U32 -> "UInt32"
  U64 -> "UInt64"
  F32 -> "Float"
  F64 -> "Double"
  Decimal -> "Decimal"
  BigSInt32 -> "BigSInt32"
  BigSInt64 -> "BigSInt64"
  Poly ty -> ty
  Concrete ty [] -> ty
  Concrete ty tys -> ty
    ++ "<"
    ++ intercalate ", " (map prettyTy tys)
    ++ ">"

prettyRawValueAndProtocols :: Maybe Ty -> [Protocol] -> String
prettyRawValueAndProtocols Nothing ps = prettyProtocols ps
prettyRawValueAndProtocols (Just ty) [] = ": " ++ prettyTy ty
prettyRawValueAndProtocols (Just ty) ps = ": " ++ prettyTy ty ++ ", " ++ intercalate ", " (map show ps)

prettyProtocols :: [Protocol] -> String
prettyProtocols = \case
  [] -> ""
  ps -> ": " ++ intercalate ", " (map show ps)

-- | Pretty-print a 'SwiftData'.
prettySwiftData :: SwiftData -> String
prettySwiftData = prettySwiftDataWith defaultOptions

-- | Pretty-print a 'SwiftData'.
--   This function cares about indent.
prettySwiftDataWith :: Options -> SwiftData -> String
prettySwiftDataWith Options{indent} = \case

  SwiftEnum {name,tyVars,protocols,cases,rawValue} -> []
    ++ "enum "
    ++ prettyTypeHeader name tyVars
    ++ prettyRawValueAndProtocols rawValue protocols
    ++ " {\n"
    ++ go cases
    ++ "}"
    where
      go [] = ""
      go ((caseNm, []):xs) = []
        ++ indents
        ++ "case "
        ++ caseNm
        ++ "\n"
        ++ go xs
      go ((caseNm, cs):xs) = []
        ++ indents
        ++ "case "
        ++ caseNm
        ++ "("
        ++ (intercalate ", " (map (uncurry labelCase) cs))
        ++ ")\n"
        ++ go xs

  SwiftStruct {name,tyVars,protocols,fields} -> []
    ++ "struct "
    ++ prettyTypeHeader name tyVars
    ++ prettyProtocols protocols
    ++ " {"
    ++ (case fields of { [] -> " "; _ -> "\n" })
    ++ go fields
    ++ "}"
    where
      go [] = ""
      go ((fieldName,ty):fs) = indents ++ "let " ++ fieldName ++ ": " ++ prettyTy ty ++ "\n" ++ go fs
  where
    indents = replicate indent ' '

ensureEnabled :: Extension -> ShwiftyM ()
ensureEnabled ext = do
  enabled <- lift $ isExtEnabled ext
  unless enabled $ do
    throwError $ ExtensionNotEnabled ext

-- | Generate 'ToSwiftData' and 'ToSwift' instances
--   for your type. 'ToSwift' instances are typically
--   used to build cases or fields, whereas
--   'ToSwiftData' instances are for building structs
--   and enums. Click the 'Examples' button to see
--   examples of what Swift gets generated in
--   different scenarios. To get access to the
--   generated code, you will have to use one of
--   the pretty-printing functions provided.
--
-- === __Examples__
--
-- > -- A simple sum type
-- > data SumType = Sum1 | Sum2 | Sum3
-- > getShwifty ''SumType
--
-- @
-- enum SumType {
--     case sum1
--     case sum2
--     case sum3
-- }
-- @
--
-- > -- A simple product type
-- > data ProductType = ProductType { x :: Int, y :: Int }
-- > getShwifty ''ProductType
--
-- @
-- struct ProductType {
--     let x: Int
--     let y: Int
-- }
-- @
--
-- > -- A sum type with type variables
-- > data SumType a b = SumL a | SumR b
-- > getShwifty ''SumType
--
-- @
-- enum SumType\<A, B\> {
--     case sumL(A)
--     case sumR(B)
-- }
-- @
--
-- > -- A product type with type variables
-- > data ProductType a b = ProductType { aField :: a, bField :: b }
-- > getShwifty ''ProductType
--
-- @
-- struct ProductType\<A, B\> {
--     let aField: A
--     let bField: B
-- }
-- @
--
-- > -- A newtype
-- > newtype Newtype a = Newtype { getNewtype :: a }
-- > getShwifty ''Newtype
--
-- @
-- struct Newtype\<A\> {
--     let getNewtype: A
-- }
-- @
--
-- > -- A type with a function field
-- > newtype Endo a = Endo { appEndo :: a -> a }
-- > getShwifty ''Endo
--
-- @
-- struct Endo\<A\> {
--     let appEndo: ((A) -> A)
-- }
-- @
--
-- > -- A weird type with nested fields. Also note the Result's types being flipped from that of the Either.
-- > data YouveGotProblems a b = YouveGotProblems { field1 :: Maybe (Maybe (Maybe a)), field2 :: Either (Maybe a) (Maybe b) }
-- > getShwifty ''YouveGotProblems
--
-- @
-- struct YouveGotProblems\<A, B\> {
--     let field1: Option\<Option\<Option\<A\>\>\>
--     let field2: Result\<Option\<B\>,Option\<A\>\>
-- }
-- @
--
-- > -- A type with polykinded type variables
-- > data PolyKinded (a :: k) = PolyKinded
-- > getShwifty ''PolyKinded
--
-- @
-- struct PolyKinded\<A\> {
-- }
-- @
--
-- > -- A sum type where constructors might be records
-- > data SumType a b (c :: k) = Sum1 Int a (Maybe b) | Sum2 b | Sum3 { x :: Int, y :: Int }
-- > getShwifty ''SumType
--
-- @
-- enum SumType\<A, B, C\> {
--   case field1(Int, A, Optional\<B\>)
--   case field2(B)
--   case field3(_ x: Int, _ y: Int)
-- }
-- @
--
-- > -- A type containing another type with instance generated by 'getShwifty'
-- > newtype MyFirstType a = MyFirstType { getMyFirstType :: a }
-- > getShwifty ''MyFirstType
-- >
-- > data Contains a = Contains { x :: MyFirstType Int, y :: MyFirstType a }
-- > getShwifty ''Contains
--
-- @
-- struct MyFirstType\<A\> {
--   let getMyFirstType: A
-- }
--
-- struct Contains\<A\> {
--   let x: MyFirstType\<Int\>
--   let y: MyFirstType\<A\>
-- }
-- @
getShwifty :: Name -> Q [Dec]
getShwifty = getShwiftyWith defaultOptions

-- | Like 'getShwifty', but lets you supply
--   your own 'Options'. Usage:
--
-- @$(getShwiftyWith myOptions ''MyType)@
getShwiftyWith :: Options -> Name -> Q [Dec]
getShwiftyWith o@Options{generateToSwift,generateToSwiftData} name = do
  r <- runExceptT $ do
    ensureEnabled ScopedTypeVariables
    ensureEnabled DataKinds
    ensureEnabled DuplicateRecordFields
    DatatypeInfo
      { datatypeName = parentName
      , datatypeVars = tyVarBndrs
      , datatypeInstTypes = instTys
      , datatypeVariant = variant
      , datatypeCons = cons
      } <- lift $ reifyDatatype name
    noExistentials cons
    swiftDataInst <- if generateToSwiftData
      then do
        !instHeadData
          <- buildTypeInstance parentName ClassSwiftData instTys tyVarBndrs variant
        clauseData <- consToSwift o parentName instTys cons
        swiftDataInst <- lift $ instanceD
          (pure [])
          (pure instHeadData)
          [ funD 'toSwiftData
            [ clause [] (normalB (pure clauseData)) []
            ]
          ]
        pure [swiftDataInst]
      else pure []
    swiftTyInst <- if generateToSwift
      then do
        !instHeadTy
          <- buildTypeInstance parentName ClassSwift instTys tyVarBndrs variant
        clauseTy <- typToSwift parentName instTys
        swiftTyInst <- lift $ instanceD
          (pure [])
          (pure instHeadTy)
          [ funD 'toSwift
            [ clause [] (normalB (pure clauseTy)) []
            ]
          ]
        pure [swiftTyInst]
      else pure []
    pure $ swiftDataInst ++ swiftTyInst
  case r of
    Left e -> fail $ prettyShwiftyError e
    Right d -> pure d

noExistentials :: [ConstructorInfo] -> ShwiftyM ()
noExistentials cs = forM_ cs $ \ConstructorInfo{..} ->
  case (constructorName, constructorVars) of
    (_, []) -> do
      pure ()
    (cn, cvs) -> do
      throwError $ ExistentialTypes cn cvs

data ShwiftyError
  = VoidType
      { _typName :: Name
      }
  | SingleConNonRecord
      { _conName :: Name
      }
  | EncounteredInfixConstructor
      { _conName :: Name
      }
  | KindVariableCannotBeRealised
      { _typName :: Name
      , _kind :: Kind
      }
  | ExtensionNotEnabled
      { _ext :: Extension
      }
  | ExistentialTypes
      { _conName :: Name
      , _types :: [TyVarBndr]
      }

prettyShwiftyError :: ShwiftyError -> String
prettyShwiftyError = \case
  VoidType (nameStr -> n) -> mempty
    ++ n
    ++ ": Cannot get shwifty with void types. "
    ++ n ++ " has no constructors. Try adding some!"
  SingleConNonRecord (nameStr -> n) -> mempty
    ++ n
    ++ ": Cannot get shwifty with single-constructor "
    ++ "non-record types. This is due to a "
    ++ "restriction of Swift that prohibits structs "
    ++ "from not having named fields. Try turning "
    ++ n ++ " into a record!"
  EncounteredInfixConstructor (nameStr -> n) -> mempty
    ++ n
    ++ ": Cannot get shwifty with infix constructors. "
    ++ "Swift doesn't support them. Try changing "
    ++ n ++ " into a prefix constructor!"
  KindVariableCannotBeRealised (nameStr -> n) typ ->
    let (typStr, kindStr) = prettyKindVar typ
    in mempty
      ++ n
      ++ ": Encountered a type variable ("
      ++ typStr
      ++ ") with a kind ("
      ++ kindStr
      ++ ") that can't "
      ++ "get shwifty! Shwifty needs to be able "
      ++ "to realise your kind variables to `*`, "
      ++ "since that's all that makes sense in "
      ++ "Swift. The only kinds that can happen with "
      ++ "are `*` and the free-est kind, `k`."
  ExtensionNotEnabled ext -> mempty
    ++ show ext
    ++ " is not enabled. Shwifty needs it to work!"
  -- TODO: make this not print out implicit kinds.
  -- e.g. for `data Ex = forall x. Ex x`, there are
  -- no implicit `TyVarBndr`s, but for
  -- `data Ex = forall x y z. Ex x`, there are two:
  -- the kinds inferred by `y` and `z` are both `k`.
  -- We print these out - this could be confusing to
  -- the end user. I'm not immediately certain how to
  -- be rid of them.
  ExistentialTypes (nameStr -> n) tys -> mempty
    ++ n
    ++ " has existential type variables ("
    ++ L.intercalate ", " (map prettyTyVarBndrStr tys)
    ++ ")! Shwifty doesn't support these."

prettyTyVarBndrStr :: TyVarBndr -> String
prettyTyVarBndrStr = \case
  PlainTV n -> go n
  KindedTV n _ -> go n
  where
    go = TS.unpack . head . TS.splitOn "_" . last . TS.splitOn "." . TS.pack . show

-- prettify the type and kind.
prettyKindVar :: Type -> (String, String)
prettyKindVar = \case
  SigT typ k -> (go typ, go k)
  VarT n -> (nameStr n, "*")
  typ -> error $ "Shwifty.prettyKindVar: used on a type without a kind signature. Type was: " ++ show typ
  where
    go = TS.unpack . head . TS.splitOn "_" . last . TS.splitOn "." . TS.pack . show . ppr

type ShwiftyM = ExceptT ShwiftyError Q

typToSwift :: ()
  => Name
     -- ^ name of the type
  -> [Type]
     -- ^ type variables
  -> ShwiftyM Exp
typToSwift parentName instTys = do
  -- TODO: use '_' instead of matching
  value <- lift $ newName "value"
  let tyVars = map toSwiftECxt instTys
  matches <- lift $ fmap ((:[]) . pure) $ do
    match
      (conP 'Proxy [])
      (normalB
        $ pure
        $ RecConE 'Concrete
        $ [ (mkName "name", unqualName parentName)
          , (mkName "tyVars", ListE tyVars)
          ]
      )
      []
  lift $ lamE [varP value] (caseE (varE value) matches)

rawValueE :: Maybe Ty -> Exp
rawValueE = \case
  Nothing -> ConE 'Nothing
  Just ty -> AppE (ConE 'Just) (ParensE (tyE ty))

-- god this is annoying. write a cleaner
-- version of this
tyE :: Ty -> Exp
tyE = \case
  Unit -> ConE 'Unit
  Bool -> ConE 'Bool
  Character -> ConE 'Character
  UUID -> ConE 'UUID
  Date -> ConE 'Date
  String -> ConE 'String
  I -> ConE 'I
  I8 -> ConE 'I8
  I16 -> ConE 'I16
  I32 -> ConE 'I32
  I64 -> ConE 'I64
  U -> ConE 'U
  U8 -> ConE 'U8
  U16 -> ConE 'U16
  U32 -> ConE 'U32
  U64 -> ConE 'U64
  F32 -> ConE 'F32
  F64 -> ConE 'F64
  Decimal -> ConE 'Decimal
  BigSInt32 -> ConE 'BigSInt32
  BigSInt64 -> ConE 'BigSInt64
  Poly s -> AppE (ConE 'Poly) (stringE s)
  Concrete tyCon tyVars -> AppE (AppE (ConE 'Concrete) (stringE tyCon)) (ListE (map tyE tyVars))
  Tuple2 e1 e2 -> AppE (AppE (ConE 'Tuple2) (tyE e1)) (tyE e2)
  Tuple3 e1 e2 e3 -> AppE (AppE (AppE (ConE 'Tuple3) (tyE e1)) (tyE e2)) (tyE e3)
  Optional e -> AppE (ConE 'Optional) (tyE e)
  Result e1 e2 -> AppE (AppE (ConE 'Result) (tyE e1)) (tyE e2)
  Dictionary e1 e2 -> AppE (AppE (ConE 'Dictionary) (tyE e1)) (tyE e2)
  App e1 e2 -> AppE (AppE (ConE 'App) (tyE e1)) (tyE e2)
  Array e -> AppE (ConE 'Array) (tyE e)

consToSwift :: ()
  => Options
     -- ^ options about how to encode things
  -> Name
     -- ^ name of type (used for Enums only)
  -> [Type]
     -- ^ type variables
  -> [ConstructorInfo]
     -- ^ constructors
  -> ShwiftyM Exp
consToSwift o@Options{dataProtocols,dataRawValue} parentName instTys = \case
  [] -> do
    throwError $ VoidType parentName
  cons -> do
    -- TODO: use '_' instead of matching
    value <- lift $ newName "value"
    matches <- matchesWorker
    lift $ lamE [varP value] (caseE (varE value) matches)
    where
      -- bad name
      matchesWorker :: ShwiftyM [Q Match]
      matchesWorker = case cons of
        [con] -> do
          ((:[]) . pure) <$> mkProd o parentName instTys con
        _ -> do
          let tyVars = prettyTyVars instTys
          let protos = map (ConE . mkName . show) dataProtocols
          let raw = rawValueE dataRawValue
          cases <- forM cons (liftEither . mkCase o)
          pure $ (:[]) $ match
            (conP 'Proxy [])
            (normalB
               $ pure
               $ RecConE 'SwiftEnum
               $ [ (mkName "name", unqualName parentName)
                 , (mkName "tyVars", tyVars)
                 , (mkName "protocols", ListE protos)
                 , (mkName "cases", ListE cases)
                 , (mkName "rawValue", raw)
                 ]
            )
            []

mkCaseHelper :: Options -> Name -> [Exp] -> Exp
mkCaseHelper o name es = TupE [ caseName o name, ListE es ]

mkCase :: Options -> ConstructorInfo -> Either ShwiftyError Exp
mkCase o = \case
  -- non-record
  ConstructorInfo
    { constructorVariant = NormalConstructor
    , constructorName = name
    , constructorFields = fields
    , ..
    } -> Right $ mkCaseHelper o name $ fields <&>
        (\typ -> TupE
          [ ConE 'Nothing
          , toSwiftEPoly typ
          ]
        )
  ConstructorInfo
    { constructorVariant = InfixConstructor
    , constructorName = name
    , ..
    } -> Left $ EncounteredInfixConstructor name
  -- records
  -- we turn names into labels
  ConstructorInfo
    { constructorVariant = RecordConstructor fieldNames
    , constructorName = name
    , constructorFields = fields
    , ..
    } ->
       let cases = zipWith (caseField o) fieldNames fields
       in Right $ mkCaseHelper o name cases

caseField :: Options -> Name -> Type -> Exp
caseField o n typ = TupE
  [ mkLabel o n
  , toSwiftEPoly typ
  ]

mkLabel :: Options -> Name -> Exp
mkLabel Options{fieldLabelModifier} = AppE (ConE 'Just)
  . stringE
  . fieldLabelModifier
  . onHead Char.toLower
  . TS.unpack
  . last
  . TS.splitOn "."
  . TS.pack
  . show

mkProd :: Options -> Name -> [Type] -> ConstructorInfo -> ShwiftyM Match
mkProd o@Options{dataProtocols} typName instTys = \case
  -- single constructor, no fields
  ConstructorInfo
    { constructorVariant = NormalConstructor
    , constructorFields = []
    , ..
    } -> do
      let tyVars = prettyTyVars instTys
      let protos = map (ConE . mkName . show) dataProtocols
      lift $ match
        (conP 'Proxy [])
        (normalB
          $ pure
          $ RecConE 'SwiftStruct
          $ [ (mkName "name", unqualName typName)
            , (mkName "tyVars", tyVars)
            , (mkName "protocols", ListE protos)
            , (mkName "fields", ListE [])
            ]
        )
        []
  -- single constructor, non-record (Normal)
  ConstructorInfo
    { constructorVariant = NormalConstructor
    , constructorName = name
    } -> do
      throwError $ SingleConNonRecord name
  -- single constructor, non-record (Infix)
  ConstructorInfo
    { constructorVariant = InfixConstructor
    , constructorName = name
    } -> do
      throwError $ EncounteredInfixConstructor name
  -- single constructor, record
  ConstructorInfo
    { constructorVariant = RecordConstructor fieldNames
    , ..
    } -> do
      let tyVars = prettyTyVars instTys
      let protos = map (ConE . mkName . show) dataProtocols
      let fields = ListE $ zipWith (prettyField o) fieldNames constructorFields
      lift $ match
        (conP 'Proxy [])
        (normalB
          $ pure
          $ RecConE 'SwiftStruct
          $ [ (mkName "name", unqualName typName)
            , (mkName "tyVars", tyVars)
            , (mkName "protocols", ListE protos)
            , (mkName "fields", fields)
            ]
        )
        []

-- turn a field name into a swift case name.
-- examples:
--
--   data Foo = A | B | C
--   =>
--   enum Foo {
--     case a
--     case b
--     case c
--   }
--
--   data Bar a = MkBar1 a | MkBar2
--   =>
--   enum Bar<A> {
--     case mkBar1(A)
--     case mkBar2
--   }
caseName :: Options -> Name -> Exp
caseName Options{constructorModifier} = stringE . constructorModifier . onHead Char.toLower . TS.unpack . last . TS.splitOn "." . TS.pack . show

-- apply a function only to the head of a string
onHead :: (Char -> Char) -> String -> String
onHead f = \case { [] -> []; (x:xs) -> f x : xs }

-- remove qualifiers from a name, turn into String
nameStr :: Name -> String
nameStr = TS.unpack . last . TS.splitOn "." . TS.pack . show

-- remove qualifiers from a name, turn into Exp
unqualName :: Name -> Exp
unqualName = stringE . nameStr

-- prettify a type variable as an Exp
prettyTyVar :: Name -> Exp
prettyTyVar = stringE . map Char.toUpper . TS.unpack . head . TS.splitOn "_" . last . TS.splitOn "." . TS.pack . show

-- prettify a bunch of type variables as an Exp
prettyTyVars :: [Type] -> Exp
prettyTyVars = ListE . map prettyTyVar . getTyVars

-- get the free type variables from many types
getTyVars :: [Type] -> [Name]
getTyVars = mapMaybe getFreeTyVar

-- get the free type variables in a type
getFreeTyVar :: Type -> Maybe Name
getFreeTyVar = \case
  VarT name -> Just name
  SigT (VarT name) _kind -> Just name
  _ -> Nothing

-- make a struct field pretty
prettyField :: Options -> Name -> Type -> Exp
prettyField Options{fieldLabelModifier} name ty = TupE
  [ (stringE (onHead Char.toLower (fieldLabelModifier (nameStr name))))
  , toSwiftEPoly ty
  ]

-- build the instance head for a type
buildTypeInstance :: ()
  => Name
     -- ^ name of the type
  -> ShwiftyClass
     -- ^ which class instance head we are building
  -> [Type]
     -- ^ type variables
  -> [TyVarBndr]
     -- ^ the binders for our tyvars
  -> DatatypeVariant
     -- ^ variant (datatype, newtype, data family, newtype family)
  -> ShwiftyM Type
buildTypeInstance tyConName cls varTysOrig tyVarBndrs variant = do
  -- Make sure to expand through type/kind synonyms!
  -- Otherwise, the eta-reduction check might get
  -- tripped up over type variables in a synonym
  -- that are actually dropped.
  -- (See GHC Trac #11416 for a scenario where this
  -- actually happened)
  varTysExp <- lift $ mapM resolveTypeSynonyms varTysOrig

  -- get the kind status of all of our types.
  -- we must realise them all to *.
  starKindStats :: [KindStatus] <- foldlM
    (\stats k -> case canRealiseKindStar k of
      NotKindStar -> do
        throwError $ KindVariableCannotBeRealised tyConName k
      s -> pure (stats ++ [s])
    ) [] varTysExp

  let -- get the names of our kind vars
      kindVarNames :: [Name]
      kindVarNames = flip mapMaybe starKindStats
        (\case
            IsKindVar n -> Just n
            _ -> Nothing
        )

  let
      -- instantiate polykinded things to star.
      varTysExpSubst :: [Type]
      varTysExpSubst = map (substNamesWithKindStar kindVarNames) varTysExp

      -- the constraints needed on type variables
      preds :: [Maybe Pred]
      preds = map (deriveConstraint cls) varTysExpSubst

      -- We now sub all of the specialised-to-* kind
      -- variable names with *, but in the original types,
      -- not the synonym-expanded types. The reason we
      -- do this is superficial: we want the derived
      -- instance to resemble the datatype written in
      -- source code as closely as possible. For example,
      --
      --   data family Fam a
      --   newtype instance Fam String = Fam String
      --
      -- We'd want to generate the instance:
      --
      --   instance C (Fam String)
      --
      -- Not:
      --
      --   instance C (Fam [Char])
      varTysOrigSubst :: [Type]
      varTysOrigSubst =
        map (substNamesWithKindStar kindVarNames) $ varTysOrig

      -- are we working on a data family
      -- or newtype family?
      isDataFamily :: Bool
      isDataFamily = case variant of
        Datatype -> False
        Newtype -> False
        DataInstance -> True
        NewtypeInstance -> True

      -- if we are working on a data family
      -- or newtype family, we need to peel off
      -- the kinds. See Note [Kind signatures in
      -- derived instances]
      varTysOrigSubst' :: [Type]
      varTysOrigSubst' = if isDataFamily
        then varTysOrigSubst
        else map unSigT varTysOrigSubst

      -- the constraints needed on type variables
      -- makes up the constraint part of the
      -- instance head.
      instanceCxt :: Cxt
      instanceCxt = catMaybes preds

      -- the class and type in the instance head.
      instanceType :: Type
      instanceType = AppT (ConT (shwiftyClassName cls))
        $ applyTyCon tyConName varTysOrigSubst'

  -- forall <tys>. ctx tys => Cls ty
  lift $ forallT
    (map tyVarBndrNoSig tyVarBndrs)
    (pure instanceCxt)
    (pure instanceType)

-- the class we're generating an instance of
data ShwiftyClass = ClassSwift | ClassSwiftData

-- turn a 'ShwiftyClass' into a 'Name'
shwiftyClassName :: ShwiftyClass -> Name
shwiftyClassName = \case
  ClassSwift -> ''ToSwift
  ClassSwiftData -> ''ToSwiftData

-- derive the constraint needed on a type variable
-- in order to build the instance head for a class.
deriveConstraint :: ()
  => ShwiftyClass
     -- ^ class name
  -> Type
     -- ^ type
  -> Maybe Pred
     -- ^ constraint on type
deriveConstraint c@ClassSwift typ
  | not (isTyVar typ) = Nothing
  | hasKindStar typ = Just (applyCon (shwiftyClassName c) tName)
  | otherwise = Nothing
  where
    tName :: Name
    tName = varTToName typ
    varTToName = \case
      VarT n -> n
      SigT t _ -> varTToName t
      _ -> error "Shwifty.varTToName: encountered non-type variable"
deriveConstraint ClassSwiftData _ = Nothing

-- apply a type constructor to a type variable.
-- this can be useful for letting the kind
-- inference engine doing work for you. see
-- 'toSwiftECxt' for an example of this.
applyCon :: Name -> Name -> Pred
applyCon con t = AppT (ConT con) (VarT t)

-- peel off a kind signature from a Type
unSigT :: Type -> Type
unSigT = \case
  SigT t _ -> t
  t -> t

-- is the type a type variable?
isTyVar :: Type -> Bool
isTyVar = \case
  VarT _ -> True
  SigT t _ -> isTyVar t
  _ -> False

-- does the type have kind *?
hasKindStar :: Type -> Bool
hasKindStar = \case
  VarT _ -> True
  SigT _ StarT -> True
  _ -> False

-- perform the substitution of type variables
-- who have kinds which can be realised to *,
-- with the same type variable where its kind
-- has been turned into *
substNamesWithKindStar :: [Name] -> Type -> Type
substNamesWithKindStar ns t = foldr' (`substNameWithKind` starK) t ns
  where
    substNameWithKind :: Name -> Kind -> Type -> Type
    substNameWithKind n k = applySubstitution (M.singleton n k)

-- | The status of a kind variable w.r.t. its
--   ability to be realised into *.
data KindStatus
  = KindStar
    -- ^ kind * (or some k which can be realised to *)
  | NotKindStar
    -- ^ any other kind
  | IsKindVar Name
    -- ^ is actually a kind variable
  | IsCon Name
    -- ^ is a constructor - this will typically
    --   happen in a data family instance, because
    --   we often have to construct a
    --   FlexibleInstance. our old check for
    --   `canRealiseKindStar` didn't check for
    --   `ConT` - where this would happen.

-- can we realise the type's kind to *?
canRealiseKindStar :: Type -> KindStatus
canRealiseKindStar = \case
  VarT{} -> KindStar
  SigT _ StarT -> KindStar
  SigT _ (VarT n) -> IsKindVar n
  ConT n -> IsCon n
  _ -> NotKindStar

-- discard the kind signature from a TyVarBndr.
tyVarBndrNoSig :: TyVarBndr -> TyVarBndr
tyVarBndrNoSig = \case
  PlainTV n -> PlainTV n
  KindedTV n _k -> PlainTV n

-- fully applies a type constructor to its
-- type variables
applyTyCon :: Name -> [Type] -> Type
applyTyCon = foldl' AppT . ConT

-- Turn a String into an Exp string literal
stringE :: String -> Exp
stringE = LitE . StringL

-- convert a type into a 'Ty'.
-- we respect constraints here - e.g. in
-- `(Swift a, Swift b) => Swift (Foo a b)`,
-- we don't just fill in holes like in
-- `toSwiftEPoly`, we actually turn `a`
-- and `b` into `Ty`s directly. Consequently,
-- the implementation is much simpler - just
-- an application.
--
-- Note the use of unSigT - see Note
-- [Kind signatures in derived instances].
toSwiftECxt :: Type -> Exp
toSwiftECxt (unSigT -> typ) = AppE
  (VarE 'toSwift)
  (SigE (ConE 'Proxy) (AppT (ConT ''Proxy) typ))

-- convert a type into a 'Ty'.
-- polymorphic types do not require a 'swift'
-- instance, since we fill them in with 'SingSymbol'.
--
-- We do this by stretching out a type along its spine,
-- completely. we then fill in any polymorphic
-- variables with 'SingSymbol', relfecting the type
-- Name to a Symbol. then we compress the spine to
-- get the original type. the 'Swift' instance for
-- 'SingSymbol' gets us where we need to go.
--
-- Note that @compress . decompress@ is not
-- actually equivalent to the identity function on
-- Type because of ForallT, where we discard some
-- context. However, for any types we care about,
-- there shouldn't be a ForallT, so this *should*
-- be fine.
toSwiftEPoly :: Type -> Exp
toSwiftEPoly = \case
  -- we don't need to special case VarT and SigT
  VarT n
    -> AppE (ConE 'Poly) (prettyTyVar n)
  SigT (VarT n) _
    -> AppE (ConE 'Poly) (prettyTyVar n)
  typ ->
    let decompressed = decompress typ
        prettyName = map Char.toUpper . TS.unpack . head . TS.splitOn "_" . last . TS.splitOn "." . TS.pack . show
        filledInHoles = decompressed <&>
          (\case
            VarT name -> AppT
              (ConT ''Shwifty.SingSymbol)
              (LitT (StrTyLit (prettyName name)))
            SigT (VarT name) _ -> AppT
              (ConT ''Shwifty.SingSymbol)
              (LitT (StrTyLit (prettyName name)))
            t -> t
          )
        typ' = compress filledInHoles
     in AppE
      (VarE 'toSwift)
      (SigE (ConE 'Proxy) (AppT (ConT ''Proxy) typ'))

decompress :: Type -> Rose Type
decompress typ = case unapplyTy typ of
  tyCon :| tyArgs -> Rose tyCon (decompress <$> tyArgs)

compress :: Rose Type -> Type
compress (Rose typ []) = typ
compress (Rose t ts) = foldl' AppT t (compress <$> ts)

unapplyTy :: Type -> NonEmpty Type
unapplyTy = NE.reverse . go
  where
    go = \case
      AppT t1 t2 -> t2 <| go t1
      SigT t _ -> go t
      ForallT _ _ t -> go t
      t -> t :| []

-- | Types can be stretched out into a Rose tree.
--   decompress will stretch a type out completely,
--   in such a way that it cannot be stretched out
--   further. compress will reconstruct a type from
--   its stretched form.
--
--   Also note that this is equivalent to
--   Cofree NonEmpty Type.
--
--   Examples:
--
--   Maybe a
--   =>
--   AppT (ConT Maybe) (VarT a)
--
--
--   Either a b
--   =>
--   AppT (AppT (ConT Either) (VarT a)) (VarT b)
--   =>
--   Rose (ConT Either)
--     [ Rose (VarT a)
--         [
--         ]
--     , Rose (VarT b)
--         [
--         ]
--     ]
--
--
--   Either (Maybe a) (Maybe b)
--   =>
--   AppT (AppT (ConT Either) (AppT (ConT Maybe) (VarT a))) (AppT (ConT Maybe) (VarT b))
--   =>
--   Rose (ConT Either)
--     [ Rose (ConT Maybe)
--         [ Rose (VarT a)
--             [
--             ]
--         ]
--     , Rose (ConT Maybe)
--         [ Rose (VarT b)
--             [
--             ]
--         ]
--     ]
data Rose a = Rose a [Rose a]
  deriving stock (Eq, Show)
  deriving stock (Functor,Foldable,Traversable)

{-
Note [Kind signatures in derived instances]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

It is possible to put explicit kind signatures into the derived instances, e.g.,

  instance C a => C (Data (f :: * -> *)) where ...

But it is preferable to avoid this if possible. If we come up with an incorrect
kind signature (which is entirely possible, since Template Haskell doesn't always
have the best track record with reifying kind signatures), then GHC will flat-out
reject the instance, which is quite unfortunate.

Plain old datatypes have the advantage that you can avoid using any kind signatures
at all in their instances. This is because a datatype declaration uses all type
variables, so the types that we use in a derived instance uniquely determine their
kinds. As long as we plug in the right types, the kind inferencer can do the rest
of the work. For this reason, we use unSigT to remove all kind signatures before
splicing in the instance context and head.

Data family instances are trickier, since a data family can have two instances that
are distinguished by kind alone, e.g.,

  data family Fam (a :: k)
  data instance Fam (a :: * -> *)
  data instance Fam (a :: *)

If we dropped the kind signatures for C (Fam a), then GHC will have no way of
knowing which instance we are talking about. To avoid this scenario, we always
include explicit kind signatures in data family instances. There is a chance that
the inferred kind signatures will be incorrect, in which case we have to write the instance manually.
-}
