{-| Module      :  DerivingShow
    License     :  GPL

    Maintainer  :  helium@cs.uu.nl
    Stability   :  experimental
    Portability :  portable
-}

module Helium.CodeGeneration.DerivingShow
    ( dataShowFunction
    , typeShowFunction
    , dataDictionary
    , nameOfShowFunction, typeOfShowFunction, showFunctionOfType
    ) where

import qualified Helium.Syntax.UHA_Syntax as UHA
import Helium.Syntax.UHA_Utils
import Helium.CodeGeneration.CoreUtils
import Lvm.Core.Expr
import Lvm.Core.Utils
import Lvm.Common.Id
import Helium.Utils.Utils
import Top.Types

-- Show function for a data type declaration
dataShowFunction :: UHA.Declaration -> CoreDecl
dataShowFunction (UHA.Declaration_Data _ _ (UHA.SimpleType_SimpleType _ name names) constructors _) =
    let typeString = show (typeOfShowFunction name names)
        nameId     = idFromString ("show" ++ getNameName name)
        valueId    = idFromString "value$"
        in
    DeclValue 
    { declName    = nameId
    , declAccess  = public
    , valueEnc    = Nothing
    , valueValue  = foldr Lam 
        (Let 
            (Strict (Bind valueId (Var valueId)))
            (Match valueId
                (map makeAlt constructors)
            )
        )    
        (map idFromName names ++ [valueId])
    , declCustoms = [ custom "type" typeString ] 
    }
dataShowFunction _ = error "not supported"

-- Show Dictionary for a data type declaration
dataDictionary :: UHA.Declaration -> CoreDecl
dataDictionary  (UHA.Declaration_Data _ _ (UHA.SimpleType_SimpleType _ name names) _ _) =
    let nameId = idFromString ("show" ++ getNameName name) in
    DeclValue 
    { declName    = idFromString ("$dictShow" ++ getNameName name)
    , declAccess  = public
    , valueEnc    = Nothing
    , valueValue  = makeShowDictionary (length names) nameId
    , declCustoms = [ custom "type" ("DictShow" ++ getNameName name) ] 
    }
  where
    makeShowDictionary :: Int -> Id -> Expr
    makeShowDictionary nrOfArgs nameId =
       let ids  = take nrOfArgs [ idFromString ("d" ++ show i) | i <- [(1::Integer)..] ]
           idX  = idFromString "x"
           con  = Con (ConTag (Lit (LitInt 0)) 2)
           list = [ Ap (Var (idFromString "$show")) (Var ident) | ident <- ids ]
           declaration = Bind idX (foldl Ap (Var nameId) list)
           body = Let (Strict declaration) (Ap (Ap con (Var idX)) (Ap (Var (idFromString "$showList")) (Var idX)))
       in foldr Lam body ids
dataDictionary _ = error "not supported"

-- Show function for a type synonym
-- type T a b = (b, a) 
--   ===>
-- showT :: (a -> String) -> (b -> String) -> T a b -> String
-- showT a b = showTuple2 b a 
typeShowFunction :: UHA.Declaration -> Decl Expr
typeShowFunction (UHA.Declaration_Type _ (UHA.SimpleType_SimpleType _ name names) type_) =
    let typeString = show (typeOfShowFunction name names) in
    DeclValue 
    { declName    = idFromString ("show" ++ getNameName name)
    , declAccess  = public
    , valueEnc    = Nothing
    , valueValue  = foldr (Lam . idFromName) (showFunctionOfType False type_) names
    , declCustoms = [ custom "type" typeString ] 
    }
typeShowFunction _ = error "not supported"

