{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RankNTypes         #-}
{-# LANGUAGE RecordWildCards    #-}
{-# OPTIONS_GHC -Wall #-}

-- | This module contains the logic for type checking Dhall code

module Dhall.TypeCheck (
    -- * Type-checking
      typeWith
    , typeOf
    , typeWithA
    , typeWithAN
    , checkContext

    -- * Types
    , Typer
    , X(..)
    , TypeError(..)
    , DetailedTypeError(..)
    , TypeMessage(..)
    ) where

import Control.Exception (Exception)
import Data.Foldable (forM_, toList)
import Data.HashMap.Strict.InsOrd (InsOrdHashMap)
import Data.Monoid ((<>))
import Data.Set (Set)
import Data.Text.Buildable (Buildable(..))
import Data.Text.Lazy (Text)
import Data.Text.Lazy.Builder (Builder)
import Data.Text.Prettyprint.Doc (Pretty(..))
import Data.Traversable (forM)
import Data.Typeable (Typeable)
import Dhall.Core (Const(..), Chunks(..), Expr(..), Normalizer, Var(..))
import Dhall.Context (Context)

import qualified Control.Monad.Trans.State.Strict as State
import qualified Data.HashMap.Strict
import qualified Data.HashMap.Strict.InsOrd
import qualified Data.Set
import qualified Data.Text.Lazy                   as Text
import qualified Data.Text.Lazy.Builder           as Builder
import qualified Data.Vector
import qualified Dhall.Context
import qualified Dhall.Core

axiom :: Const -> Either (TypeError s a) Const
axiom Type = return Kind
axiom Kind = Left (TypeError Dhall.Context.empty (Const Kind) Untyped)

rule :: Const -> Const -> Either () Const
rule Type Kind = Left ()
rule Type Type = return Type
rule Kind Kind = return Kind
rule Kind Type = return Type

match :: Var -> Var -> [(Text, Text)] -> Bool
match (V xL nL) (V xR nR)             []  =
    xL == xR  && nL == nR
match (V xL 0 ) (V xR 0 ) ((xL', xR'):_ )
    | xL == xL' && xR == xR' = True
match (V xL nL) (V xR nR) ((xL', xR'):xs) =
    match (V xL nL') (V xR nR') xs
  where
    nL' = if xL == xL' then nL - 1 else nL
    nR' = if xR == xR' then nR - 1 else nR


toSortedList :: InsOrdHashMap k v -> [(k, v)]
toSortedList =
    Data.HashMap.Strict.toList . Data.HashMap.Strict.InsOrd.toHashMap

propEqual :: Eq a => Normalizer s a -> Expr s a -> Expr s a -> Bool
propEqual nrm eL0 eR0 =
    State.evalState
        (go (Dhall.Core.normalizeWith nrm eL0) (Dhall.Core.normalizeWith nrm eR0))
        []
  where
    go (Const Type) (Const Type) = return True
    go (Const Kind) (Const Kind) = return True
    go (Var vL) (Var vR) = do
        ctx <- State.get
        return (match vL vR ctx)
    go (Pi xL tL bL) (Pi xR tR bR) = do
        ctx <- State.get
        eq1 <- go tL tR
        if eq1
            then do
                State.put ((xL, xR):ctx)
                eq2 <- go bL bR
                State.put ctx
                return eq2
            else return False
    go (App fL aL) (App fR aR) = do
        b1 <- go fL fR
        if b1 then go aL aR else return False
    go Bool Bool = return True
    go Natural Natural = return True
    go Integer Integer = return True
    go Double Double = return True
    go Text Text = return True
    go List List = return True
    go Optional Optional = return True
    go (Record ktsL0) (Record ktsR0) = do
        let loop ((kL, tL):ktsL) ((kR, tR):ktsR)
                | kL == kR = do
                    b <- go tL tR
                    if b
                        then loop ktsL ktsR
                        else return False
            loop [] [] = return True
            loop _  _  = return False
        loop (toSortedList ktsL0) (toSortedList ktsR0)
    go (Union ktsL0) (Union ktsR0) = do
        let loop ((kL, tL):ktsL) ((kR, tR):ktsR)
                | kL == kR = do
                    b <- go tL tR
                    if b
                        then loop ktsL ktsR
                        else return False
            loop [] [] = return True
            loop _  _  = return False
        loop (toSortedList ktsL0) (toSortedList ktsR0)
    go (Embed eL) (Embed eR) = return (eL == eR)
    -- TODO (armando): Hacks to make some typelit stuff I'm doing work
    go (TextLit (Chunks [] tL)) (TextLit (Chunks [] tR)) = return $ tL == tR
    go (NaturalLit nL) (NaturalLit nR) = return $ nL == nR
    -- TODO: Fix this up
    go (ListLit _ xsL) (ListLit _ xsR) = do
      let loop (tL:tsL) (tR:tsR) = do
            b <- go tL tR
            if b
                then loop tsL tsR
                else return False
          loop [] [] = return True
          loop _ _ = return False
      loop (Data.Vector.toList xsL) (Data.Vector.toList xsR)
    go _ _ = return False
{-| Type-check an expression and return the expression's type if type-checking
    succeeds or an error if type-checking fails

    `typeWith` does not necessarily normalize the type since full normalization
    is not necessary for just type-checking.  If you actually care about the
    returned type then you may want to `Dhall.Core.normalize` it afterwards.
-}
typeWith :: Context (Expr s X) -> Expr s X -> Either (TypeError s X) (Expr s X)
typeWith ctx expr = do
    checkContext ctx
    typeWithA absurd ctx expr

{-| Function that converts the value inside an `Embed` constructor into a new
    expression
-}
type Typer s a = a -> Expr s a

{-| Generalization of `typeWith` that allows type-checking the `Embed`
    constructor with custom logic
-}
typeWithA
    :: Eq a
    => Typer s a
    -> Context (Expr s a)
    -> Expr s a
    -> Either (TypeError s a) (Expr s a)
typeWithA = typeWithAN (const Nothing)

typeWithAN
    :: Eq a
    => Normalizer s a
    -> Typer s a
    -> Context (Expr s a)
    -> Expr s a
    -> Either (TypeError s a) (Expr s a)
typeWithAN nrm tpa = loop
  where
    loop _     (Const c         ) = do
        fmap Const (axiom c)
    loop ctx e@(Var (V x n)     ) = do
        case Dhall.Context.lookup x n ctx of
            Nothing -> Left (TypeError ctx e (UnboundVariable x))
            Just a  -> do
                _ <- loop ctx a
                return a
    loop ctx   (Lam x _A  b     ) = do
        _ <- loop ctx _A
        let ctx' = fmap (Dhall.Core.shift 1 (V x 0)) (Dhall.Context.insert x _A ctx)
        _B <- loop ctx' b
        let p = Pi x _A _B
        _t <- loop ctx p
        return p
    loop ctx e@(Pi  x _A _B     ) = do
        tA <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx _A)
        kA <- case tA of
            Const k -> return k
            _       -> Left (TypeError ctx e (InvalidInputType _A))

        _ <- loop ctx _A
        let ctx' = fmap (Dhall.Core.shift 1 (V x 0)) (Dhall.Context.insert x _A ctx)
        tB <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx' _B)
        kB <- case tB of
            Const k -> return k
            _       -> Left (TypeError ctx' e (InvalidOutputType _B))

        case rule kA kB of
            Left () -> Left (TypeError ctx e (NoDependentTypes _A _B))
            Right k -> Right (Const k)
    loop ctx e@(App f a         ) = do
        tf <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx f)
        (x, _A, _B) <- case tf of
            Pi x _A _B -> return (x, _A, _B)
            _          -> Left (TypeError ctx e (NotAFunction f tf))
        _A' <- loop ctx a
        if propEqual nrm _A _A'
            then do
                let a'   = Dhall.Core.shift   1  (V x 0) a
                let _B'  = Dhall.Core.subst (V x 0) a' _B
                let _B'' = Dhall.Core.shift (-1) (V x 0) _B'
                return _B''
            else do
                let nf_A  = Dhall.Core.normalizeWith nrm _A
                let nf_A' = Dhall.Core.normalizeWith nrm _A'
                Left (TypeError ctx e (TypeMismatch f nf_A a nf_A'))
    loop ctx e@(Let x mA a0 b0) = do
        _A1 <- loop ctx a0
        case mA of
            Just _A0 -> do
                _ <- loop ctx _A0
                let nf_A0 = Dhall.Core.normalizeWith nrm _A0
                let nf_A1 = Dhall.Core.normalizeWith nrm _A1
                if propEqual nrm _A0 _A1
                    then return ()
                    else Left (TypeError ctx e (AnnotMismatch a0 nf_A0 nf_A1))
            Nothing -> return ()
        let a1 = Dhall.Core.normalizeWith nrm a0
        let a2 = Dhall.Core.shift 1 (V x 0) a1
        let b1 = Dhall.Core.subst (V x 0) a2 b0
        let b2 = Dhall.Core.shift (-1) (V x 0) b1
        loop ctx b2
    loop ctx e@(Annot x t       ) = do
        _ <- loop ctx t

        t' <- loop ctx x
        if propEqual nrm t t'
            then do
                return t
            else do
                let nf_t  = Dhall.Core.normalizeWith nrm t
                let nf_t' = Dhall.Core.normalizeWith nrm t'
                Left (TypeError ctx e (AnnotMismatch x nf_t nf_t'))
    loop _      Bool              = do
        return (Const Type)
    loop _     (BoolLit _       ) = do
        return Bool
    loop ctx e@(BoolAnd l r     ) = do
        tl <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx l)
        case tl of
            Bool -> return ()
            _    -> Left (TypeError ctx e (CantAnd l tl))

        tr <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx r)
        case tr of
            Bool -> return ()
            _    -> Left (TypeError ctx e (CantAnd r tr))

        return Bool
    loop ctx e@(BoolOr  l r     ) = do
        tl <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx l)
        case tl of
            Bool -> return ()
            _    -> Left (TypeError ctx e (CantOr l tl))

        tr <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx r)
        case tr of
            Bool -> return ()
            _    -> Left (TypeError ctx e (CantOr r tr))

        return Bool
    loop ctx e@(BoolEQ  l r     ) = do
        tl <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx l)
        case tl of
            Bool -> return ()
            _    -> Left (TypeError ctx e (CantEQ l tl))

        tr <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx r)
        case tr of
            Bool -> return ()
            _    -> Left (TypeError ctx e (CantEQ r tr))

        return Bool
    loop ctx e@(BoolNE  l r     ) = do
        tl <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx l)
        case tl of
            Bool -> return ()
            _    -> Left (TypeError ctx e (CantNE l tl))

        tr <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx r)
        case tr of
            Bool -> return ()
            _    -> Left (TypeError ctx e (CantNE r tr))

        return Bool
    loop ctx e@(BoolIf x y z    ) = do
        tx <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx x)
        case tx of
            Bool -> return ()
            _    -> Left (TypeError ctx e (InvalidPredicate x tx))
        ty  <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx y )
        tty <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx ty)
        case tty of
            Const Type -> return ()
            _          -> Left (TypeError ctx e (IfBranchMustBeTerm True y ty tty))

        tz <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx z)
        ttz <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx tz)
        case ttz of
            Const Type -> return ()
            _          -> Left (TypeError ctx e (IfBranchMustBeTerm False z tz ttz))

        if propEqual nrm ty tz
            then return ()
            else Left (TypeError ctx e (IfBranchMismatch y z ty tz))
        return ty
    loop _      Natural           = do
        return (Const Type)
    loop _     (NaturalLit _    ) = do
        return Natural
    loop _      NaturalFold       = do
        return
            (Pi "_" Natural
                (Pi "natural" (Const Type)
                    (Pi "succ" (Pi "_" "natural" "natural")
                        (Pi "zero" "natural" "natural") ) ) )
    loop _      NaturalBuild      = do
        return
            (Pi "_"
                (Pi "natural" (Const Type)
                    (Pi "succ" (Pi "_" "natural" "natural")
                        (Pi "zero" "natural" "natural") ) )
                Natural )
    loop _      NaturalIsZero     = do
        return (Pi "_" Natural Bool)
    loop _      NaturalEven       = do
        return (Pi "_" Natural Bool)
    loop _      NaturalOdd        = do
        return (Pi "_" Natural Bool)
    loop _      NaturalToInteger  = do
        return (Pi "_" Natural Integer)
    loop _      NaturalShow  = do
        return (Pi "_" Natural Text)
    loop ctx e@(NaturalPlus  l r) = do
        tl <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx l)
        case tl of
            Natural -> return ()
            _       -> Left (TypeError ctx e (CantAdd l tl))

        tr <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx r)
        case tr of
            Natural -> return ()
            _       -> Left (TypeError ctx e (CantAdd r tr))
        return Natural
    loop ctx e@(NaturalTimes l r) = do
        tl <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx l)
        case tl of
            Natural -> return ()
            _       -> Left (TypeError ctx e (CantMultiply l tl))

        tr <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx r)
        case tr of
            Natural -> return ()
            _       -> Left (TypeError ctx e (CantMultiply r tr))
        return Natural
    loop _      Integer           = do
        return (Const Type)
    loop _     (IntegerLit _    ) = do
        return Integer
    loop _      IntegerShow  = do
        return (Pi "_" Integer Text)
    loop _      Double            = do
        return (Const Type)
    loop _     (DoubleLit _     ) = do
        return Double
    loop _     DoubleShow         = do
        return (Pi "_" Double Text)
    loop _      Text              = do
        return (Const Type)
    loop ctx e@(TextLit (Chunks xys _)) = do
        let process (_, y) = do
                ty <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx y)
                case ty of
                    Text -> return ()
                    _    -> Left (TypeError ctx e (CantInterpolate y ty))
        mapM_ process xys
        return Text
    loop ctx e@(TextAppend l r  ) = do
        tl <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx l)
        case tl of
            Text -> return ()
            _    -> Left (TypeError ctx e (CantTextAppend l tl))

        tr <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx r)
        case tr of
            Text -> return ()
            _    -> Left (TypeError ctx e (CantTextAppend r tr))
        return Text
    loop _      List              = do
        return (Pi "_" (Const Type) (Const Type))
    loop ctx e@(ListLit  Nothing  xs) = do
        if Data.Vector.null xs
            then Left (TypeError ctx e MissingListType)
            else do
                t <- loop ctx (Data.Vector.head xs)
                s <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx t)
                case s of
                    Const Type -> return ()
                    _ -> Left (TypeError ctx e (InvalidListType t))
                flip Data.Vector.imapM_ xs (\i x -> do
                    t' <- loop ctx x
                    if propEqual nrm t t'
                        then return ()
                        else do
                            let nf_t  = Dhall.Core.normalizeWith nrm t
                            let nf_t' = Dhall.Core.normalizeWith nrm t'
                            let err   = MismatchedListElements i nf_t x nf_t'
                            Left (TypeError ctx x err) )
                return (App List t)
    loop ctx e@(ListLit (Just t ) xs) = do
        s <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx t)
        case s of
            Const Type -> return ()
            _ -> Left (TypeError ctx e (InvalidListType t))
        flip Data.Vector.imapM_ xs (\i x -> do
            t' <- loop ctx x
            if propEqual nrm t t'
                then return ()
                else do
                    let nf_t  = Dhall.Core.normalizeWith nrm t
                    let nf_t' = Dhall.Core.normalizeWith nrm t'
                    Left (TypeError ctx x (InvalidListElement i nf_t x nf_t')) )
        return (App List t)
    loop ctx e@(ListAppend l r  ) = do
        tl <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx l)
        el <- case tl of
            App List el -> return el
            _           -> Left (TypeError ctx e (CantListAppend l tl))

        tr <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx r)
        er <- case tr of
            App List er -> return er
            _           -> Left (TypeError ctx e (CantListAppend r tr))

        if propEqual nrm el er
            then return (App List el)
            else Left (TypeError ctx e (ListAppendMismatch el er))
    loop _      ListBuild         = do
        return
            (Pi "a" (Const Type)
                (Pi "_"
                    (Pi "list" (Const Type)
                        (Pi "cons" (Pi "_" "a" (Pi "_" "list" "list"))
                            (Pi "nil" "list" "list") ) )
                    (App List "a") ) )
    loop _      ListFold          = do
        return
            (Pi "a" (Const Type)
                (Pi "_" (App List "a")
                    (Pi "list" (Const Type)
                        (Pi "cons" (Pi "_" "a" (Pi "_" "list" "list"))
                            (Pi "nil" "list" "list")) ) ) )
    loop _      ListLength        = do
        return (Pi "a" (Const Type) (Pi "_" (App List "a") Natural))
    loop _      ListHead          = do
        return (Pi "a" (Const Type) (Pi "_" (App List "a") (App Optional "a")))
    loop _      ListLast          = do
        return (Pi "a" (Const Type) (Pi "_" (App List "a") (App Optional "a")))
    loop _      ListIndexed       = do
        let kts = [("index", Natural), ("value", "a")]
        return
            (Pi "a" (Const Type)
                (Pi "_" (App List "a")
                    (App List (Record (Data.HashMap.Strict.InsOrd.fromList kts))) ) )
    loop _      ListReverse       = do
        return (Pi "a" (Const Type) (Pi "_" (App List "a") (App List "a")))
    loop _      Optional          = do
        return (Pi "_" (Const Type) (Const Type))
    loop ctx e@(OptionalLit t xs) = do
        s <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx t)
        case s of
            Const Type -> return ()
            _ -> Left (TypeError ctx e (InvalidOptionalType t))
        let n = Data.Vector.length xs
        if 2 <= n
            then Left (TypeError ctx e (InvalidOptionalLiteral n))
            else return ()
        forM_ xs (\x -> do
            t' <- loop ctx x
            if propEqual nrm t t'
                then return ()
                else do
                    let nf_t  = Dhall.Core.normalizeWith nrm t
                    let nf_t' = Dhall.Core.normalizeWith nrm t'
                    Left (TypeError ctx e (InvalidOptionalElement nf_t x nf_t')) )
        return (App Optional t)
    loop _      OptionalFold      = do
        return
            (Pi "a" (Const Type)
                (Pi "_" (App Optional "a")
                    (Pi "optional" (Const Type)
                        (Pi "just" (Pi "_" "a" "optional")
                            (Pi "nothing" "optional" "optional") ) ) ) )
    loop _      OptionalBuild     = do
        return
            (Pi "a" (Const Type)
                (Pi "_" f (App Optional "a") ) )
        where f = Pi "optional" (Const Type)
                      (Pi "just" (Pi "_" "a" "optional")
                          (Pi "nothing" "optional" "optional") )
    loop ctx e@(Record    kts   ) = do
        let process (k, t) = do
                s <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx t)
                case s of
                    Const Type -> return ()
                    Const Kind -> return ()
                    other -> loop ctx other >>= \x -> case x of
                    -- This codepath doesn't come into play for vanilla Dhall,
                    -- but can come in handy with Embedded terms that introduce
                    -- new Kinds
                      Const Kind -> return ()
                      _          -> Left (TypeError ctx e (InvalidFieldType k t))
        mapM_ process (Data.HashMap.Strict.InsOrd.toList kts)
        return (Const Type)
    loop ctx e@(RecordLit kvs   ) = do
        let process k v = do
                t <- loop ctx v
                s <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx t)
                case s of
                    Const Type -> return ()
                    Const Kind -> return ()
                    _          -> Left (TypeError ctx e (InvalidField k v))
                return t
        kts <- Data.HashMap.Strict.InsOrd.traverseWithKey process kvs
        return (Record kts)
    loop ctx e@(Union     kts   ) = do
        let process (k, t) = do
                s <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx t)
                case s of
                    Const Type -> return ()
                    Const Kind -> return ()
                    _          -> Left (TypeError ctx e (InvalidAlternativeType k t))
        mapM_ process (Data.HashMap.Strict.InsOrd.toList kts)
        return (Const Type)
    loop ctx e@(UnionLit k v kts) = do
        case Data.HashMap.Strict.InsOrd.lookup k kts of
            Just _  -> Left (TypeError ctx e (DuplicateAlternative k))
            Nothing -> return ()
        t <- loop ctx v
        let union = Union (Data.HashMap.Strict.InsOrd.insert k t kts)
        _ <- loop ctx union
        return union
    loop ctx e@(Combine kvsX kvsY) = do
        tKvsX <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx kvsX)
        ktsX  <- case tKvsX of
            Record kts -> return kts
            _          -> Left (TypeError ctx e (MustCombineARecord '∧' kvsX tKvsX))

        tKvsY <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx kvsY)
        ktsY  <- case tKvsY of
            Record kts -> return kts
            _          -> Left (TypeError ctx e (MustCombineARecord '∧' kvsY tKvsY))

        let combineTypes ktsL ktsR = do
                let ksL =
                        Data.Set.fromList (Data.HashMap.Strict.InsOrd.keys ktsL)
                let ksR =
                        Data.Set.fromList (Data.HashMap.Strict.InsOrd.keys ktsR)
                let ks = Data.Set.union ksL ksR
                kts <- forM (toList ks) (\k -> do
                    case (Data.HashMap.Strict.InsOrd.lookup k ktsL, Data.HashMap.Strict.InsOrd.lookup k ktsR) of
                        (Just (Record ktsL'), Just (Record ktsR')) -> do
                            t <- combineTypes ktsL' ktsR'
                            return (k, t)
                        (Nothing, Just t) -> do
                            return (k, t)
                        (Just t, Nothing) -> do
                            return (k, t)
                        _ -> do
                            Left (TypeError ctx e (FieldCollision k)) )
                return (Record (Data.HashMap.Strict.InsOrd.fromList kts))

        combineTypes ktsX ktsY
    loop ctx e@(Prefer kvsX kvsY) = do
        tKvsX <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx kvsX)
        ktsX  <- case tKvsX of
            Record kts -> return kts
            _          -> Left (TypeError ctx e (MustCombineARecord '⫽' kvsX tKvsX))

        tKvsY <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx kvsY)
        ktsY  <- case tKvsY of
            Record kts -> return kts
            _          -> Left (TypeError ctx e (MustCombineARecord '⫽' kvsY tKvsY))
        return (Record (Data.HashMap.Strict.InsOrd.union ktsY ktsX))
    loop ctx e@(Merge kvsX kvsY (Just t)) = do
        _ <- loop ctx t

        tKvsX <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx kvsX)
        ktsX  <- case tKvsX of
            Record kts -> return kts
            _          -> Left (TypeError ctx e (MustMergeARecord kvsX tKvsX))
        let ksX = Data.Set.fromList (Data.HashMap.Strict.InsOrd.keys ktsX)

        tKvsY <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx kvsY)
        ktsY  <- case tKvsY of
            Union kts -> return kts
            _         -> Left (TypeError ctx e (MustMergeUnion kvsY tKvsY))
        let ksY = Data.Set.fromList (Data.HashMap.Strict.InsOrd.keys ktsY)

        let diffX = Data.Set.difference ksX ksY
        let diffY = Data.Set.difference ksY ksX

        if Data.Set.null diffX
            then return ()
            else Left (TypeError ctx e (UnusedHandler diffX))

        let process (kY, tY) = do
                case Data.HashMap.Strict.InsOrd.lookup kY ktsX of
                    Nothing  -> Left (TypeError ctx e (MissingHandler diffY))
                    Just tX  ->
                        case tX of
                            Pi _ tY' t' -> do
                                if propEqual nrm tY tY'
                                    then return ()
                                    else Left (TypeError ctx e (HandlerInputTypeMismatch kY tY tY'))
                                if propEqual nrm t t'
                                    then return ()
                                    else Left (TypeError ctx e (InvalidHandlerOutputType kY t t'))
                            _ -> Left (TypeError ctx e (HandlerNotAFunction kY tX))
        mapM_ process (Data.HashMap.Strict.InsOrd.toList ktsY)
        return t
    loop ctx e@(Merge kvsX kvsY Nothing) = do
        tKvsX <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx kvsX)
        ktsX  <- case tKvsX of
            Record kts -> return kts
            _          -> Left (TypeError ctx e (MustMergeARecord kvsX tKvsX))
        let ksX = Data.Set.fromList (Data.HashMap.Strict.InsOrd.keys ktsX)

        tKvsY <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx kvsY)
        ktsY  <- case tKvsY of
            Union kts -> return kts
            _         -> Left (TypeError ctx e (MustMergeUnion kvsY tKvsY))
        let ksY = Data.Set.fromList (Data.HashMap.Strict.InsOrd.keys ktsY)

        let diffX = Data.Set.difference ksX ksY
        let diffY = Data.Set.difference ksY ksX

        if Data.Set.null diffX
            then return ()
            else Left (TypeError ctx e (UnusedHandler diffX))

        (kX, t) <- case Data.HashMap.Strict.InsOrd.toList ktsX of
            []               -> Left (TypeError ctx e MissingMergeType)
            (kX, Pi _ _ t):_ -> return (kX, t)
            (kX, tX      ):_ -> Left (TypeError ctx e (HandlerNotAFunction kX tX))
        let process (kY, tY) = do
                case Data.HashMap.Strict.InsOrd.lookup kY ktsX of
                    Nothing  -> Left (TypeError ctx e (MissingHandler diffY))
                    Just tX  ->
                        case tX of
                            Pi _ tY' t' -> do
                                if propEqual nrm tY tY'
                                    then return ()
                                    else Left (TypeError ctx e (HandlerInputTypeMismatch kY tY tY'))
                                if propEqual nrm t t'
                                    then return ()
                                    else Left (TypeError ctx e (HandlerOutputTypeMismatch kX t kY t'))
                            _ -> Left (TypeError ctx e (HandlerNotAFunction kY tX))
        mapM_ process (Data.HashMap.Strict.InsOrd.toList ktsY)
        return t
    loop ctx e@(Constructors t  ) = do
        _ <- loop ctx t

        kts <- case Dhall.Core.normalizeWith nrm t of
            Union kts -> return kts
            t'        -> Left (TypeError ctx e (ConstructorsRequiresAUnionType t t'))

        let adapt k t_ = Pi k t_ (Union kts)

        return (Record (Data.HashMap.Strict.InsOrd.mapWithKey adapt kts))
    loop ctx e@(Field r x       ) = do
        t <- fmap (Dhall.Core.normalizeWith nrm) (loop ctx r)
        case t of
            Record kts -> do
                _ <- loop ctx t

                case Data.HashMap.Strict.InsOrd.lookup x kts of
                    Just t' -> return t'
                    Nothing -> Left (TypeError ctx e (MissingField x t))
            _          -> Left (TypeError ctx e (NotARecord x r t))
    loop ctx   (Note s e'       ) = case loop ctx e' of
        Left (TypeError ctx' (Note s' e'') m) -> Left (TypeError ctx' (Note s' e'') m)
        Left (TypeError ctx'          e''  m) -> Left (TypeError ctx' (Note s  e'') m)
        Right r                               -> Right r
    loop _     (Embed p         ) = Right $ tpa p

{-| `typeOf` is the same as `typeWith` with an empty context, meaning that the
    expression must be closed (i.e. no free variables), otherwise type-checking
    will fail.
-}
typeOf :: Expr s X -> Either (TypeError s X) (Expr s X)
typeOf = typeWith Dhall.Context.empty

-- | Like `Data.Void.Void`, except with a shorter inferred type
newtype X = X { absurd :: forall a . a }

instance Show X where
    show = absurd

instance Eq X where
  _ == _ = True

instance Buildable X where
    build = absurd

instance Pretty X where
    pretty = absurd

-- | The specific type error
data TypeMessage s a
    = UnboundVariable Text
    | InvalidInputType (Expr s a)
    | InvalidOutputType (Expr s a)
    | NotAFunction (Expr s a) (Expr s a)
    | TypeMismatch (Expr s a) (Expr s a) (Expr s a) (Expr s a)
    | AnnotMismatch (Expr s a) (Expr s a) (Expr s a)
    | Untyped
    | MissingListType
    | MismatchedListElements Int (Expr s a) (Expr s a) (Expr s a)
    | InvalidListElement Int (Expr s a) (Expr s a) (Expr s a)
    | InvalidListType (Expr s a)
    | InvalidOptionalElement (Expr s a) (Expr s a) (Expr s a)
    | InvalidOptionalLiteral Int
    | InvalidOptionalType (Expr s a)
    | InvalidPredicate (Expr s a) (Expr s a)
    | IfBranchMismatch (Expr s a) (Expr s a) (Expr s a) (Expr s a)
    | IfBranchMustBeTerm Bool (Expr s a) (Expr s a) (Expr s a)
    | InvalidField Text (Expr s a)
    | InvalidFieldType Text (Expr s a)
    | InvalidAlternative Text (Expr s a)
    | InvalidAlternativeType Text (Expr s a)
    | ListAppendMismatch (Expr s a) (Expr s a)
    | DuplicateAlternative Text
    | MustCombineARecord Char (Expr s a) (Expr s a)
    | FieldCollision Text
    | MustMergeARecord (Expr s a) (Expr s a)
    | MustMergeUnion (Expr s a) (Expr s a)
    | UnusedHandler (Set Text)
    | MissingHandler (Set Text)
    | HandlerInputTypeMismatch Text (Expr s a) (Expr s a)
    | HandlerOutputTypeMismatch Text (Expr s a) Text (Expr s a)
    | InvalidHandlerOutputType Text (Expr s a) (Expr s a)
    | MissingMergeType
    | HandlerNotAFunction Text (Expr s a)
    | ConstructorsRequiresAUnionType (Expr s a) (Expr s a)
    | NotARecord Text (Expr s a) (Expr s a)
    | MissingField Text (Expr s a)
    | CantAnd (Expr s a) (Expr s a)
    | CantOr (Expr s a) (Expr s a)
    | CantEQ (Expr s a) (Expr s a)
    | CantNE (Expr s a) (Expr s a)
    | CantInterpolate (Expr s a) (Expr s a)
    | CantTextAppend (Expr s a) (Expr s a)
    | CantListAppend (Expr s a) (Expr s a)
    | CantAdd (Expr s a) (Expr s a)
    | CantMultiply (Expr s a) (Expr s a)
    | NoDependentTypes (Expr s a) (Expr s a)
    deriving (Show)

shortTypeMessage :: Buildable a => TypeMessage s a -> Builder
shortTypeMessage msg =
    "\ESC[1;31mError\ESC[0m: " <> build short <> "\n"
  where
    ErrorMessages {..} = prettyTypeMessage msg

longTypeMessage :: Buildable a => TypeMessage s a -> Builder
longTypeMessage msg =
        "\ESC[1;31mError\ESC[0m: " <> build short <> "\n"
    <>  "\n"
    <>  long
  where
    ErrorMessages {..} = prettyTypeMessage msg

data ErrorMessages = ErrorMessages
    { short :: Builder
    -- ^ Default succinct 1-line explanation of what went wrong
    , long  :: Builder
    -- ^ Longer and more detailed explanation of the error
    }

_NOT :: Builder
_NOT = "\ESC[1mnot\ESC[0m"

prettyTypeMessage :: Buildable a => TypeMessage s a -> ErrorMessages
prettyTypeMessage (UnboundVariable _) = ErrorMessages {..}
  -- We do not need to print variable name here. For the discussion see:
  -- https://github.com/dhall-lang/dhall-haskell/pull/116
  where
    short = "Unbound variable"

    long =
        "Explanation: Expressions can only reference previously introduced (i.e. \"bound\")\n\
        \variables that are still \"in scope\"                                           \n\
        \                                                                                \n\
        \For example, the following valid expressions introduce a \"bound\" variable named\n\
        \❰x❱:                                                                            \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────┐                                                         \n\
        \    │ λ(x : Bool) → x │  Anonymous functions introduce \"bound\" variables      \n\
        \    └─────────────────┘                                                         \n\
        \        ⇧                                                                       \n\
        \        This is the bound variable                                              \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────┐                                                         \n\
        \    │ let x = 1 in x  │  ❰let❱ expressions introduce \"bound\" variables        \n\
        \    └─────────────────┘                                                         \n\
        \          ⇧                                                                     \n\
        \          This is the bound variable                                            \n\
        \                                                                                \n\
        \                                                                                \n\
        \However, the following expressions are not valid because they all reference a   \n\
        \variable that has not been introduced yet (i.e. an \"unbound\" variable):       \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────┐                                                         \n\
        \    │ λ(x : Bool) → y │  The variable ❰y❱ hasn't been introduced yet            \n\
        \    └─────────────────┘                                                         \n\
        \                    ⇧                                                           \n\
        \                    This is the unbound variable                                \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────────────┐                                                \n\
        \    │ (let x = True in x) && x │  ❰x❱ is undefined outside the parentheses      \n\
        \    └──────────────────────────┘                                                \n\
        \                             ⇧                                                  \n\
        \                             This is the unbound variable                       \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────┐                                                          \n\
        \    │ let x = x in x │  The definition for ❰x❱ cannot reference itself          \n\
        \    └────────────────┘                                                          \n\
        \              ⇧                                                                 \n\
        \              This is the unbound variable                                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \Some common reasons why you might get this error:                               \n\
        \                                                                                \n\
        \● You misspell a variable name, like this:                                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────────────────────────────────┐                      \n\
        \    │ λ(empty : Bool) → if emty then \"Empty\" else \"Full\" │                  \n\
        \    └────────────────────────────────────────────────────┘                      \n\
        \                           ⇧                                                    \n\
        \                           Typo                                                 \n\
        \                                                                                \n\
        \                                                                                \n\
        \● You misspell a reserved identifier, like this:                                \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────────────┐                                                \n\
        \    │ foral (a : Type) → a → a │                                                \n\
        \    └──────────────────────────┘                                                \n\
        \      ⇧                                                                         \n\
        \      Typo                                                                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \● You tried to define a recursive value, like this:                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────┐                                                     \n\
        \    │ let x = x + +1 in x │                                                     \n\
        \    └─────────────────────┘                                                     \n\
        \              ⇧                                                                 \n\
        \              Recursive definitions are not allowed                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \● You accidentally forgot a ❰λ❱ or ❰∀❱/❰forall❱                                 \n\
        \                                                                                \n\
        \                                                                                \n\
        \        Unbound variable                                                        \n\
        \        ⇩                                                                       \n\
        \    ┌─────────────────┐                                                         \n\
        \    │  (x : Bool) → x │                                                         \n\
        \    └─────────────────┘                                                         \n\
        \      ⇧                                                                         \n\
        \      A ❰λ❱ here would transform this into a valid anonymous function           \n\
        \                                                                                \n\
        \                                                                                \n\
        \        Unbound variable                                                        \n\
        \        ⇩                                                                       \n\
        \    ┌────────────────────┐                                                      \n\
        \    │  (x : Bool) → Bool │                                                      \n\
        \    └────────────────────┘                                                      \n\
        \      ⇧                                                                         \n\
        \      A ❰∀❱ or ❰forall❱ here would transform this into a valid function type    \n"

prettyTypeMessage (InvalidInputType expr) = ErrorMessages {..}
  where
    short = "Invalid function input"

    long =
        "Explanation: A function can accept an input \"term\" that has a given \"type\", like\n\
        \this:                                                                           \n\
        \                                                                                \n\
        \                                                                                \n\
        \        This is the input term that the function accepts                        \n\
        \        ⇩                                                                       \n\
        \    ┌───────────────────────┐                                                   \n\
        \    │ ∀(x : Natural) → Bool │  This is the type of a function that accepts an   \n\
        \    └───────────────────────┘  input term named ❰x❱ that has type ❰Natural❱     \n\
        \            ⇧                                                                   \n\
        \            This is the type of the input term                                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────┐                                                          \n\
        \    │ Bool → Integer │  This is the type of a function that accepts an anonymous\n\
        \    └────────────────┘  input term that has type ❰Bool❱                         \n\
        \      ⇧                                                                         \n\
        \      This is the type of the input term                                        \n\
        \                                                                                \n\
        \                                                                                \n\
        \... or a function can accept an input \"type\" that has a given \"kind\", like this:\n\
        \                                                                                \n\
        \                                                                                \n\
        \        This is the input type that the function accepts                        \n\
        \        ⇩                                                                       \n\
        \    ┌────────────────────┐                                                      \n\
        \    │ ∀(a : Type) → Type │  This is the type of a function that accepts an input\n\
        \    └────────────────────┘  type named ❰a❱ that has kind ❰Type❱                 \n\
        \            ⇧                                                                   \n\
        \            This is the kind of the input type                                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────────┐                                                    \n\
        \    │ (Type → Type) → Type │  This is the type of a function that accepts an    \n\
        \    └──────────────────────┘  anonymous input type that has kind ❰Type → Type❱  \n\
        \       ⇧                                                                        \n\
        \       This is the kind of the input type                                       \n\
        \                                                                                \n\
        \                                                                                \n\
        \Other function inputs are " <> _NOT <> " valid, like this:                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────┐                                                            \n\
        \    │ ∀(x : 1) → x │  ❰1❱ is a \"term\" and not a \"type\" nor a \"kind\" so ❰x❱\n\
        \    └──────────────┘  cannot have \"type\" ❰1❱ or \"kind\" ❰1❱                  \n\
        \            ⇧                                                                   \n\
        \            This is not a type or kind                                          \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────┐                                                                \n\
        \    │ True → x │  ❰True❱ is a \"term\" and not a \"type\" nor a \"kind\" so the \n\
        \    └──────────┘  anonymous input cannot have \"type\" ❰True❱ or \"kind\" ❰True❱\n\
        \      ⇧                                                                         \n\
        \      This is not a type or kind                                                \n\
        \                                                                                \n\
        \                                                                                \n\
        \You annotated a function input with the following expression:                   \n\
        \                                                                                \n\
        \↳ " <> txt <> "                                                                 \n\
        \                                                                                \n\
        \... which is neither a type nor a kind                                          \n"
      where
        txt  = build expr

prettyTypeMessage (InvalidOutputType expr) = ErrorMessages {..}
  where
    short = "Invalid function output"

    long =
        "Explanation: A function can return an output \"term\" that has a given \"type\",\n\
        \like this:                                                                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────┐                                                      \n\
        \    │ ∀(x : Text) → Bool │  This is the type of a function that returns an      \n\
        \    └────────────────────┘  output term that has type ❰Bool❱                    \n\
        \                    ⇧                                                           \n\
        \                    This is the type of the output term                         \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────┐                                                          \n\
        \    │ Bool → Integer │  This is the type of a function that returns an output   \n\
        \    └────────────────┘  term that has type ❰Int❱                                \n\
        \             ⇧                                                                  \n\
        \             This is the type of the output term                                \n\
        \                                                                                \n\
        \                                                                                \n\
        \... or a function can return an output \"type\" that has a given \"kind\", like \n\
        \this:                                                                           \n\
        \                                                                                \n\
        \    ┌────────────────────┐                                                      \n\
        \    │ ∀(a : Type) → Type │  This is the type of a function that returns an      \n\
        \    └────────────────────┘  output type that has kind ❰Type❱                    \n\
        \                    ⇧                                                           \n\
        \                    This is the kind of the output type                         \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────────┐                                                    \n\
        \    │ (Type → Type) → Type │  This is the type of a function that returns an    \n\
        \    └──────────────────────┘  output type that has kind ❰Type❱                  \n\
        \                      ⇧                                                         \n\
        \                      This is the kind of the output type                       \n\
        \                                                                                \n\
        \                                                                                \n\
        \Other outputs are " <> _NOT <> " valid, like this:                              \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────┐                                                         \n\
        \    │ ∀(x : Bool) → x │  ❰x❱ is a \"term\" and not a \"type\" nor a \"kind\" so the\n\
        \    └─────────────────┘  output cannot have \"type\" ❰x❱ or \"kind\" ❰x❱        \n\
        \                    ⇧                                                           \n\
        \                    This is not a type or kind                                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────┐                                                             \n\
        \    │ Text → True │  ❰True❱ is a \"term\" and not a \"type\" nor a \"kind\" so the\n\
        \    └─────────────┘  output cannot have \"type\" ❰True❱ or \"kind\" ❰True❱      \n\
        \             ⇧                                                                  \n\
        \             This is not a type or kind                                         \n\
        \                                                                                \n\
        \                                                                                \n\
        \Some common reasons why you might get this error:                               \n\
        \                                                                                \n\
        \● You use ❰∀❱ instead of ❰λ❱ by mistake, like this:                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────┐                                                          \n\
        \    │ ∀(x: Bool) → x │                                                          \n\
        \    └────────────────┘                                                          \n\
        \      ⇧                                                                         \n\
        \      Using ❰λ❱ here instead of ❰∀❱ would transform this into a valid function  \n\
        \                                                                                \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \You specified that your function outputs a:                                     \n\
        \                                                                                \n\
        \↳ " <> txt <> "                                                                 \n\
        \                                                                                \n\
        \... which is neither a type nor a kind:                                         \n"
      where
        txt = build expr

prettyTypeMessage (NotAFunction expr0 expr1) = ErrorMessages {..}
  where
    short = "Not a function"

    long =
        "Explanation: Expressions separated by whitespace denote function application,   \n\
        \like this:                                                                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────┐                                                                     \n\
        \    │ f x │  This denotes the function ❰f❱ applied to an argument named ❰x❱     \n\
        \    └─────┘                                                                     \n\
        \                                                                                \n\
        \                                                                                \n\
        \A function is a term that has type ❰a → b❱ for some ❰a❱ or ❰b❱.  For example,   \n\
        \the following expressions are all functions because they have a function type:  \n\
        \                                                                                \n\
        \                                                                                \n\
        \                        The function's input type is ❰Bool❱                     \n\
        \                        ⇩                                                       \n\
        \    ┌───────────────────────────────┐                                           \n\
        \    │ λ(x : Bool) → x : Bool → Bool │  User-defined anonymous function          \n\
        \    └───────────────────────────────┘                                           \n\
        \                               ⇧                                                \n\
        \                               The function's output type is ❰Bool❱             \n\
        \                                                                                \n\
        \                                                                                \n\
        \                     The function's input type is ❰Natural❱                     \n\
        \                     ⇩                                                          \n\
        \    ┌───────────────────────────────┐                                           \n\
        \    │ Natural/even : Natural → Bool │  Built-in function                        \n\
        \    └───────────────────────────────┘                                           \n\
        \                               ⇧                                                \n\
        \                               The function's output type is ❰Bool❱             \n\
        \                                                                                \n\
        \                                                                                \n\
        \                        The function's input kind is ❰Type❱                     \n\
        \                        ⇩                                                       \n\
        \    ┌───────────────────────────────┐                                           \n\
        \    │ λ(a : Type) → a : Type → Type │  Type-level functions are still functions \n\
        \    └───────────────────────────────┘                                           \n\
        \                               ⇧                                                \n\
        \                               The function's output kind is ❰Type❱             \n\
        \                                                                                \n\
        \                                                                                \n\
        \             The function's input kind is ❰Type❱                                \n\
        \             ⇩                                                                  \n\
        \    ┌────────────────────┐                                                      \n\
        \    │ List : Type → Type │  Built-in type-level function                        \n\
        \    └────────────────────┘                                                      \n\
        \                    ⇧                                                           \n\
        \                    The function's output kind is ❰Type❱                        \n\
        \                                                                                \n\
        \                                                                                \n\
        \                        Function's input has kind ❰Type❱                        \n\
        \                        ⇩                                                       \n\
        \    ┌─────────────────────────────────────────────────┐                         \n\
        \    │ List/head : ∀(a : Type) → (List a → Optional a) │  A function can return  \n\
        \    └─────────────────────────────────────────────────┘  another function       \n\
        \                                ⇧                                               \n\
        \                                Function's output has type ❰List a → Optional a❱\n\
        \                                                                                \n\
        \                                                                                \n\
        \                       The function's input type is ❰List Text❱                 \n\
        \                       ⇩                                                        \n\
        \    ┌────────────────────────────────────────────┐                              \n\
        \    │ List/head Text : List Text → Optional Text │  A function applied to an    \n\
        \    └────────────────────────────────────────────┘  argument can be a function  \n\
        \                                   ⇧                                            \n\
        \                                   The function's output type is ❰Optional Text❱\n\
        \                                                                                \n\
        \                                                                                \n\
        \An expression is not a function if the expression's type is not of the form     \n\
        \❰a → b❱.  For example, these are " <> _NOT <> " functions:                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────┐                                                             \n\
        \    │ 1 : Integer │  ❰1❱ is not a function because ❰Integer❱ is not the type of \n\
        \    └─────────────┘  a function                                                 \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────┐                                                  \n\
        \    │ Natural/even +2 : Bool │  ❰Natural/even +2❱ is not a function because     \n\
        \    └────────────────────────┘  ❰Bool❱ is not the type of a function            \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────┐                                                        \n\
        \    │ List Text : Type │  ❰List Text❱ is not a function because ❰Type❱ is not   \n\
        \    └──────────────────┘  the type of a function                                \n\
        \                                                                                \n\
        \                                                                                \n\
        \Some common reasons why you might get this error:                               \n\
        \                                                                                \n\
        \● You tried to add two ❰Integer❱s without a space around the ❰+❱, like this:    \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────┐                                                                     \n\
        \    │ 2+2 │                                                                     \n\
        \    └─────┘                                                                     \n\
        \                                                                                \n\
        \                                                                                \n\
        \  The above code is parsed as:                                                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────┐                                                                  \n\
        \    │ 2 (+2) │                                                                  \n\
        \    └────────┘                                                                  \n\
        \      ⇧                                                                         \n\
        \      The compiler thinks that this ❰2❱ is a function whose argument is ❰+2❱    \n\
        \                                                                                \n\
        \                                                                                \n\
        \  This is because the ❰+❱ symbol has two meanings: you use ❰+❱ to add two       \n\
        \  numbers, but you also can prefix ❰Integer❱ literals with a ❰+❱ to turn them   \n\
        \  into ❰Natural❱ literals (like ❰+2❱)                                           \n\
        \                                                                                \n\
        \  To fix the code, you need to put spaces around the ❰+❱ and also prefix each   \n\
        \  ❰2❱ with a ❰+❱, like this:                                                    \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────┐                                                                 \n\
        \    │ +2 + +2 │                                                                 \n\
        \    └─────────┘                                                                 \n\
        \                                                                                \n\
        \                                                                                \n\
        \  You can only add ❰Natural❱ numbers, which is why you must also change each    \n\
        \  ❰2❱ to ❰+2❱                                                                   \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \You tried to use the following expression as a function:                        \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... but this expression's type is:                                              \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... which is not a function type                                                \n"
      where
        txt0 = build expr0
        txt1 = build expr1

prettyTypeMessage (TypeMismatch expr0 expr1 expr2 expr3) = ErrorMessages {..}
  where
    short = "Wrong type of function argument"

    long =
        "Explanation: Every function declares what type or kind of argument to accept    \n\
        \                                                                                \n\
        \For example:                                                                    \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────┐                                           \n\
        \    │ λ(x : Bool) → x : Bool → Bool │  This anonymous function only accepts     \n\
        \    └───────────────────────────────┘  arguments that have type ❰Bool❱          \n\
        \                        ⇧                                                       \n\
        \                        The function's input type                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────┐                                           \n\
        \    │ Natural/even : Natural → Bool │  This built-in function only accepts      \n\
        \    └───────────────────────────────┘  arguments that have type ❰Natural❱       \n\
        \                     ⇧                                                          \n\
        \                     The function's input type                                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────┐                                           \n\
        \    │ λ(a : Type) → a : Type → Type │  This anonymous function only accepts     \n\
        \    └───────────────────────────────┘  arguments that have kind ❰Type❱          \n\
        \                        ⇧                                                       \n\
        \                        The function's input kind                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────┐                                                      \n\
        \    │ List : Type → Type │  This built-in function only accepts arguments that  \n\
        \    └────────────────────┘  have kind ❰Type❱                                    \n\
        \             ⇧                                                                  \n\
        \             The function's input kind                                          \n\
        \                                                                                \n\
        \                                                                                \n\
        \For example, the following expressions are valid:                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────┐                                                  \n\
        \    │ (λ(x : Bool) → x) True │  ❰True❱ has type ❰Bool❱, which matches the type  \n\
        \    └────────────────────────┘  of argument that the anonymous function accepts \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────┐                                                         \n\
        \    │ Natural/even +2 │  ❰+2❱ has type ❰Natural❱, which matches the type of     \n\
        \    └─────────────────┘  argument that the ❰Natural/even❱ function accepts,     \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────┐                                                  \n\
        \    │ (λ(a : Type) → a) Bool │  ❰Bool❱ has kind ❰Type❱, which matches the kind  \n\
        \    └────────────────────────┘  of argument that the anonymous function accepts \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────┐                                                               \n\
        \    │ List Text │  ❰Text❱ has kind ❰Type❱, which matches the kind of argument   \n\
        \    └───────────┘  that that the ❰List❱ function accepts                        \n\
        \                                                                                \n\
        \                                                                                \n\
        \However, you can " <> _NOT <> " apply a function to the wrong type or kind of argument\n\
        \                                                                                \n\
        \For example, the following expressions are not valid:                           \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────┐                                                   \n\
        \    │ (λ(x : Bool) → x) \"A\" │  ❰\"A\"❱ has type ❰Text❱, but the anonymous function\n\
        \    └───────────────────────┘  expects an argument that has type ❰Bool❱         \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────┐                                                        \n\
        \    │ Natural/even \"A\" │  ❰\"A\"❱ has type ❰Text❱, but the ❰Natural/even❱ function\n\
        \    └──────────────────┘  expects an argument that has type ❰Natural❱           \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────┐                                                  \n\
        \    │ (λ(a : Type) → a) True │  ❰True❱ has type ❰Bool❱, but the anonymous       \n\
        \    └────────────────────────┘  function expects an argument of kind ❰Type❱     \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────┐                                                                  \n\
        \    │ List 1 │  ❰1❱ has type ❰Integer❱, but the ❰List❱ function expects an      \n\
        \    └────────┘  argument that has kind ❰Type❱                                   \n\
        \                                                                                \n\
        \                                                                                \n\
        \Some common reasons why you might get this error:                               \n\
        \                                                                                \n\
        \● You omit a function argument by mistake:                                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────┐                                                   \n\
        \    │ List/head   [1, 2, 3] │                                                   \n\
        \    └───────────────────────┘                                                   \n\
        \                ⇧                                                               \n\
        \                ❰List/head❱ is missing the first argument,                      \n\
        \                which should be: ❰Integer❱                                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \● You supply an ❰Integer❱ literal to a function that expects a ❰Natural❱        \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────┐                                                          \n\
        \    │ Natural/even 2 │                                                          \n\
        \    └────────────────┘                                                          \n\
        \                   ⇧                                                            \n\
        \                   This should be ❰+2❱                                          \n\
        \                                                                                \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \You tried to invoke the following function:                                     \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... which expects an argument of type or kind:                                  \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... on the following argument:                                                  \n\
        \                                                                                \n\
        \↳ " <> txt2 <> "                                                                \n\
        \                                                                                \n\
        \... which has a different type or kind:                                         \n\
        \                                                                                \n\
        \↳ " <> txt3 <> "                                                                \n"
      where
        txt0 = build expr0
        txt1 = build expr1
        txt2 = build expr2
        txt3 = build expr3

prettyTypeMessage (AnnotMismatch expr0 expr1 expr2) = ErrorMessages {..}
  where
    short = "Expression doesn't match annotation"

    long =
        "Explanation: You can annotate an expression with its type or kind using the     \n\
        \❰:❱ symbol, like this:                                                          \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────┐                                                                   \n\
        \    │ x : t │  ❰x❱ is an expression and ❰t❱ is the annotated type or kind of ❰x❱\n\
        \    └───────┘                                                                   \n\
        \                                                                                \n\
        \The type checker verifies that the expression's type or kind matches the        \n\
        \provided annotation                                                             \n\
        \                                                                                \n\
        \For example, all of the following are valid annotations that the type checker   \n\
        \accepts:                                                                        \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────┐                                                             \n\
        \    │ 1 : Integer │  ❰1❱ is an expression that has type ❰Integer❱, so the type  \n\
        \    └─────────────┘  checker accepts the annotation                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────┐                                                  \n\
        \    │ Natural/even +2 : Bool │  ❰Natural/even +2❱ has type ❰Bool❱, so the type  \n\
        \    └────────────────────────┘  checker accepts the annotation                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────┐                                                      \n\
        \    │ List : Type → Type │  ❰List❱ is an expression that has kind ❰Type → Type❱,\n\
        \    └────────────────────┘  so the type checker accepts the annotation          \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────┐                                                        \n\
        \    │ List Text : Type │  ❰List Text❱ is an expression that has kind ❰Type❱, so \n\
        \    └──────────────────┘  the type checker accepts the annotation               \n\
        \                                                                                \n\
        \                                                                                \n\
        \However, the following annotations are " <> _NOT <> " valid and the type checker will\n\
        \reject them:                                                                    \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────┐                                                                \n\
        \    │ 1 : Text │  The type checker rejects this because ❰1❱ does not have type  \n\
        \    └──────────┘  ❰Text❱                                                        \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────┐                                                             \n\
        \    │ List : Type │  ❰List❱ does not have kind ❰Type❱                           \n\
        \    └─────────────┘                                                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \Some common reasons why you might get this error:                               \n\
        \                                                                                \n\
        \● The Haskell Dhall interpreter implicitly inserts a top-level annotation       \n\
        \  matching the expected type                                                    \n\
        \                                                                                \n\
        \  For example, if you run the following Haskell code:                           \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────┐                                           \n\
        \    │ >>> input auto \"1\" :: IO Text │                                         \n\
        \    └───────────────────────────────┘                                           \n\
        \                                                                                \n\
        \                                                                                \n\
        \  ... then the interpreter will actually type check the following annotated     \n\
        \  expression:                                                                   \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────┐                                                                \n\
        \    │ 1 : Text │                                                                \n\
        \    └──────────┘                                                                \n\
        \                                                                                \n\
        \                                                                                \n\
        \  ... and then type-checking will fail                                          \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \You or the interpreter annotated this expression:                               \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... with this type or kind:                                                     \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... but the inferred type or kind of the expression is actually:                \n\
        \                                                                                \n\
        \↳ " <> txt2 <> "                                                                \n"
      where
        txt0 = build expr0
        txt1 = build expr1
        txt2 = build expr2

prettyTypeMessage Untyped = ErrorMessages {..}
  where
    short = "❰Kind❱ has no type or kind"

    long =
        "Explanation: There are four levels of expressions that form a hierarchy:        \n\
        \                                                                                \n\
        \● terms                                                                         \n\
        \● types                                                                         \n\
        \● kinds                                                                         \n\
        \● sorts                                                                         \n\
        \                                                                                \n\
        \The following example illustrates this hierarchy:                               \n\
        \                                                                                \n\
        \    ┌────────────────────────────┐                                              \n\
        \    │ \"ABC\" : Text : Type : Kind │                                            \n\
        \    └────────────────────────────┘                                              \n\
        \       ⇧      ⇧      ⇧      ⇧                                                   \n\
        \       term   type   kind   sort                                                \n\
        \                                                                                \n\
        \There is nothing above ❰Kind❱ in this hierarchy, so if you try to type check any\n\
        \expression containing ❰Kind❱ anywhere in the expression then type checking fails\n\
        \                                                                                \n\
        \Some common reasons why you might get this error:                               \n\
        \                                                                                \n\
        \● You supplied a kind where a type was expected                                 \n\
        \                                                                                \n\
        \  For example, the following expression will fail to type check:                \n\
        \                                                                                \n\
        \    ┌────────────────┐                                                          \n\
        \    │ [] : List Type │                                                          \n\
        \    └────────────────┘                                                          \n\
        \                ⇧                                                               \n\
        \                ❰Type❱ is a kind, not a type                                    \n"

prettyTypeMessage (InvalidPredicate expr0 expr1) = ErrorMessages {..}
  where
    short = "Invalid predicate for ❰if❱"

    long =
        "Explanation: Every ❰if❱ expression begins with a predicate which must have type \n\
        \❰Bool❱                                                                          \n\
        \                                                                                \n\
        \For example, these are valid ❰if❱ expressions:                                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────────────────┐                                            \n\
        \    │ if True then \"Yes\" else \"No\" │                                        \n\
        \    └──────────────────────────────┘                                            \n\
        \         ⇧                                                                      \n\
        \         Predicate                                                              \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────────┐                                 \n\
        \    │ λ(x : Bool) → if x then False else True │                                 \n\
        \    └─────────────────────────────────────────┘                                 \n\
        \                       ⇧                                                        \n\
        \                       Predicate                                                \n\
        \                                                                                \n\
        \                                                                                \n\
        \... but these are " <> _NOT <> " valid ❰if❱ expressions:                        \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────┐                                               \n\
        \    │ if 0 then \"Yes\" else \"No\" │  ❰0❱ does not have type ❰Bool❱            \n\
        \    └───────────────────────────┘                                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────────┐                                              \n\
        \    │ if \"\" then False else True │  ❰\"\"❱ does not have type ❰Bool❱          \n\
        \    └────────────────────────────┘                                              \n\
        \                                                                                \n\
        \                                                                                \n\
        \Some common reasons why you might get this error:                               \n\
        \                                                                                \n\
        \● You might be used to other programming languages that accept predicates other \n\
        \  than ❰Bool❱                                                                   \n\
        \                                                                                \n\
        \  For example, some languages permit ❰0❱ or ❰\"\"❱ as valid predicates and treat\n\
        \  them as equivalent to ❰False❱.  However, the Dhall language does not permit   \n\
        \  this                                                                          \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \Your ❰if❱ expression begins with the following predicate:                       \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... that has type:                                                              \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... but the predicate must instead have type ❰Bool❱                             \n"
      where
        txt0 = build expr0
        txt1 = build expr1

prettyTypeMessage (IfBranchMustBeTerm b expr0 expr1 expr2) =
    ErrorMessages {..}
  where
    short = "❰if❱ branch is not a term"

    long =
        "Explanation: Every ❰if❱ expression has a ❰then❱ and ❰else❱ branch, each of which\n\
        \is an expression:                                                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \                   Expression for ❰then❱ branch                                 \n\
        \                   ⇩                                                            \n\
        \    ┌────────────────────────────────┐                                          \n\
        \    │ if True then \"Hello, world!\"   │                                        \n\
        \    │         else \"Goodbye, world!\" │                                        \n\
        \    └────────────────────────────────┘                                          \n\
        \                   ⇧                                                            \n\
        \                   Expression for ❰else❱ branch                                 \n\
        \                                                                                \n\
        \                                                                                \n\
        \These expressions must be a \"term\", where a \"term\" is defined as an expression\n\
        \that has a type thas has kind ❰Type❱                                            \n\
        \                                                                                \n\
        \For example, the following expressions are all valid \"terms\":                 \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────┐                                                      \n\
        \    │ 1 : Integer : Type │  ❰1❱ is a term with a type (❰Integer❱) of kind ❰Type❱\n\
        \    └────────────────────┘                                                      \n\
        \      ⇧                                                                         \n\
        \      term                                                                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────┐                                     \n\
        \    │ Natural/odd : Natural → Bool : Type │  ❰Natural/odd❱ is a term with a type\n\
        \    └─────────────────────────────────────┘  (❰Natural → Bool❱) of kind ❰Type❱  \n\
        \      ⇧                                                                         \n\
        \      term                                                                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \However, the following expressions are " <> _NOT <> " valid terms:              \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────┐                                                      \n\
        \    │ Text : Type : Kind │  ❰Text❱ has kind (❰Type❱) of sort ❰Kind❱ and is      \n\
        \    └────────────────────┘  therefore not a term                                \n\
        \      ⇧                                                                         \n\
        \      type                                                                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────┐                                               \n\
        \    │ List : Type → Type : Kind │  ❰List❱ has kind (❰Type → Type❱) of sort      \n\
        \    └───────────────────────────┘  ❰Kind❱ and is therefore not a term           \n\
        \      ⇧                                                                         \n\
        \      type-level function                                                       \n\
        \                                                                                \n\
        \                                                                                \n\
        \This means that you cannot define an ❰if❱ expression that returns a type.  For  \n\
        \example, the following ❰if❱ expression is " <> _NOT <> " valid:                 \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────┐                                             \n\
        \    │ if True then Text else Bool │  Invalid ❰if❱ expression                    \n\
        \    └─────────────────────────────┘                                             \n\
        \                   ⇧         ⇧                                                  \n\
        \                   type      type                                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \Your ❰" <> txt0 <> "❱ branch of your ❰if❱ expression is:                        \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... which has kind:                                                             \n\
        \                                                                                \n\
        \↳ " <> txt2 <> "                                                                \n\
        \                                                                                \n\
        \... of sort:                                                                    \n\
        \                                                                                \n\
        \↳ " <> txt3 <> "                                                                \n\
        \                                                                                \n\
        \... and is not a term.  Therefore your ❰if❱ expression is not valid             \n"
      where
        txt0 = if b then "then" else "else"
        txt1 = build expr0
        txt2 = build expr1
        txt3 = build expr2

prettyTypeMessage (IfBranchMismatch expr0 expr1 expr2 expr3) =
    ErrorMessages {..}
  where
    short = "❰if❱ branches must have matching types"

    long =
        "Explanation: Every ❰if❱ expression has a ❰then❱ and ❰else❱ branch, each of which\n\
        \is an expression:                                                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \                   Expression for ❰then❱ branch                                 \n\
        \                   ⇩                                                            \n\
        \    ┌────────────────────────────────┐                                          \n\
        \    │ if True then \"Hello, world!\"   │                                        \n\
        \    │         else \"Goodbye, world!\" │                                        \n\
        \    └────────────────────────────────┘                                          \n\
        \                   ⇧                                                            \n\
        \                   Expression for ❰else❱ branch                                 \n\
        \                                                                                \n\
        \                                                                                \n\
        \These two expressions must have the same type.  For example, the following ❰if❱ \n\
        \expressions are all valid:                                                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────────────────────┐                                        \n\
        \    │ λ(b : Bool) → if b then 0 else 1 │ Both branches have type ❰Integer❱      \n\
        \    └──────────────────────────────────┘                                        \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────────┐                                              \n\
        \    │ λ(b : Bool) →              │                                              \n\
        \    │     if b then Natural/even │ Both branches have type ❰Natural → Bool❱     \n\
        \    │          else Natural/odd  │                                              \n\
        \    └────────────────────────────┘                                              \n\
        \                                                                                \n\
        \                                                                                \n\
        \However, the following expression is " <> _NOT <> " valid:                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \                   This branch has type ❰Integer❱                               \n\
        \                   ⇩                                                            \n\
        \    ┌────────────────────────┐                                                  \n\
        \    │ if True then 0         │                                                  \n\
        \    │         else \"ABC\"     │                                                \n\
        \    └────────────────────────┘                                                  \n\
        \                   ⇧                                                            \n\
        \                   This branch has type ❰Text❱                                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \The ❰then❱ and ❰else❱ branches must have matching types, even if the predicate  \n\
        \is always ❰True❱ or ❰False❱                                                     \n\
        \                                                                                \n\
        \Your ❰if❱ expression has the following ❰then❱ branch:                           \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... which has type:                                                             \n\
        \                                                                                \n\
        \↳ " <> txt2 <> "                                                                \n\
        \                                                                                \n\
        \... and the following ❰else❱ branch:                                            \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... which has a different type:                                                 \n\
        \                                                                                \n\
        \↳ " <> txt3 <> "                                                                \n\
        \                                                                                \n\
        \Fix your ❰then❱ and ❰else❱ branches to have matching types                      \n"
      where
        txt0 = build expr0
        txt1 = build expr1
        txt2 = build expr2
        txt3 = build expr3

prettyTypeMessage (InvalidListType expr0) = ErrorMessages {..}
  where
    short = "Invalid type for ❰List❱ elements"

    long =
        "Explanation: ❰List❱s can optionally document the type of their elements with a  \n\
        \type annotation, like this:                                                     \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────────────┐                                                \n\
        \    │ [1, 2, 3] : List Integer │  A ❰List❱ of three ❰Integer❱s                  \n\
        \    └──────────────────────────┘                                                \n\
        \                       ⇧                                                        \n\
        \                       The type of the ❰List❱'s elements, which are ❰Integer❱s  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────┐                                                       \n\
        \    │ [] : List Integer │  An empty ❰List❱                                      \n\
        \    └───────────────────┘                                                       \n\
        \                ⇧                                                               \n\
        \                You must specify the type when the ❰List❱ is empty              \n\
        \                                                                                \n\
        \                                                                                \n\
        \The element type must be a type and not something else.  For example, the       \n\
        \following element types are " <> _NOT <> " valid:                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────┐                                                            \n\
        \    │ ... : List 1 │                                                            \n\
        \    └──────────────┘                                                            \n\
        \                 ⇧                                                              \n\
        \                 This is an ❰Integer❱ and not a ❰Type❱                          \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────┐                                                         \n\
        \    │ ... : List Type │                                                         \n\
        \    └─────────────────┘                                                         \n\
        \                 ⇧                                                              \n\
        \                 This is a ❰Kind❱ and not a ❰Type❱                              \n\
        \                                                                                \n\
        \                                                                                \n\
        \You declared that the ❰List❱'s elements should have type:                       \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... which is not a ❰Type❱                                                       \n"
      where
        txt0 = build expr0

prettyTypeMessage MissingListType = do
    ErrorMessages {..}
  where
    short = "An empty list requires a type annotation"

    long =
        "Explanation: Lists do not require a type annotation if they have at least one   \n\
        \element:                                                                        \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────┐                                                               \n\
        \    │ [1, 2, 3] │  The compiler can infer that this list has type ❰List Integer❱\n\
        \    └───────────┘                                                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \However, empty lists still require a type annotation:                           \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────┐                                                       \n\
        \    │ [] : List Integer │  This type annotation is mandatory                    \n\
        \    └───────────────────┘                                                       \n\
        \                                                                                \n\
        \                                                                                \n\
        \You cannot supply an empty list without a type annotation                       \n"

prettyTypeMessage (MismatchedListElements i expr0 _expr1 expr2) =
    ErrorMessages {..}
  where
    short = "List elements should all have the same type"

    long =
        "Explanation: Every element in a list must have the same type                    \n\
        \                                                                                \n\
        \For example, this is a valid ❰List❱:                                            \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────┐                                                               \n\
        \    │ [1, 2, 3] │  Every element in this ❰List❱ is an ❰Integer❱                 \n\
        \    └───────────┘                                                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \.. but this is " <> _NOT <> " a valid ❰List❱:                                   \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────┐                                                           \n\
        \    │ [1, \"ABC\", 3] │  The first and second element have different types      \n\
        \    └───────────────┘                                                           \n\
        \                                                                                \n\
        \                                                                                \n\
        \Your first ❰List❱ element has this type:                                        \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... but the element at index #" <> txt1 <> " has this type instead:             \n\
        \                                                                                \n\
        \↳ " <> txt3 <> "                                                                \n"
      where
        txt0 = build expr0
        txt1 = build i
        txt3 = build expr2

prettyTypeMessage (InvalidListElement i expr0 _expr1 expr2) =
    ErrorMessages {..}
  where
    short = "List element has the wrong type"

    long =
        "Explanation: Every element in the list must have a type matching the type       \n\
        \annotation at the end of the list                                               \n\
        \                                                                                \n\
        \For example, this is a valid ❰List❱:                                            \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────────────┐                                                \n\
        \    │ [1, 2, 3] : List Integer │  Every element in this ❰List❱ is an ❰Integer❱  \n\
        \    └──────────────────────────┘                                                \n\
        \                                                                                \n\
        \                                                                                \n\
        \.. but this is " <> _NOT <> " a valid ❰List❱:                                   \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────────────────┐                                            \n\
        \    │ [1, \"ABC\", 3] : List Integer │  The second element is not an ❰Integer❱  \n\
        \    └──────────────────────────────┘                                            \n\
        \                                                                                \n\
        \                                                                                \n\
        \Your ❰List❱ elements should have this type:                                     \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... but the element at index #" <> txt1 <> " has this type instead:             \n\
        \                                                                                \n\
        \↳ " <> txt3 <> "                                                                \n"
      where
        txt0 = build expr0
        txt1 = build i
        txt3 = build expr2

prettyTypeMessage (InvalidOptionalType expr0) = ErrorMessages {..}
  where
    short = "Invalid type for ❰Optional❱ element"

    long =
        "Explanation: Every optional element ends with a type annotation for the element \n\
        \that might be present, like this:                                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────┐                                                  \n\
        \    │ [1] : Optional Integer │  An optional element that's present              \n\
        \    └────────────────────────┘                                                  \n\
        \                     ⇧                                                          \n\
        \                     The type of the ❰Optional❱ element, which is an ❰Integer❱  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────┐                                                  \n\
        \    │ [] : Optional Integer  │  An optional element that's absent               \n\
        \    └────────────────────────┘                                                  \n\
        \                    ⇧                                                           \n\
        \                    You still specify the type even when the element is absent  \n\
        \                                                                                \n\
        \                                                                                \n\
        \The element type must be a type and not something else.  For example, the       \n\
        \following element types are " <> _NOT <> " valid:                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────┐                                                        \n\
        \    │ ... : Optional 1 │                                                        \n\
        \    └──────────────────┘                                                        \n\
        \                     ⇧                                                          \n\
        \                     This is an ❰Integer❱ and not a ❰Type❱                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────┐                                                     \n\
        \    │ ... : Optional Type │                                                     \n\
        \    └─────────────────────┘                                                     \n\
        \                     ⇧                                                          \n\
        \                     This is a ❰Kind❱ and not a ❰Type❱                          \n\
        \                                                                                \n\
        \                                                                                \n\
        \Even if the element is absent you still must specify a valid type               \n\
        \                                                                                \n\
        \You declared that the ❰Optional❱ element should have type:                      \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... which is not a ❰Type❱                                                       \n"
      where
        txt0 = build expr0

prettyTypeMessage (InvalidOptionalElement expr0 expr1 expr2) = ErrorMessages {..}
  where
    short = "❰Optional❱ element has the wrong type"

    long =
        "Explanation: An ❰Optional❱ element must have a type matching the type annotation\n\
        \                                                                                \n\
        \For example, this is a valid ❰Optional❱ value:                                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────┐                                                  \n\
        \    │ [1] : Optional Integer │  ❰1❱ is an ❰Integer❱, which matches the type     \n\
        \    └────────────────────────┘                                                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \... but this is " <> _NOT <> " a valid ❰Optional❱ value:                        \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────────┐                                              \n\
        \    │ [\"ABC\"] : Optional Integer │  ❰\"ABC\"❱ is not an ❰Integer❱             \n\
        \    └────────────────────────────┘                                              \n\
        \                                                                                \n\
        \                                                                                \n\
        \Your ❰Optional❱ element should have this type:                                  \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... but the element you provided:                                               \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... has this type instead:                                                      \n\
        \                                                                                \n\
        \↳ " <> txt2 <> "                                                                \n"
      where
        txt0 = build expr0
        txt1 = build expr1
        txt2 = build expr2

prettyTypeMessage (InvalidOptionalLiteral n) = ErrorMessages {..}
  where
    short = "Multiple ❰Optional❱ elements not allowed"

    long =
        "Explanation: The syntax for ❰Optional❱ values resembles the syntax for ❰List❱s: \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────┐                                                   \n\
        \    │ [] : Optional Integer │  An ❰Optional❱ value which is absent              \n\
        \    └───────────────────────┘                                                   \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────┐                                                   \n\
        \    │ [] : List     Integer │  An empty (0-element) ❰List❱                      \n\
        \    └───────────────────────┘                                                   \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────┐                                                  \n\
        \    │ [1] : Optional Integer │  An ❰Optional❱ value which is present            \n\
        \    └────────────────────────┘                                                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────┐                                                  \n\
        \    │ [1] : List     Integer │  A singleton (1-element) ❰List❱                  \n\
        \    └────────────────────────┘                                                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \However, an ❰Optional❱ value can " <> _NOT <> " have more than one element, whereas a\n\
        \❰List❱ can have multiple elements:                                              \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────┐                                               \n\
        \    │ [1, 2] : Optional Integer │  Invalid: multiple elements " <> _NOT <> " allowed\n\
        \    └───────────────────────────┘                                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────┐                                               \n\
        \    │ [1, 2] : List     Integer │  Valid: multiple elements allowed             \n\
        \    └───────────────────────────┘                                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \Some common reasons why you might get this error:                               \n\
        \                                                                                \n\
        \● You accidentally typed ❰Optional❱ when you meant ❰List❱, like this:           \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────────────────────────────────┐                      \n\
        \    │ List/length Integer ([1, 2, 3] : Optional Integer) │                      \n\
        \    └────────────────────────────────────────────────────┘                      \n\
        \                                       ⇧                                        \n\
        \                                       This should be ❰List❱ instead            \n\
        \                                                                                \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \Your ❰Optional❱ value had this many elements:                                   \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... when an ❰Optional❱ value can only have at most one element                  \n"
      where
        txt0 = build n

prettyTypeMessage (InvalidFieldType k expr0) = ErrorMessages {..}
  where
    short = "Invalid field type"

    long =
        "Explanation: Every record type documents the type of each field, like this:     \n\
        \                                                                                \n\
        \    ┌──────────────────────────────────────────────┐                            \n\
        \    │ { foo : Integer, bar : Integer, baz : Text } │                            \n\
        \    └──────────────────────────────────────────────┘                            \n\
        \                                                                                \n\
        \However, fields cannot be annotated with expressions other than types           \n\
        \                                                                                \n\
        \For example, these record types are " <> _NOT <> " valid:                       \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────────┐                                              \n\
        \    │ { foo : Integer, bar : 1 } │                                              \n\
        \    └────────────────────────────┘                                              \n\
        \                             ⇧                                                  \n\
        \                             ❰1❱ is an ❰Integer❱ and not a ❰Type❱               \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────┐                                           \n\
        \    │ { foo : Integer, bar : Type } │                                           \n\
        \    └───────────────────────────────┘                                           \n\
        \                             ⇧                                                  \n\
        \                             ❰Type❱ is a ❰Kind❱ and not a ❰Type❱                \n\
        \                                                                                \n\
        \                                                                                \n\
        \You provided a record type with a key named:                                    \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... annotated with the following expression:                                    \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... which is not a type                                                         \n"
      where
        txt0 = build k
        txt1 = build expr0

prettyTypeMessage (InvalidField k expr0) = ErrorMessages {..}
  where
    short = "Invalid field"

    long =
        "Explanation: Every record literal is a set of fields assigned to values, like   \n\
        \this:                                                                           \n\
        \                                                                                \n\
        \    ┌────────────────────────────────────────┐                                  \n\
        \    │ { foo = 100, bar = True, baz = \"ABC\" } │                                \n\
        \    └────────────────────────────────────────┘                                  \n\
        \                                                                                \n\
        \However, fields can only be terms and cannot be types or kinds                  \n\
        \                                                                                \n\
        \For example, these record literals are " <> _NOT <> " valid:                    \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────┐                                               \n\
        \    │ { foo = 100, bar = Text } │                                               \n\
        \    └───────────────────────────┘                                               \n\
        \                         ⇧                                                      \n\
        \                         ❰Text❱ is a type and not a term                        \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────┐                                               \n\
        \    │ { foo = 100, bar = Type } │                                               \n\
        \    └───────────────────────────┘                                               \n\
        \                         ⇧                                                      \n\
        \                         ❰Type❱ is a kind and not a term                        \n\
        \                                                                                \n\
        \                                                                                \n\
        \You provided a record literal with a key named:                                 \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... whose value is:                                                             \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... which is not a term                                                         \n"
      where
        txt0 = build k
        txt1 = build expr0

prettyTypeMessage (InvalidAlternativeType k expr0) = ErrorMessages {..}
  where
    short = "Invalid alternative"

    long =
        "Explanation: Every union literal begins by selecting one alternative and        \n\
        \specifying the value for that alternative, like this:                           \n\
        \                                                                                \n\
        \                                                                                \n\
        \        Select the ❰Left❱ alternative, whose value is ❰True❱                    \n\
        \        ⇩                                                                       \n\
        \    ┌──────────────────────────────────┐                                        \n\
        \    │ < Left = True, Right : Natural > │  A union literal with two alternatives \n\
        \    └──────────────────────────────────┘                                        \n\
        \                                                                                \n\
        \                                                                                \n\
        \However, this value must be a term and not a type.  For example, the following  \n\
        \values are " <> _NOT <> " valid:                                                \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────────────────────┐                                        \n\
        \    │ < Left = Text, Right : Natural > │  Invalid union literal                 \n\
        \    └──────────────────────────────────┘                                        \n\
        \               ⇧                                                                \n\
        \               This is a type and not a term                                    \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────┐                                           \n\
        \    │ < Left = Type, Right : Type > │  Invalid union type                       \n\
        \    └───────────────────────────────┘                                           \n\
        \               ⇧                                                                \n\
        \               This is a kind and not a term                                    \n\
        \                                                                                \n\
        \                                                                                \n\
        \Some common reasons why you might get this error:                               \n\
        \                                                                                \n\
        \● You accidentally typed ❰=❱ instead of ❰:❱ for a union literal with one        \n\
        \  alternative:                                                                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────┐                                                      \n\
        \    │ < Example = Text > │                                                      \n\
        \    └────────────────────┘                                                      \n\
        \                ⇧                                                               \n\
        \                This could be ❰:❱ instead                                       \n\
        \                                                                                \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \You provided a union literal with an alternative named:                         \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... whose value is:                                                             \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... which is not a term                                                         \n"
      where
        txt0 = build k
        txt1 = build expr0

prettyTypeMessage (InvalidAlternative k expr0) = ErrorMessages {..}
  where
    short = "Invalid alternative"

    long =
        "Explanation: Every union type specifies the type of each alternative, like this:\n\
        \                                                                                \n\
        \                                                                                \n\
        \               The type of the first alternative is ❰Bool❱                      \n\
        \               ⇩                                                                \n\
        \    ┌──────────────────────────────────┐                                        \n\
        \    │ < Left : Bool, Right : Natural > │  A union type with two alternatives    \n\
        \    └──────────────────────────────────┘                                        \n\
        \                             ⇧                                                  \n\
        \                             The type of the second alternative is ❰Natural❱    \n\
        \                                                                                \n\
        \                                                                                \n\
        \However, these alternatives can only be annotated with types.  For example, the \n\
        \following union types are " <> _NOT <> " valid:                                 \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────────┐                                              \n\
        \    │ < Left : Bool, Right : 1 > │  Invalid union type                          \n\
        \    └────────────────────────────┘                                              \n\
        \                             ⇧                                                  \n\
        \                             This is a term and not a type                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────┐                                           \n\
        \    │ < Left : Bool, Right : Type > │  Invalid union type                       \n\
        \    └───────────────────────────────┘                                           \n\
        \                             ⇧                                                  \n\
        \                             This is a kind and not a type                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \Some common reasons why you might get this error:                               \n\
        \                                                                                \n\
        \● You accidentally typed ❰:❱ instead of ❰=❱ for a union literal with one        \n\
        \  alternative:                                                                  \n\
        \                                                                                \n\
        \    ┌─────────────────┐                                                         \n\
        \    │ < Example : 1 > │                                                         \n\
        \    └─────────────────┘                                                         \n\
        \                ⇧                                                               \n\
        \                This could be ❰=❱ instead                                       \n\
        \                                                                                \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \You provided a union type with an alternative named:                            \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... annotated with the following expression which is not a type:                \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n"
      where
        txt0 = build k
        txt1 = build expr0

prettyTypeMessage (ListAppendMismatch expr0 expr1) = ErrorMessages {..}
  where
    short = "You can only append ❰List❱s with matching element types"

    long =
        "Explanation: You can append two ❰List❱s using the ❰#❱ operator, like this:      \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────┐                                                      \n\
        \    │ [1, 2, 3] # [4, 5] │                                                      \n\
        \    └────────────────────┘                                                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \... but you cannot append two ❰List❱s if they have different element types.     \n\
        \For example, the following expression is " <> _NOT <> " valid:                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \       These elements have type ❰Integer❱                                       \n\
        \       ⇩                                                                        \n\
        \    ┌───────────────────────────┐                                               \n\
        \    │ [1, 2, 3] # [True, False] │  Invalid: the element types don't match       \n\
        \    └───────────────────────────┘                                               \n\
        \                  ⇧                                                             \n\
        \                  These elements have type ❰Bool❱                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \You tried to append a ❰List❱ thas has elements of type:                         \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... with another ❰List❱ that has elements of type:                              \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... and those two types do not match                                            \n"
      where
        txt0 = build expr0
        txt1 = build expr1

prettyTypeMessage (DuplicateAlternative k) = ErrorMessages {..}
  where
    short = "Duplicate union alternative"

    long =
        "Explanation: Unions may not have two alternatives that share the same name      \n\
        \                                                                                \n\
        \For example, the following expressions are " <> _NOT <> " valid:                \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────┐                                             \n\
        \    │ < foo = True | foo : Text > │  Invalid: ❰foo❱ appears twice               \n\
        \    └─────────────────────────────┘                                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────────────┐                                   \n\
        \    │ < foo = 1 | bar : Bool | bar : Text > │  Invalid: ❰bar❱ appears twice     \n\
        \    └───────────────────────────────────────┘                                   \n\
        \                                                                                \n\
        \                                                                                \n\
        \You have more than one alternative named:                                       \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n"
      where
        txt0 = build k

prettyTypeMessage (MustCombineARecord c expr0 expr1) = ErrorMessages {..}
  where
    short = "You can only combine records"

    long =
        "Explanation: You can combine records using the ❰" <> op <> "❱ operator, like this:\n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────────────────┐                               \n\
        \    │ { foo = 1, bar = \"ABC\" } " <> op <> " { baz = True } │                  \n\
        \    └───────────────────────────────────────────┘                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────────────┐                             \n\
        \    │ λ(r : { foo : Bool }) → r " <> op <> " { bar = \"ABC\" } │                \n\
        \    └─────────────────────────────────────────────┘                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \... but you cannot combine values that are not records.                         \n\
        \                                                                                \n\
        \For example, the following expressions are " <> _NOT <> " valid:                \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────────────────┐                                            \n\
        \    │ { foo = 1, bar = \"ABC\" } " <> op <> " 1 │                               \n\
        \    └──────────────────────────────┘                                            \n\
        \                                 ⇧                                              \n\
        \                                 Invalid: Not a record                          \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────────────────┐                               \n\
        \    │ { foo = 1, bar = \"ABC\" } " <> op <> " { baz : Bool } │                  \n\
        \    └───────────────────────────────────────────┘                               \n\
        \                                 ⇧                                              \n\
        \                                 Invalid: This is a record type and not a record\n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────────────────┐                               \n\
        \    │ { foo = 1, bar = \"ABC\" } " <> op <> " < baz = True > │                  \n\
        \    └───────────────────────────────────────────┘                               \n\
        \                                 ⇧                                              \n\
        \                                 Invalid: This is a union and not a record      \n\
        \                                                                                \n\
        \                                                                                \n\
        \You tried to combine the following value:                                       \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... which is not a record, but is actually a:                                   \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n"
      where
        op   = build c
        txt0 = build expr0
        txt1 = build expr1

prettyTypeMessage (FieldCollision k) = ErrorMessages {..}
  where
    short = "Field collision"

    long =
        "Explanation: You can combine records if they don't share any fields in common,  \n\
        \like this:                                                                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────────────────┐                               \n\
        \    │ { foo = 1, bar = \"ABC\" } ∧ { baz = True } │                             \n\
        \    └───────────────────────────────────────────┘                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────────────────────┐                                  \n\
        \    │ λ(r : { baz : Bool}) → { foo = 1 } ∧ r │                                  \n\
        \    └────────────────────────────────────────┘                                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \... but you cannot merge two records that share the same field                  \n\
        \                                                                                \n\
        \For example, the following expression is " <> _NOT <> " valid:                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────────────────┐                               \n\
        \    │ { foo = 1, bar = \"ABC\" } ∧ { foo = True } │  Invalid: Colliding ❰foo❱ fields\n\
        \    └───────────────────────────────────────────┘                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \Some common reasons why you might get this error:                               \n\
        \                                                                                \n\
        \● You tried to use ❰∧❱ to update a field's value, like this:                    \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────────────────────┐                                  \n\
        \    │ { foo = 1, bar = \"ABC\" } ∧ { foo = 2 } │                                \n\
        \    └────────────────────────────────────────┘                                  \n\
        \                                   ⇧                                            \n\
        \                                   Invalid attempt to update ❰foo❱'s value to ❰2❱\n\
        \                                                                                \n\
        \  Field updates are intentionally not allowed as the Dhall language discourages \n\
        \  patch-oriented programming                                                    \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \You combined two records that share the following field:                        \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... which is not allowed                                                        \n"
      where
        txt0 = build k

prettyTypeMessage (MustMergeARecord expr0 expr1) = ErrorMessages {..}
  where
    short = "❰merge❱ expects a record of handlers"

    long =
        "Explanation: You can ❰merge❱ the alternatives of a union using a record with one\n\
        \handler per alternative, like this:                                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────────────────────────────────────┐     \n\
        \    │     let union    = < Left = +2 | Right : Bool >                     │     \n\
        \    │ in  let handlers = { Left = Natural/even, Right = λ(x : Bool) → x } │     \n\
        \    │ in  merge handlers union : Bool                                     │     \n\
        \    └─────────────────────────────────────────────────────────────────────┘     \n\
        \                                                                                \n\
        \                                                                                \n\
        \... but the first argument to ❰merge❱ must be a record and not some other type. \n\
        \                                                                                \n\
        \For example, the following expression is " <> _NOT <> " valid:                 \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────────┐                                 \n\
        \    │ let handler = λ(x : Bool) → x           │                                 \n\
        \    │ in  merge handler < Foo = True > : True │                                 \n\
        \    └─────────────────────────────────────────┘                                 \n\
        \                ⇧                                                               \n\
        \                Invalid: ❰handler❱ isn't a record                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \Some common reasons why you might get this error:                               \n\
        \                                                                                \n\
        \● You accidentally provide an empty record type instead of an empty record when \n\
        \  you ❰merge❱ an empty union:                                                   \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────────────────────────────┐                                \n\
        \    │ λ(x : <>) → λ(a : Type) → merge {} x : a │                                \n\
        \    └──────────────────────────────────────────┘                                \n\
        \                                      ⇧                                         \n\
        \                                      This should be ❰{=}❱ instead              \n\
        \                                                                                \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \You provided the following handler:                                             \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... which is not a record, but is actually a value of type:                     \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n"
      where
        txt0 = build expr0
        txt1 = build expr1

prettyTypeMessage (MustMergeUnion expr0 expr1) = ErrorMessages {..}
  where
    short = "❰merge❱ expects a union"

    long =
        "Explanation: You can ❰merge❱ the alternatives of a union using a record with one\n\
        \handler per alternative, like this:                                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────────────────────────────────────┐     \n\
        \    │     let union    = < Left = +2 | Right : Bool >                     │     \n\
        \    │ in  let handlers = { Left = Natural/even, Right = λ(x : Bool) → x } │     \n\
        \    │ in  merge handlers union : Bool                                     │     \n\
        \    └─────────────────────────────────────────────────────────────────────┘     \n\
        \                                                                                \n\
        \                                                                                \n\
        \... but the second argument to ❰merge❱ must be a union and not some other type. \n\
        \                                                                                \n\
        \For example, the following expression is " <> _NOT <> " valid:                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────────────────────────────┐                                \n\
        \    │ let handlers = { Foo = λ(x : Bool) → x } │                                \n\
        \    │ in  merge handlers True : True           │                                \n\
        \    └──────────────────────────────────────────┘                                \n\
        \                         ⇧                                                      \n\
        \                         Invalid: ❰True❱ isn't a union                          \n\
        \                                                                                \n\
        \                                                                                \n\
        \You tried to ❰merge❱ this expression:                                           \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... which is not a union, but is actually a value of type:                      \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n"
      where
        txt0 = build expr0
        txt1 = build expr1

prettyTypeMessage (UnusedHandler ks) = ErrorMessages {..}
  where
    short = "Unused handler"

    long =
        "Explanation: You can ❰merge❱ the alternatives of a union using a record with one\n\
        \handler per alternative, like this:                                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────────────────────────────────────┐     \n\
        \    │     let union    = < Left = +2 | Right : Bool >                     │     \n\
        \    │ in  let handlers = { Left = Natural/even, Right = λ(x : Bool) → x } │     \n\
        \    │ in  merge handlers union : Bool                                     │     \n\
        \    └─────────────────────────────────────────────────────────────────────┘     \n\
        \                                                                                \n\
        \                                                                                \n\
        \... but you must provide exactly one handler per alternative in the union.  You \n\
        \cannot supply extra handlers                                                    \n\
        \                                                                                \n\
        \For example, the following expression is " <> _NOT <> " valid:                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────────────┐                                   \n\
        \    │     let union    = < Left = +2 >      │  The ❰Right❱ alternative is missing\n\
        \    │ in  let handlers =                    │                                   \n\
        \    │             { Left  = Natural/even    │                                   \n\
        \    │             , Right = λ(x : Bool) → x │  Invalid: ❰Right❱ handler isn't used\n\
        \    │             }                         │                                   \n\
        \    │ in  merge handlers union : Bool       │                                   \n\
        \    └───────────────────────────────────────┘                                   \n\
        \                                                                                \n\
        \                                                                                \n\
        \You provided the following handlers:                                            \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... which had no matching alternatives in the union you tried to ❰merge❱        \n"
      where
        txt0 = build (Text.intercalate ", " (Data.Set.toList ks))

prettyTypeMessage (MissingHandler ks) = ErrorMessages {..}
  where
    short = "Missing handler"

    long =
        "Explanation: You can ❰merge❱ the alternatives of a union using a record with one\n\
        \handler per alternative, like this:                                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────────────────────────────────────┐     \n\
        \    │     let union    = < Left = +2 | Right : Bool >                     │     \n\
        \    │ in  let handlers = { Left = Natural/even, Right = λ(x : Bool) → x } │     \n\
        \    │ in  merge handlers union : Bool                                     │     \n\
        \    └─────────────────────────────────────────────────────────────────────┘     \n\
        \                                                                                \n\
        \                                                                                \n\
        \... but you must provide exactly one handler per alternative in the union.  You \n\
        \cannot omit any handlers                                                        \n\
        \                                                                                \n\
        \For example, the following expression is " <> _NOT <> " valid:                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \                                              Invalid: Missing ❰Right❱ handler  \n\
        \                                              ⇩                                 \n\
        \    ┌─────────────────────────────────────────────────┐                         \n\
        \    │     let handlers = { Left = Natural/even }      │                         \n\
        \    │ in  let union    = < Left = +2 | Right : Bool > │                         \n\
        \    │ in  merge handlers union : Bool                 │                         \n\
        \    └─────────────────────────────────────────────────┘                         \n\
        \                                                                                \n\
        \                                                                                \n\
        \Note that you need to provide handlers for other alternatives even if those     \n\
        \alternatives are never used                                                     \n\
        \                                                                                \n\
        \You need to supply the following handlers:                                      \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n"
      where
        txt0 = build (Text.intercalate ", " (Data.Set.toList ks))

prettyTypeMessage MissingMergeType =
    ErrorMessages {..}
  where
    short = "An empty ❰merge❱ requires a type annotation"

    long =
        "Explanation: A ❰merge❱ does not require a type annotation if the union has at   \n\
        \least one alternative, like this                                                \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────────────────────────────────────┐     \n\
        \    │     let union    = < Left = +2 | Right : Bool >                     │     \n\
        \    │ in  let handlers = { Left = Natural/even, Right = λ(x : Bool) → x } │     \n\
        \    │ in  merge handlers union                                            │     \n\
        \    └─────────────────────────────────────────────────────────────────────┘     \n\
        \                                                                                \n\
        \                                                                                \n\
        \However, you must provide a type annotation when merging an empty union:        \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────────────┐                                          \n\
        \    │ λ(a : <>) → merge {=} a : Bool │                                          \n\
        \    └────────────────────────────────┘                                          \n\
        \                                ⇧                                               \n\
        \                                This can be any type                            \n\
        \                                                                                \n\
        \                                                                                \n\
        \You can provide any type at all as the annotation, since merging an empty       \n\
        \union can produce any type of output                                            \n"

prettyTypeMessage (HandlerInputTypeMismatch expr0 expr1 expr2) =
    ErrorMessages {..}
  where
    short = "Wrong handler input type"

    long =
        "Explanation: You can ❰merge❱ the alternatives of a union using a record with one\n\
        \handler per alternative, like this:                                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────────────────────────────────────┐     \n\
        \    │     let union    = < Left = +2 | Right : Bool >                     │     \n\
        \    │ in  let handlers = { Left = Natural/even, Right = λ(x : Bool) → x } │     \n\
        \    │ in  merge handlers union : Bool                                     │     \n\
        \    └─────────────────────────────────────────────────────────────────────┘     \n\
        \                                                                                \n\
        \                                                                                \n\
        \... as long as the input type of each handler function matches the type of the  \n\
        \corresponding alternative:                                                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────────────────────────────────┐               \n\
        \    │ union    : < Left : Natural       | Right : Bool        > │               \n\
        \    └───────────────────────────────────────────────────────────┘               \n\
        \                          ⇧                       ⇧                             \n\
        \                   These must match        These must match                     \n\
        \                          ⇩                       ⇩                             \n\
        \    ┌───────────────────────────────────────────────────────────┐               \n\
        \    │ handlers : { Left : Natural → Bool, Right : Bool → Bool } │               \n\
        \    └───────────────────────────────────────────────────────────┘               \n\
        \                                                                                \n\
        \                                                                                \n\
        \For example, the following expression is " <> _NOT <> " valid:                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \      Invalid: Doesn't match the type of the ❰Right❱ alternative                \n\
        \                                                               ⇩                \n\
        \    ┌──────────────────────────────────────────────────────────────────────┐    \n\
        \    │     let handlers = { Left = Natural/even | Right = λ(x : Text) → x } │    \n\
        \    │ in  let union    = < Left = +2 | Right : Bool >                      │    \n\
        \    │ in  merge handlers union : Bool                                      │    \n\
        \    └──────────────────────────────────────────────────────────────────────┘    \n\
        \                                                                                \n\
        \                                                                                \n\
        \Your handler for the following alternative:                                     \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... needs to accept an input value of type:                                     \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... but actually accepts an input value of a different type:                    \n\
        \                                                                                \n\
        \↳ " <> txt2 <> "                                                                \n"
      where
        txt0 = build expr0
        txt1 = build expr1
        txt2 = build expr2

prettyTypeMessage (InvalidHandlerOutputType expr0 expr1 expr2) =
    ErrorMessages {..}
  where
    short = "Wrong handler output type"

    long =
        "Explanation: You can ❰merge❱ the alternatives of a union using a record with one\n\
        \handler per alternative, like this:                                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────────────────────────────────────┐     \n\
        \    │     let union    = < Left = +2 | Right : Bool >                     │     \n\
        \    │ in  let handlers = { Left = Natural/even, Right = λ(x : Bool) → x } │     \n\
        \    │ in  merge handlers union : Bool                                     │     \n\
        \    └─────────────────────────────────────────────────────────────────────┘     \n\
        \                                                                                \n\
        \                                                                                \n\
        \... as long as the output type of each handler function matches the declared type\n\
        \of the result:                                                                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────────────────────────────────┐               \n\
        \    │ handlers : { Left : Natural → Bool, Right : Bool → Bool } │               \n\
        \    └───────────────────────────────────────────────────────────┘               \n\
        \                                    ⇧                    ⇧                      \n\
        \                                    These output types ...                      \n\
        \                                                                                \n\
        \                             ... must match the declared type of the ❰merge❱    \n\
        \                             ⇩                                                  \n\
        \    ┌─────────────────────────────┐                                             \n\
        \    │ merge handlers union : Bool │                                             \n\
        \    └─────────────────────────────┘                                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \For example, the following expression is " <> _NOT <> " valid:                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────────────────────────────────────────────────────────┐    \n\
        \    │     let union    = < Left = +2 | Right : Bool >                      │    \n\
        \    │ in  let handlers = { Left = Natural/even, Right = λ(x : Bool) → x }  │    \n\
        \    │ in  merge handlers union : Text                                      │    \n\
        \    └──────────────────────────────────────────────────────────────────────┘    \n\
        \                                 ⇧                                              \n\
        \                                 Invalid: Doesn't match output of either handler\n\
        \                                                                                \n\
        \                                                                                \n\
        \Your handler for the following alternative:                                     \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... needs to return an output value of type:                                    \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... but actually returns an output value of a different type:                   \n\
        \                                                                                \n\
        \↳ " <> txt2 <> "                                                                \n"
      where
        txt0 = build expr0
        txt1 = build expr1
        txt2 = build expr2

prettyTypeMessage (HandlerOutputTypeMismatch key0 expr0 key1 expr1) =
    ErrorMessages {..}
  where
    short = "Handlers should have the same output type"

    long =
        "Explanation: You can ❰merge❱ the alternatives of a union using a record with one\n\
        \handler per alternative, like this:                                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────────────────────────────────────┐     \n\
        \    │     let union    = < Left = +2 | Right : Bool >                     │     \n\
        \    │ in  let handlers = { Left = Natural/even, Right = λ(x : Bool) → x } │     \n\
        \    │ in  merge handlers union                                            │     \n\
        \    └─────────────────────────────────────────────────────────────────────┘     \n\
        \                                                                                \n\
        \                                                                                \n\
        \... as long as the output type of each handler function is the same:            \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────────────────────────────────┐               \n\
        \    │ handlers : { Left : Natural → Bool, Right : Bool → Bool } │               \n\
        \    └───────────────────────────────────────────────────────────┘               \n\
        \                                    ⇧                    ⇧                      \n\
        \                                These output types both match                   \n\
        \                                                                                \n\
        \                                                                                \n\
        \For example, the following expression is " <> _NOT <> " valid:                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────────────────┐                         \n\
        \    │     let union    = < Left = +2 | Right : Bool > │                         \n\
        \    │ in  let handlers =                              │                         \n\
        \    │              { Left  = λ(x : Natural) → x       │  This outputs ❰Natural❱ \n\
        \    │              , Right = λ(x : Bool   ) → x       │  This outputs ❰Bool❱    \n\
        \    │              }                                  │                         \n\
        \    │ in  merge handlers union                        │                         \n\
        \    └─────────────────────────────────────────────────┘                         \n\
        \                ⇧                                                               \n\
        \                Invalid: The handlers in this record don't have matching outputs\n\
        \                                                                                \n\
        \                                                                                \n\
        \The handler for the ❰" <> txt0 <> "❱ alternative has this output type:          \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... but the handler for the ❰" <> txt2 <> "❱ alternative has this output type instead:\n\
        \                                                                                \n\
        \↳ " <> txt3 <> "                                                                \n"
      where
        txt0 = build key0
        txt1 = build expr0
        txt2 = build key1
        txt3 = build expr1

prettyTypeMessage (HandlerNotAFunction k expr0) = ErrorMessages {..}
  where
    short = "Handler is not a function"

    long =
        "Explanation: You can ❰merge❱ the alternatives of a union using a record with one\n\
        \handler per alternative, like this:                                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────────────────────────────────────┐     \n\
        \    │     let union    = < Left = +2 | Right : Bool >                     │     \n\
        \    │ in  let handlers = { Left = Natural/even, Right = λ(x : Bool) → x } │     \n\
        \    │ in  merge handlers union : Bool                                     │     \n\
        \    └─────────────────────────────────────────────────────────────────────┘     \n\
        \                                                                                \n\
        \                                                                                \n\
        \... as long as each handler is a function                                       \n\
        \                                                                                \n\
        \For example, the following expression is " <> _NOT <> " valid:                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────────┐                                 \n\
        \    │ merge { Foo = True } < Foo = 1 > : Bool │                                 \n\
        \    └─────────────────────────────────────────┘                                 \n\
        \                    ⇧                                                           \n\
        \                    Invalid: Not a function                                     \n\
        \                                                                                \n\
        \                                                                                \n\
        \Your handler for this alternative:                                              \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... has the following type:                                                     \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... which is not the type of a function                                         \n"
      where
        txt0 = build k
        txt1 = build expr0

prettyTypeMessage (ConstructorsRequiresAUnionType expr0 expr1) = ErrorMessages {..}
  where
    short = "❰constructors❱ requires a union type"

    long =
        "Explanation: You can only use the ❰constructors❱ keyword on an argument that is \n\
        \a union type literal, like this:                                                \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────────────────────┐                           \n\
        \    │ constructors < Left : Natural, Right : Bool > │                           \n\
        \    └───────────────────────────────────────────────┘                           \n\
        \                                                                                \n\
        \                                                                                \n\
        \... but you cannot use the ❰constructors❱ keyword on any other type of argument.\n\
        \For example, you cannot use a variable argument:                                \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────────────────┐                                            \n\
        \    │ λ(t : Type) → constructors t │  Invalid: ❰t❱ might not be a union type    \n\
        \    └──────────────────────────────┘                                            \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────────────────┐                         \n\
        \    │ let t : Type = < Left : Natural, Right : Bool > │  Invalid: Type-checking \n\
        \    │ in  constructors t                              │  precedes normalization \n\
        \    └─────────────────────────────────────────────────┘                         \n\
        \                                                                                \n\
        \                                                                                \n\
        \However, you can import the union type argument:                                \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────────────┐                                          \n\
        \    │ constructors ./unionType.dhall │ Valid: Import resolution precedes        \n\
        \    └────────────────────────────────┘ type-checking                            \n\
        \                                                                                \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \You tried to supply the following argument:                                     \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... which normalized to:                                                        \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... which is not a union type literal                                           \n"
      where
        txt0 = build expr0
        txt1 = build expr1

prettyTypeMessage (NotARecord k expr0 expr1) = ErrorMessages {..}
  where
    short = "Not a record"

    long =
        "Explanation: You can only access fields on records, like this:                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────┐                                         \n\
        \    │ { foo = True, bar = \"ABC\" }.foo │  This is valid ...                    \n\
        \    └─────────────────────────────────┘                                         \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────────────────┐                               \n\
        \    │ λ(r : { foo : Bool, bar : Text }) → r.foo │  ... and so is this           \n\
        \    └───────────────────────────────────────────┘                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \... but you cannot access fields on non-record expressions                      \n\
        \                                                                                \n\
        \For example, the following expression is " <> _NOT <> " valid:                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────┐                                                                   \n\
        \    │ 1.foo │                                                                   \n\
        \    └───────┘                                                                   \n\
        \      ⇧                                                                         \n\
        \      Invalid: Not a record                                                     \n\
        \                                                                                \n\
        \                                                                                \n\
        \Some common reasons why you might get this error:                               \n\
        \                                                                                \n\
        \● You accidentally try to access a field of a union instead of a record, like   \n\
        \  this:                                                                         \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────┐                                                         \n\
        \    │ < foo : a >.foo │                                                         \n\
        \    └─────────────────┘                                                         \n\
        \      ⇧                                                                         \n\
        \      This is a union, not a record                                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \You tried to access a field named:                                              \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... on the following expression which is not a record:                          \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... but is actually an expression of type:                                      \n\
        \                                                                                \n\
        \↳ " <> txt2 <> "                                                                \n"
      where
        txt0 = build k
        txt1 = build expr0
        txt2 = build expr1

prettyTypeMessage (MissingField k expr0) = ErrorMessages {..}
  where
    short = "Missing record field"

    long =
        "Explanation: You can only access fields on records, like this:                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────┐                                         \n\
        \    │ { foo = True, bar = \"ABC\" }.foo │  This is valid ...                    \n\
        \    └─────────────────────────────────┘                                         \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────────────────┐                               \n\
        \    │ λ(r : { foo : Bool, bar : Text }) → r.foo │  ... and so is this           \n\
        \    └───────────────────────────────────────────┘                               \n\
        \                                                                                \n\
        \                                                                                \n\
        \... but you can only access fields if they are present                          \n\
        \                                                                                \n\
        \For example, the following expression is " <> _NOT <> " valid:                  \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────┐                                         \n\
        \    │ { foo = True, bar = \"ABC\" }.qux │                                       \n\
        \    └─────────────────────────────────┘                                         \n\
        \                                  ⇧                                             \n\
        \                                  Invalid: the record has no ❰qux❱ field        \n\
        \                                                                                \n\
        \You tried to access a field named:                                              \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... but the field is missing because the record only defines the following fields:\n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n"
      where
        txt0 = build k
        txt1 = build expr0

prettyTypeMessage (CantAnd expr0 expr1) =
        buildBooleanOperator "&&" expr0 expr1

prettyTypeMessage (CantOr expr0 expr1) =
        buildBooleanOperator "||" expr0 expr1

prettyTypeMessage (CantEQ expr0 expr1) =
        buildBooleanOperator "==" expr0 expr1

prettyTypeMessage (CantNE expr0 expr1) =
        buildBooleanOperator "/=" expr0 expr1

prettyTypeMessage (CantInterpolate expr0 expr1) = ErrorMessages {..}
  where
    short = "You can only interpolate ❰Text❱"

    long =
        "Explanation: Text interpolation only works on expressions of type ❰Text❱        \n\
        \                                                                                \n\
        \For example, these are all valid uses of string interpolation:                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────┐                                                        \n\
        \    │ \"ABC${\"DEF\"}GHI\" │                                                    \n\
        \    └──────────────────┘                                                        \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────────┐                                              \n\
        \    │ λ(x : Text) → \"ABC${x}GHI\" │                                            \n\
        \    └────────────────────────────┘                                              \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────────────────────────────────────────────────┐       \n\
        \    │ λ(age : Natural) → \"Age: ${Integer/show (Natural/toInteger age)}\" │     \n\
        \    └───────────────────────────────────────────────────────────────────┘       \n\
        \                                                                                \n\
        \                                                                                \n\
        \Some common reasons why you might get this error:                               \n\
        \                                                                                \n\
        \● You might have thought that string interpolation automatically converts the   \n\
        \  interpolated value to a ❰Text❱ representation of that value:                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌──────────────────────────────────┐                                        \n\
        \    │ λ(age : Natural) → \"Age: ${age}\" │                                      \n\
        \    └──────────────────────────────────┘                                        \n\
        \                                  ⇧                                             \n\
        \                                  Invalid: ❰age❱ has type ❰Natural❱             \n\
        \                                                                                \n\
        \                                                                                \n\
        \● You might have forgotten to escape a string interpolation that you wanted     \n\
        \  Dhall to ignore and pass through:                                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────┐                                                          \n\
        \    │ \"echo ${HOME}\" │                                                        \n\
        \    └────────────────┘                                                          \n\
        \             ⇧                                                                  \n\
        \             ❰HOME❱ is not in scope and this might have meant to use ❰\\${HOME}❱\n\
        \                                                                                \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \You interpolated this expression:                                               \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... which does not have type ❰Text❱ but instead has type:                       \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n"
      where
        txt0 = build expr0
        txt1 = build expr1



prettyTypeMessage (CantTextAppend expr0 expr1) = ErrorMessages {..}
  where
    short = "❰++❱ only works on ❰Text❱"

    long =
        "Explanation: The ❰++❱ operator expects two arguments that have type ❰Text❱      \n\
        \                                                                                \n\
        \For example, this is a valid use of ❰++❱:                                       \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────┐                                                          \n\
        \    │ \"ABC\" ++ \"DEF\" │                                                      \n\
        \    └────────────────┘                                                          \n\
        \                                                                                \n\
        \                                                                                \n\
        \Some common reasons why you might get this error:                               \n\
        \                                                                                \n\
        \● You might have thought that ❰++❱ was the operator to combine two lists:       \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────┐                                                  \n\
        \    │ [1, 2, 3] ++ [4, 5, 6] │  Not valid                                       \n\
        \    └────────────────────────┘                                                  \n\
        \                                                                                \n\
        \                                                                                \n\
        \  ... but the list concatenation operator is actually ❰#❱:                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────┐                                                   \n\
        \    │ [1, 2, 3] # [4, 5, 6] │  Valid                                            \n\
        \    └───────────────────────┘                                                   \n\
        \                                                                                \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \You provided this argument:                                                     \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... which does not have type ❰Text❱ but instead has type:                       \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n"
      where
        txt0 = build expr0
        txt1 = build expr1

prettyTypeMessage (CantListAppend expr0 expr1) = ErrorMessages {..}
  where
    short = "❰#❱ only works on ❰List❱s"

    long =
        "Explanation: The ❰#❱ operator expects two arguments that are both ❰List❱s       \n\
        \                                                                                \n\
        \For example, this is a valid use of ❰#❱:                                        \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────────────┐                                                   \n\
        \    │ [1, 2, 3] # [4, 5, 6] │                                                   \n\
        \    └───────────────────────┘                                                   \n\
        \                                                                                \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \You provided this argument:                                                     \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... which is not a ❰List❱ but instead has type:                                 \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n"
      where
        txt0 = build expr0
        txt1 = build expr1

prettyTypeMessage (CantAdd expr0 expr1) =
        buildNaturalOperator "+" expr0 expr1

prettyTypeMessage (CantMultiply expr0 expr1) =
        buildNaturalOperator "*" expr0 expr1

prettyTypeMessage (NoDependentTypes expr0 expr1) = ErrorMessages {..}
  where
    short = "No dependent types"

    long =
        "Explanation: The Dhall programming language does not allow functions from terms \n\
        \to types.  These function types are also known as \"dependent function types\"  \n\
        \because you have a type whose value \"depends\" on the value of a term.         \n\
        \                                                                                \n\
        \For example, this is " <> _NOT <> " a legal function type:                      \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────┐                                                             \n\
        \    │ Bool → Type │                                                             \n\
        \    └─────────────┘                                                             \n\
        \                                                                                \n\
        \                                                                                \n\
        \Similarly, this is " <> _NOT <> " legal code:                                   \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌────────────────────────────────────────────────────┐                      \n\
        \    │ λ(Vector : Natural → Type → Type) → Vector +0 Text │                      \n\
        \    └────────────────────────────────────────────────────┘                      \n\
        \                 ⇧                                                              \n\
        \                 Invalid dependent type                                         \n\
        \                                                                                \n\
        \                                                                                \n\
        \Your function type is invalid because the input has type:                       \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... and the output has kind:                                                    \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n\
        \                                                                                \n\
        \... which makes this a forbidden dependent function type                        \n"
      where
        txt0 = build expr0
        txt1 = build expr1

buildBooleanOperator :: Buildable a => Text -> Expr s a -> Expr s a -> ErrorMessages
buildBooleanOperator operator expr0 expr1 = ErrorMessages {..}
  where
    short = "❰" <> txt2 <> "❱ only works on ❰Bool❱s"

    long =
        "Explanation: The ❰" <> txt2 <> "❱ operator expects two arguments that have type ❰Bool❱\n\
        \                                                                                \n\
        \For example, this is a valid use of ❰" <> txt2 <> "❱:                           \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────────────┐                                                           \n\
        \    │ True " <> txt2 <> " False │                                               \n\
        \    └───────────────┘                                                           \n\
        \                                                                                \n\
        \                                                                                \n\
        \You provided this argument:                                                     \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... which does not have type ❰Bool❱ but instead has type:                       \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n"
      where
        txt0 = build expr0
        txt1 = build expr1

    txt2 = build operator

buildNaturalOperator :: Buildable a => Text -> Expr s a -> Expr s a -> ErrorMessages
buildNaturalOperator operator expr0 expr1 = ErrorMessages {..}
  where
    short = "❰" <> txt2 <> "❱ only works on ❰Natural❱s"

    long =
        "Explanation: The ❰" <> txt2 <> "❱ operator expects two arguments that have type ❰Natural❱\n\
        \                                                                                \n\
        \For example, this is a valid use of ❰" <> txt2 <> "❱:                           \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────┐                                                                 \n\
        \    │ +3 " <> txt2 <> " +5 │                                                    \n\
        \    └─────────┘                                                                 \n\
        \                                                                                \n\
        \                                                                                \n\
        \Some common reasons why you might get this error:                               \n\
        \                                                                                \n\
        \● You might have tried to use an ❰Integer❱, which is " <> _NOT <> " allowed:    \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────────────────────────────────────┐                                 \n\
        \    │ λ(x : Integer) → λ(y : Integer) → x " <> txt2 <> " y │  Not valid         \n\
        \    └─────────────────────────────────────────┘                                 \n\
        \                                                                                \n\
        \                                                                                \n\
        \  You can only use ❰Natural❱ numbers                                            \n\
        \                                                                                \n\
        \                                                                                \n\
        \● You might have mistakenly used an ❰Integer❱ literal, which is " <> _NOT <> " allowed:\n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌───────┐                                                                   \n\
        \    │ 2 " <> txt2 <> " 2 │  Not valid                                           \n\
        \    └───────┘                                                                   \n\
        \                                                                                \n\
        \                                                                                \n\
        \  You need to prefix each literal with a ❰+❱ to transform them into ❰Natural❱   \n\
        \  literals, like this:                                                          \n\
        \                                                                                \n\
        \                                                                                \n\
        \    ┌─────────┐                                                                 \n\
        \    │ +2 " <> txt2 <> " +2 │  Valid                                             \n\
        \    └─────────┘                                                                 \n\
        \                                                                                \n\
        \                                                                                \n\
        \────────────────────────────────────────────────────────────────────────────────\n\
        \                                                                                \n\
        \You provided this argument:                                                     \n\
        \                                                                                \n\
        \↳ " <> txt0 <> "                                                                \n\
        \                                                                                \n\
        \... which does not have type ❰Natural❱ but instead has type:                    \n\
        \                                                                                \n\
        \↳ " <> txt1 <> "                                                                \n"
      where
        txt0 = build expr0
        txt1 = build expr1

    txt2 = build operator

-- | A structured type error that includes context
data TypeError s a = TypeError
    { context     :: Context (Expr s a)
    , current     :: Expr s a
    , typeMessage :: TypeMessage s a
    } deriving (Typeable)

instance (Buildable a, Buildable s) => Show (TypeError s a) where
    show = Text.unpack . Builder.toLazyText . build

instance (Buildable a, Buildable s, Typeable a, Typeable s) => Exception (TypeError s a)

instance (Buildable a, Buildable s) => Buildable (TypeError s a) where
    build (TypeError ctx expr msg)
        =   "\n"
        <>  (   if  Text.null (Builder.toLazyText (buildContext ctx))
                then ""
                else buildContext ctx <> "\n"
            )
        <>  shortTypeMessage msg <> "\n"
        <>  source
      where
        buildKV (key, val) = build key <> " : " <> build val

        buildContext =
                build
            .   Text.unlines
            .   map (Builder.toLazyText . buildKV)
            .   reverse
            .   Dhall.Context.toList

        source = case expr of
            Note s _ -> build s
            _        -> mempty

{-| Newtype used to wrap error messages so that they render with a more
    detailed explanation of what went wrong
-}
newtype DetailedTypeError s a = DetailedTypeError (TypeError s a)
    deriving (Typeable)

instance (Buildable a, Buildable s) => Show (DetailedTypeError s a) where
    show = Text.unpack . Builder.toLazyText . build

instance (Buildable a, Buildable s, Typeable a, Typeable s) => Exception (DetailedTypeError s a)

instance (Buildable a, Buildable s) => Buildable (DetailedTypeError s a) where
    build (DetailedTypeError (TypeError ctx expr msg))
        =   "\n"
        <>  (   if  Text.null (Builder.toLazyText (buildContext ctx))
                then ""
                else buildContext ctx <> "\n"
            )
        <>  longTypeMessage msg <> "\n"
        <>  "────────────────────────────────────────────────────────────────────────────────\n"
        <>  "\n"
        <>  source
      where
        buildKV (key, val) = build key <> " : " <> build val

        buildContext =
                build
            .   Text.unlines
            .   map (Builder.toLazyText . buildKV)
            .   reverse
            .   Dhall.Context.toList

        source = case expr of
            Note s _ -> build s
            _        -> mempty

{-| This function verifies that a custom context is well-formed so that
    type-checking will not loop

    Note that `typeWith` already calls `checkContext` for you on the `Context`
    that you supply
-}
checkContext :: Context (Expr s X) -> Either (TypeError s X) ()
checkContext context =
    case Dhall.Context.match context of
        Nothing -> do
            return ()
        Just (x, v, context') -> do
            let shiftedV       =       Dhall.Core.shift (-1) (V x 0)  v
            let shiftedContext = fmap (Dhall.Core.shift (-1) (V x 0)) context'
            _ <- typeWith shiftedContext shiftedV
            return ()