-- Convert a data type constructor to a Core alternative
makeAlt :: UHA.Constructor -> Alt
makeAlt c = Alt (constructorToPat ident types) (showConstructor ident types)
  where
    (ident, types) = nameAndTypes c
    
    nameAndTypes :: UHA.Constructor -> (Id, [UHA.Type])
    nameAndTypes c' =
        case c' of
            UHA.Constructor_Constructor _    n ts -> (idFromName n, map annotatedTypeToType ts      )
            UHA.Constructor_Infix       _ t1 n t2 -> (idFromName n, map annotatedTypeToType [t1, t2])
            UHA.Constructor_Record _ _ _          -> error "not supported"
    constructorToPat :: Id -> [UHA.Type] -> Pat
    constructorToPat ident' ts =
        PatCon (ConId ident') [ idFromNumber i | i <- [1..length ts] ]
        
    annotatedTypeToType :: UHA.AnnotatedType -> UHA.Type
    annotatedTypeToType (UHA.AnnotatedType_AnnotatedType _ _ t) = t

-- Show expression for one constructor
showConstructor :: Id -> [UHA.Type] -> Expr
showConstructor c ts -- name of constructor and paramater types
    | isConOp && length ts == 2 = 
        Ap (Var (idFromString "$primConcat")) $ coreList 
            [   stringToCore "("
            ,   Ap (showFunctionOfType False (ts!!0)) (Var (idFromNumber 1))
            ,   stringToCore name
            ,   Ap (showFunctionOfType False (ts!!1)) (Var (idFromNumber 2)) 
            ,   stringToCore ")"
            ]
    | otherwise =
        Ap (Var (idFromString "$primConcat")) $ coreList 
            (  (if null ts then [] else [stringToCore "("])
            ++ (if isConOp then parens else id) [stringToCore name]
            ++ concat
                   [ [stringToCore " ", Ap (showFunctionOfType False t) (Var (idFromNumber i))]
                   | (t, i) <- zip ts [1..] 
                   ]
            ++ (if null ts then [] else [stringToCore ")"])
            )
  where
    name = stringFromId c
    isConOp = head name == ':'
    parens s = [ stringToCore "(" ] ++ s ++ [ stringToCore ")" ]

-- What show function to call for a specific type. Returns a Core expression
-- If this function is called for the main function, type variables are printed
-- using showPolymorphic. Otherwise, a show function for the type variable
-- should be available
showFunctionOfType :: Bool -> UHA.Type -> Expr
showFunctionOfType isMainType = sFOT
  where
    sFOT t = 
      case t of
        UHA.Type_Variable _ n             -> if isMainType then var "showPolymorphic" else Var (idFromName n) 
        -- show Strings not as List of Char but using showString
        UHA.Type_Application _ _ 
                    ( UHA.Type_Constructor _ (UHA.Name_Special    _ _ "[]") ) -- !!!Name
                    [ UHA.Type_Constructor _ (UHA.Name_Identifier _ _ "Char") ] -> -- !!!Name
            var "showString"
        UHA.Type_Constructor _ n         -> var ("show" ++ checkForPrimitive (getNameName n))
        UHA.Type_Application _ _ f xs    -> foldl Ap (sFOT f) (map sFOT xs)
        UHA.Type_Parenthesized _ t'      -> showFunctionOfType isMainType t'
        _ -> internalError "DerivingShow" "showFunctionOfType" "unsupported type"

-- Some primitive types have funny names and their Show function has a different name
checkForPrimitive :: String -> String
checkForPrimitive name =
    case name of 
        "[]" -> "List"
        "()" -> "Unit"
        "->" -> "Function"
        ('(':commasAndClose) -> 
            let arity = length commasAndClose in 
                if arity > 10 then
                    internalError "DerivingShow" "checkForPrimitive" "No show functions for tuples with more than 10 elements"
                else
                    "Tuple" ++ show arity
        _ -> name 
        
idFromNumber :: Int -> Id
idFromNumber i = idFromString ("v$" ++ show i)

nameOfShowFunction :: UHA.Name -> UHA.Name
nameOfShowFunction (UHA.Name_Identifier r m n) = UHA.Name_Identifier r m ("show" ++ n) -- !!!Name
nameOfShowFunction _ = internalError "DerivingShow" "nameOfShowFunction" "name of type must be an identifier"

typeOfShowFunction :: UHA.Name -> UHA.Names -> TpScheme
typeOfShowFunction name names =
    -- Build type from type name and parameters.
    -- e.g. data T a b = ...  ===> (0 -> String) -> (1 -> String) -> (T 0 1 -> String)
    let vars  = map TVar (take (length names) [0..])
        types = vars ++ [foldl TApp (TCon (getNameName name)) vars]
    in generalizeAll ([] .=>. foldr1 (.->.) (map (.->. stringType) types))

