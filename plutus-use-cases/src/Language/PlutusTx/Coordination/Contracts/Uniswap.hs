{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}

-- | A decentralized exchange for arbitrary token pairs following the
-- [Uniswap protocol](https://uniswap.org/whitepaper.pdf).
--
module Language.PlutusTx.Coordination.Contracts.Uniswap
    ( Coin (..)
    , coin, coinValueOf
    , CreateParams (..)
    , SwapParams (..)
    , CloseParams (..)
    , RemoveParams (..)
    , AddParams (..)
    , UniswapSchema
    , endpoints
    ) where

import           Control.Monad                                     hiding (fmap)
import qualified Data.Map                                          as Map
import           Data.Text                                         (Text, pack)
import           Language.Plutus.Contract                          hiding (when)
import qualified Language.PlutusTx                                 as PlutusTx
import qualified Language.PlutusTx.Coordination.Contracts.Currency as Currency
import           Language.PlutusTx.Prelude                         hiding (unless, Semigroup (..))
import           Ledger                                            hiding (singleton)
import           Ledger.AddressMap
import           Ledger.Constraints                                as Constraints
import           Ledger.Constraints.OnChain                        as Constraints
import           Ledger.Constraints.TxConstraints                  as Constraints
import qualified Ledger.Scripts                                    as Scripts
import qualified Ledger.Typed.Scripts                              as Scripts
import           Ledger.Value                                      as Value
import           Playground.Contract
import           Prelude                                           (Semigroup (..))
import           Text.Printf                                       (printf)

feeNum, feeDen :: Integer
feeNum = 3
feeDen = 1000

uniswapTokenName, poolStateTokenName :: TokenName
uniswapTokenName = "Uniswap"
poolStateTokenName = "Pool State"

-- | A pair consisting of a 'CurrencySymbol' and a 'TokenName'.
-- Coins are the entities that can be swapped in the exchange.
data Coin = Coin
    { cCurrency :: CurrencySymbol
    , cToken    :: TokenName
    } deriving (Show, Generic, ToJSON, FromJSON, ToSchema)

PlutusTx.unstableMakeIsData ''Coin
PlutusTx.makeLift ''Coin

instance Eq Coin where
    {-# INLINABLE (==) #-}
    c == d = cCurrency c == cCurrency d && cToken c == cToken d

{-# INLINABLE compareCoins #-}
compareCoins :: Coin -> Coin -> Ordering
compareCoins c d = case compare (cCurrency c) (cCurrency d) of
    LT -> LT
    GT -> GT
    EQ -> compare (cToken c) (cToken d)

{-# INLINABLE coinLT #-}
coinLT :: Coin -> Coin -> Bool
coinLT c d = case compareCoins c d of
    LT -> True
    _  -> False

{-# INLINABLE coin #-}
-- | @'coin' c n@ denotes the value given by @n@ units of @'Coin'@ @c@.
coin :: Coin    -- ^ The 'Coin'.
     -> Integer -- ^ The desired number coins.
     -> Value   -- ^ The 'Value' consisting of the given number of units of the given 'Coin'.
coin Coin{..} = Value.singleton cCurrency cToken

{-# INLINABLE coinValueOf #-}
-- | Calculates how many units of the specified 'Coin' are contained in the
-- given 'Value'.
coinValueOf :: Value   -- ^ The 'Value' to inspect.
            -> Coin    -- ^ The 'Coin' to look for.
            -> Integer -- ^ The number of units of the given 'Coin' contained in the given 'Value'.
coinValueOf v Coin{..} = valueOf v cCurrency cToken

{-# INLINABLE hashCoin #-}
hashCoin :: Coin -> ByteString
hashCoin Coin{..} = sha2_256 $ concatenate (unCurrencySymbol cCurrency) (unTokenName cToken)

data Sqrt =
      Imaginary
    | Exact Integer
    | Irrational Integer
    deriving stock Show

PlutusTx.unstableMakeIsData ''Sqrt
PlutusTx.makeLift ''Sqrt

{-# INLINABLE rsqrt #-}
rsqrt :: Integer -> Integer -> Sqrt
rsqrt n d
    | n * d < 0 = Imaginary
    | n == 0    = Exact 0
    | n == d    = Exact 1
    | n < 0     = rsqrt (negate n) (negate d)
    | otherwise = go 1 $ 1 + divide n d
  where
    go :: Integer -> Integer -> Sqrt
    go l u
        | l * l * d == n = Exact l
        | u == (l + 1)   = Irrational l
        | otherwise      =
              let
                m = divide (l + u) 2
              in
                if m * m * d <= n then go m u
                                  else go l m

{-# INLINABLE isqrt #-}
isqrt :: Integer -> Sqrt
isqrt n = rsqrt n 1

{-# INLINABLE calculateInitialLiquidity #-}
calculateInitialLiquidity :: Integer -> Integer -> Integer
calculateInitialLiquidity outA outB = case isqrt (outA * outB) of
    Exact l
        | l > 0 -> l
    Irrational l
        | l > 0 -> l + 1
    _           -> traceError "insufficient liquidity"

{-# INLINABLE calculateAdditionalLiquidity #-}
calculateAdditionalLiquidity :: Integer -> Integer -> Integer -> Integer -> Integer -> Integer
calculateAdditionalLiquidity oldA oldB liquidity delA delB = case rsqrt (liquidity * liquidity * newProd) oldProd of
    Imaginary    -> traceError "insufficient liquidity"
    Exact x      -> x - liquidity
    Irrational x -> x - liquidity
  where
    oldProd, newProd :: Integer
    oldProd = oldA * oldB
    newProd = (oldA + delA) * (oldB + delB)

{-# INLINABLE calculateRemoval #-}
calculateRemoval :: Integer -> Integer -> Integer -> Integer -> (Integer, Integer)
calculateRemoval inA inB liquidity diff = (f inA, f inB)
  where
    f :: Integer -> Integer
    f x = x - divide (x * diff) liquidity

data LiquidityPool = LiquidityPool
    { lpCoinA  :: Coin
    , lpCoinB  :: Coin
    } deriving (Show, Generic, ToJSON, FromJSON, ToSchema)

PlutusTx.unstableMakeIsData ''LiquidityPool
PlutusTx.makeLift ''LiquidityPool

instance Eq LiquidityPool where
    {-# INLINABLE (==) #-}
    x == y = (lpCoinA x == lpCoinA y && lpCoinB x == lpCoinB y) ||
             (lpCoinA x == lpCoinB y && lpCoinB x == lpCoinA y)

{-# INLINABLE hashLiquidityPool #-}
hashLiquidityPool :: LiquidityPool -> ByteString
hashLiquidityPool LiquidityPool{..} = sha2_256 $ concatenate (hashCoin c) (hashCoin d)
  where
    (c, d)
        | lpCoinA `coinLT` lpCoinB = (lpCoinA, lpCoinB)
        | otherwise                = (lpCoinB, lpCoinA)

newtype Uniswap = Uniswap
    { usCoin :: Coin
    } deriving stock    (Show, Generic)
      deriving anyclass (ToJSON, FromJSON, ToSchema)

PlutusTx.makeLift ''Uniswap

data UniswapAction = Create LiquidityPool | Close | Swap | Remove | Add
    deriving Show

PlutusTx.unstableMakeIsData ''UniswapAction
PlutusTx.makeLift ''UniswapAction

data UniswapDatum =
      Factory [LiquidityPool]
    | Pool LiquidityPool Integer
    deriving stock (Show)

PlutusTx.unstableMakeIsData ''UniswapDatum
PlutusTx.makeLift ''UniswapDatum

data Uniswapping
instance Scripts.ScriptType Uniswapping where
    type instance RedeemerType Uniswapping = UniswapAction
    type instance DatumType Uniswapping = UniswapDatum

{-# INLINABLE checkSwap #-}
checkSwap :: Integer -> Integer -> Integer -> Integer -> Bool
checkSwap oldA oldB newA newB =
    traceIfFalse "expected positive oldA" (oldA > 0) &&
    traceIfFalse "expected positive oldB" (oldB > 0) &&
    traceIfFalse "expected positive-newA" (newA > 0) &&
    traceIfFalse "expected positive-newB" (newB > 0) &&
    traceIfFalse "expected product to increase"
        ((((newA * feeDen) - (inA * feeNum)) * ((newB * feeDen) - (inB * feeNum)))
         >= (feeDen * feeDen * oldA * oldB))
  where
    inA, inB :: Integer
    inA = max 0 $ newA - oldA
    inB = max 0 $ newB - oldB

-- (newA - fee * inA) * (newB - fee * inB) >= oldA * oldB
-- (newA * feeDen - inA + feeNum) * (newB * feeDen - inB * feeNum)
--     >= feeDen ^ 2 * oldA * oldB

{-# INLINABLE validateSwap #-}
validateSwap :: LiquidityPool -> Coin -> ValidatorCtx -> Bool
validateSwap LiquidityPool{..} c ctx =
    checkSwap oldA oldB newA newB                                                                &&
    traceIfFalse "expected pool state token to be present in input" (coinValueOf inVal c == 1)   &&
    traceIfFalse "expected pool state token to be present in output" (coinValueOf outVal c == 1) &&
    traceIfFalse "did not expect Uniswap forging" noUniswapForging
  where
    info :: TxInfo
    info = valCtxTxInfo ctx

    ownInput :: TxInInfo
    ownInput = findOwnInput ctx

    ownOutput :: TxOutInfo
    ownOutput = case [ o
                     | o <- getContinuingOutputs ctx
                     , txOutType o == PayToScript ownInDatumHash
                     ] of
        [o] -> o
        _   -> traceError "expected exactly one output to the same liquidity pool"

    ownInDatumHash :: DatumHash
    ownInDatumHash = let (_, _, h) = ownHashes ctx in h

    oldA, oldB, newA, newB :: Integer
    oldA = amountA inVal
    oldB = amountB inVal
    newA = amountA outVal
    newB = amountB outVal

    amountA, amountB :: Value -> Integer
    amountA v = coinValueOf v lpCoinA
    amountB v = coinValueOf v lpCoinB

    inVal, outVal :: Value
    inVal   = txInInfoValue ownInput
    outVal  = txOutValue ownOutput

    noUniswapForging :: Bool
    noUniswapForging =
      let
        Coin cs _ = c
        forged    = txInfoForge info
      in
        all (/= cs) $ symbols forged

{-# INLINABLE validateCreate #-}
validateCreate :: Uniswap
               -> Coin
               -> [LiquidityPool]
               -> LiquidityPool
               -> ValidatorCtx
               -> Bool
validateCreate Uniswap{..} c lps lp@LiquidityPool{..} ctx =
    traceIfFalse "Uniswap coin not present" (coinValueOf (txInInfoValue $ findOwnInput ctx) usCoin == 1) &&
    (lpCoinA /= lpCoinB)                                                                                 &&
    all (/= lp) lps                                                                                      &&
    Constraints.checkOwnOutputConstraint ctx (OutputConstraint (Factory $ lp : lps) $ coin usCoin 1)     &&
    (coinValueOf forged c == 1)                                                                          &&
    (coinValueOf forged liquidityCoin == liquidity)                                                      &&
    (outA > 0)                                                                                           &&
    (outB > 0)                                                                                           &&
    Constraints.checkOwnOutputConstraint ctx (OutputConstraint (Pool lp liquidity) $
        coin lpCoinA outA <> coin lpCoinB outB <> coin c 1)
  where
    poolOutput :: TxOutInfo
    poolOutput = case [o | o <- getContinuingOutputs ctx, coinValueOf (txOutValue o) c == 1] of
        [o] -> o
        _   -> traceError "expected exactly one pool output"

    outA, outB, liquidity :: Integer
    outA      = coinValueOf (txOutValue poolOutput) lpCoinA
    outB      = coinValueOf (txOutValue poolOutput) lpCoinB
    liquidity = calculateInitialLiquidity outA outB

    forged :: Value
    forged = txInfoForge $ valCtxTxInfo ctx

    liquidityCoin :: Coin
    liquidityCoin = let Coin cs _ = c in Coin cs $ lpTicker lp

{-# INLINABLE validateCloseFactory #-}
validateCloseFactory :: Uniswap -> Coin -> [LiquidityPool] -> ValidatorCtx -> Bool
validateCloseFactory us c lps ctx =
    traceIfFalse "Uniswap coin not present" (coinValueOf (txInInfoValue $ findOwnInput ctx) usC == 1)             &&
    traceIfFalse "wrong forge value"        (txInfoForge info == negate (coin c 1 <>  coin lC (snd lpLiquidity))) &&
    traceIfFalse "factory output wrong"
        (Constraints.checkOwnOutputConstraint ctx $ OutputConstraint (Factory $ filter (/= fst lpLiquidity) lps) $ coin usC 1)
  where
    info :: TxInfo
    info = valCtxTxInfo ctx

    poolInput :: TxInInfo
    poolInput = case [ i
                     | i <- txInfoInputs info
                     , coinValueOf (txInInfoValue i) c == 1
                     ] of
        [i] -> i
        _   -> traceError "expected exactly one pool input"

    lpLiquidity :: (LiquidityPool, Integer)
    lpLiquidity = case txInInfoWitness poolInput of
        Nothing        -> traceError "pool input witness missing"
        Just (_, _, h) -> findPoolDatum info h

    lC, usC :: Coin
    lC  = Coin (cCurrency c) (lpTicker $ fst lpLiquidity)
    usC = usCoin us

{-# INLINABLE validateClosePool #-}
validateClosePool :: Uniswap -> ValidatorCtx -> Bool
validateClosePool us ctx = hasFactoryInput
  where
    info :: TxInfo
    info = valCtxTxInfo ctx

    hasFactoryInput :: Bool
    hasFactoryInput =
        traceIfFalse "Uniswap factory input expected" $
        coinValueOf (valueSpent info) (usCoin us) == 1

{-# INLINABLE validateRemove #-}
validateRemove :: Coin -> LiquidityPool -> Integer -> ValidatorCtx -> Bool
validateRemove c lp liquidity ctx =
    traceIfFalse "zero removal"                        (diff > 0)                                  &&
    traceIfFalse "removal of too much liquidity"       (diff < liquidity)                          &&
    traceIfFalse "pool state coin missing"             (coinValueOf inVal c == 1)                  &&
    traceIfFalse "wrong liquidity pool output"         (fst lpLiquidity == lp)                     &&
    traceIfFalse "pool state coin missing from output" (coinValueOf outVal c == 1)                 &&
    traceIfFalse "liquidity tokens not burnt"          (txInfoForge info == negate (coin lC diff)) &&
    traceIfFalse "non-positive liquidity"              (outA > 0 && outB > 0)
  where
    info :: TxInfo
    info = valCtxTxInfo ctx

    ownInput :: TxInInfo
    ownInput = findOwnInput ctx

    output :: TxOut
    output = case getContinuingOutputs ctx of
        [o] -> o
        _   -> traceError "expected exactly one Uniswap output"

    inVal, outVal :: Value
    inVal  = txInInfoValue ownInput
    outVal = txOutValue output

    lpLiquidity :: (LiquidityPool, Integer)
    lpLiquidity = case txOutType output of
        PayToPubKey   -> traceError "pool output witness missing"
        PayToScript h -> findPoolDatum info h

    lC :: Coin
    lC = Coin (cCurrency c) (lpTicker lp)

    diff, inA, inB, outA, outB :: Integer
    diff         = liquidity - snd lpLiquidity
    inA          = coinValueOf inVal $ lpCoinA lp
    inB          = coinValueOf inVal $ lpCoinB lp
    (outA, outB) = calculateRemoval inA inB liquidity diff

{-# INLINABLE validateAdd #-}
validateAdd :: Coin -> LiquidityPool -> Integer -> ValidatorCtx -> Bool
validateAdd c lp liquidity ctx =
    traceIfFalse "pool stake token missing from input"          (coinValueOf inVal c == 1)                                           &&
    traceIfFalse "output pool for same liquidity pair expected" (lp == fst outDatum)                                                 &&
    traceIfFalse "must not remove tokens"                       (delA >= 0 && delB >= 0)                                             &&
    traceIfFalse "insufficient liquidity"                       (delL >= 0)                                                          &&
    traceIfFalse "wrong amount of liquidity tokens"             (delL == calculateAdditionalLiquidity oldA oldB liquidity delA delB) &&
    traceIfFalse "wrong amount of liquidity tokens forged"      (txInfoForge info == coin lC delL)
  where
    info :: TxInfo
    info = valCtxTxInfo ctx

    ownInput :: TxInInfo
    ownInput = findOwnInput ctx

    ownOutput :: TxOut
    ownOutput = case [ o
                     | o <- getContinuingOutputs ctx
                     , coinValueOf (txOutValue o) c == 1
                     ] of
        [o] -> o
        _   -> traceError "expected exactly on pool output"

    outDatum :: (LiquidityPool, Integer)
    outDatum = case txOutDatum ownOutput of
        Nothing -> traceError "pool output datum hash not found"
        Just h  -> findPoolDatum info h

    inVal, outVal :: Value
    inVal  = txInInfoValue ownInput
    outVal = txOutValue ownOutput

    oldA, oldB, delA, delB, delL :: Integer
    oldA = coinValueOf inVal aC
    oldB = coinValueOf inVal bC
    delA = coinValueOf outVal aC - oldA
    delB = coinValueOf outVal bC - oldB
    delL = snd outDatum - liquidity

    aC, bC, lC :: Coin
    aC = lpCoinA lp
    bC = lpCoinB lp
    lC = let Coin cs _ = c in Coin cs $ lpTicker lp

{-# INLINABLE findPoolDatum #-}
findPoolDatum :: TxInfo -> DatumHash -> (LiquidityPool, Integer)
findPoolDatum info h = case findDatum h info of
    Just (Datum d) -> case PlutusTx.fromData d of
        Just (Pool lp a) -> (lp, a)
        _                -> traceError "error decoding data"
    _              -> traceError "pool input datum not found"

{-# INLINABLE lpTicker #-}
lpTicker :: LiquidityPool -> TokenName
--lpTicker = TokenName . hashLiquidityPool
lpTicker LiquidityPool{..} = TokenName $
    unCurrencySymbol (cCurrency c) `concatenate`
    unCurrencySymbol (cCurrency d) `concatenate`
    unTokenName      (cToken    c) `concatenate`
    unTokenName      (cToken    d)
  where
    (c, d)
        | lpCoinA `coinLT` lpCoinB = (lpCoinA, lpCoinB)
        | otherwise                = (lpCoinB, lpCoinA)

mkUniswapValidator :: Uniswap
                   -> Coin
                   -> UniswapDatum
                   -> UniswapAction
                   -> ValidatorCtx
                   -> Bool
mkUniswapValidator us c (Factory lps) (Create lp) ctx = validateCreate us c lps lp ctx
mkUniswapValidator _  c (Pool lp _)   Swap        ctx = validateSwap lp c ctx
mkUniswapValidator us c (Factory lps) Close       ctx = validateCloseFactory us c lps ctx
mkUniswapValidator us _ (Pool _  _)   Close       ctx = validateClosePool us ctx
mkUniswapValidator _  c (Pool lp a)   Remove      ctx = validateRemove c lp a ctx
mkUniswapValidator _  c (Pool lp a)   Add         ctx = validateAdd c lp a ctx
mkUniswapValidator _  _ _             _           _   = False

validateLiquidityForging :: Uniswap -> TokenName -> PolicyCtx -> Bool
validateLiquidityForging us tn ctx = case [ i
                                          | i <- txInfoInputs $ policyCtxTxInfo ctx
                                          , let v = txInInfoValue i
                                          , (coinValueOf v usC == 1) ||
                                            (coinValueOf v lpC == 1)
                                          ] of
    [_]    -> True
    [_, _] -> True
    _      -> traceError "pool state forging without Uniswap input"
  where
    usC, lpC :: Coin
    usC = usCoin us
    lpC = Coin (ownCurrencySymbol ctx) tn

uniswapInstance :: Uniswap -> Scripts.ScriptInstance Uniswapping
uniswapInstance us = Scripts.validator @Uniswapping
    ($$(PlutusTx.compile [|| mkUniswapValidator ||])
        `PlutusTx.applyCode` PlutusTx.liftCode us
        `PlutusTx.applyCode` PlutusTx.liftCode c)
     $$(PlutusTx.compile [|| wrap ||])
  where
    c :: Coin
    c = poolStateCoin us

    wrap = Scripts.wrapValidator @UniswapDatum @UniswapAction

uniswapScript :: Uniswap -> Validator
uniswapScript = Scripts.validatorScript . uniswapInstance

uniswapHash :: Uniswap -> Ledger.ValidatorHash
uniswapHash = Scripts.validatorHash . uniswapScript

uniswapAddress :: Uniswap -> Ledger.Address
uniswapAddress = ScriptAddress . uniswapHash

uniswap :: CurrencySymbol -> Uniswap
uniswap cs = Uniswap $ Coin cs uniswapTokenName

liquidityPolicy :: Uniswap -> MonetaryPolicy
liquidityPolicy us = mkMonetaryPolicyScript $
    $$(PlutusTx.compile [|| \u t -> Scripts.wrapMonetaryPolicy (validateLiquidityForging u t) ||])
        `PlutusTx.applyCode` PlutusTx.liftCode us
        `PlutusTx.applyCode` PlutusTx.liftCode poolStateTokenName

liquidityCurrency :: Uniswap -> CurrencySymbol
liquidityCurrency = scriptCurrencySymbol . liquidityPolicy

poolStateCoin :: Uniswap -> Coin
poolStateCoin = flip Coin poolStateTokenName . liquidityCurrency

-- | Paraneters for the @create@-endpoint, which creates a new liquidity pool.
data CreateParams = CreateParams
    { cpUniswap :: CurrencySymbol -- ^ Currency used for the Uniswap factory token, the Uniswap liquidity pool tokens and the liquidity tokens.
    , cpCoinA   :: Coin
    , cpCoinB   :: Coin
    , cpAmountA :: Integer
    , cpAmountB :: Integer
    } deriving (Generic, ToJSON, FromJSON, ToSchema)

-- | Parameters for the @swap@-endpoint, which allows swaps between the two different coins in a liquidity pool.
-- One of the provided amounts must be positive, the other must be zero.
data SwapParams = SwapParams
    { spUniswap :: CurrencySymbol -- ^ Currency used for the Uniswap factory token, the Uniswap liquidity pool tokens and the liquidity tokens.
    , spCoinA   :: Coin           -- ^ One 'Coin' of the liquidity pair.
    , spCoinB   :: Coin           -- ^ The other 'Coin'.
    , spAmountA :: Integer        -- ^ The amount the first 'Coin' that should be swapped.
    , spAmountB :: Integer        -- ^ The amount of the second 'Coin' that should be swapped.
    } deriving (Generic, ToJSON, FromJSON, ToSchema)

-- | Parameters for the @close@-endpoint, which closes a liquidity pool.
data CloseParams = CloseParams
    { clpUniswap :: CurrencySymbol -- ^ Currency used for the Uniswap factory token, the Uniswap liquidity pool tokens and the liquidity tokens.
    , clpCoinA   :: Coin           -- ^ One 'Coin' of the liquidity pair.
    , clpCoinB   :: Coin           -- ^ The other 'Coin' of the liquidity pair.
    } deriving (Generic, ToJSON, FromJSON, ToSchema)

-- | Parameters for the @remove@-endpoint, which removes some liquidity from a liquidity pool.
data RemoveParams = RemoveParams
    { rpUniswap :: CurrencySymbol -- ^ Currency used for the Uniswap factory token, the Uniswap liquidity pool tokens and the liquidity tokens.
    , rpCoinA   :: Coin           -- ^ One 'Coin' of the liquidity pair.
    , rpCoinB   :: Coin           -- ^ The other 'Coin' of the liquidity pair.
    , rpDiff    :: Integer        -- ^ The amount of liquidity tokens to burn in exchange for liquidity from the pool.
    } deriving (Generic, ToJSON, FromJSON, ToSchema)

-- | Parameters for the @add@-endpoint, which adds liquidity to a liquidity pool in exchange for liquidity tokens.
data AddParams = AddParams
    { apUniswap :: CurrencySymbol -- ^ Currency used for the Uniswap factory token, the Uniswap liquidity pool tokens and the liquidity tokens.
    , apCoinA   :: Coin           -- ^ One 'Coin' of the liquidity pair.
    , apCoinB   :: Coin           -- ^ The other 'Coin' of the liquidity pair.
    , apAmountA :: Integer        -- ^ The amount of coins of the first kind to add to the pool.
    , apAmountB :: Integer        -- ^ The amount of coins of the second kind to add to the pool.
    } deriving (Generic, ToJSON, FromJSON, ToSchema)

-- | Schema for the 'endpoints'.
type UniswapSchema =
    BlockchainActions
        .\/ Endpoint "start"  ()
        .\/ Endpoint "create" CreateParams
        .\/ Endpoint "swap"   SwapParams
        .\/ Endpoint "close"  CloseParams
        .\/ Endpoint "remove" RemoveParams
        .\/ Endpoint "add"    AddParams

start :: Contract () UniswapSchema Text ()
start = do
    ()  <- endpoint @"start"
    pkh <- pubKeyHash <$> ownPubKey
    cs  <- fmap Currency.currencySymbol $
           mapError (pack . show @Currency.CurrencyError) $
           Currency.forgeContract pkh [(uniswapTokenName, 1)]
    let c    = Coin cs uniswapTokenName
        us   = uniswap cs
        inst = uniswapInstance us
        tx   = mustPayToTheScript (Factory []) $ coin c 1
    ledgerTx <- submitTxConstraints inst tx
    void $ awaitTxConfirmed $ txId ledgerTx

    logInfo @String $ printf "started Uniswap %s at address %s" (show us) (show $ uniswapAddress us)

create :: Contract () UniswapSchema Text ()
create = do
    CreateParams{..} <- endpoint @"create"
    when (cpCoinA == cpCoinB)               $ throwError "coins must be different"
    when (cpAmountA <= 0 || cpAmountB <= 0) $ throwError "amounts must be positive"
    let us = uniswap cpUniswap
    (oref, o, lps) <- findUniswapFactory us
    let liquidity = calculateInitialLiquidity cpAmountA cpAmountB
        lp        = LiquidityPool {lpCoinA = cpCoinA, lpCoinB = cpCoinB}
    let usInst   = uniswapInstance us
        usScript = uniswapScript us
        usDat1   = Factory $ lp : lps
        usDat2   = Pool lp liquidity
        psC      = poolStateCoin us
        lC       = Coin (liquidityCurrency us) $ lpTicker lp
        usVal    = coin (usCoin us) 1
        lpVal    = coin cpCoinA cpAmountA <> coin cpCoinB cpAmountB <> coin psC 1

        lookups  = Constraints.scriptInstanceLookups usInst        <>
                   Constraints.otherScript usScript                <>
                   Constraints.monetaryPolicy (liquidityPolicy us) <>
                   Constraints.unspentOutputs (Map.singleton oref o)

        tx       = Constraints.mustPayToTheScript usDat1 usVal                                               <>
                   Constraints.mustPayToTheScript usDat2 lpVal                                               <>
                   Constraints.mustForgeValue (coin psC 1 <> coin lC liquidity)                              <>
                   Constraints.mustSpendScriptOutput oref (Redeemer $ PlutusTx.toData $ Create lp)

    ledgerTx <- submitTxConstraintsWith lookups tx
    void $ awaitTxConfirmed $ txId ledgerTx

    logInfo $ "created liquidity pool: " ++ show lp

close :: Contract () UniswapSchema Text ()
close = do
    CloseParams{..} <- endpoint @"close"
    let us = uniswap clpUniswap
    ((oref1, o1, lps), (oref2, o2, lp, liquidity)) <- findUniswapFactoryAndPool us clpCoinA clpCoinB
    pkh                                            <- pubKeyHash <$> ownPubKey
    let usInst   = uniswapInstance us
        usScript = uniswapScript us
        usDat    = Factory $ filter (/= lp) lps
        usC      = usCoin us
        psC      = poolStateCoin us
        lC       = Coin (liquidityCurrency us) $ lpTicker lp
        usVal    = coin usC 1
        psVal    = coin psC 1
        lVal     = coin lC liquidity
        redeemer = Redeemer $ PlutusTx.toData Close

        lookups  = Constraints.scriptInstanceLookups usInst        <>
                   Constraints.otherScript usScript                <>
                   Constraints.monetaryPolicy (liquidityPolicy us) <>
                   Constraints.ownPubKeyHash pkh                   <>
                   Constraints.unspentOutputs (Map.singleton oref1 o1 <> Map.singleton oref2 o2)

        tx       = Constraints.mustPayToTheScript usDat usVal          <>
                   Constraints.mustForgeValue (negate $ psVal <> lVal) <>
                   Constraints.mustSpendScriptOutput oref1 redeemer    <>
                   Constraints.mustSpendScriptOutput oref2 redeemer    <>
                   Constraints.mustIncludeDatum (Datum $ PlutusTx.toData $ Pool lp liquidity)

    ledgerTx <- submitTxConstraintsWith lookups tx
    void $ awaitTxConfirmed $ txId ledgerTx

    logInfo $ "closed liquidity pool: " ++ show lp

remove :: Contract () UniswapSchema Text ()
remove = do
    RemoveParams{..} <- endpoint @"remove"
    let us = uniswap rpUniswap
    (_, (oref, o, lp, liquidity)) <- findUniswapFactoryAndPool us rpCoinA rpCoinB
    pkh                           <- pubKeyHash <$> ownPubKey
    when (rpDiff < 1 || rpDiff >= liquidity) $ throwError "removed liquidity must be positive and less than total liquidity"
    let usInst       = uniswapInstance us
        usScript     = uniswapScript us
        dat          = Pool lp $ liquidity - rpDiff
        psC          = poolStateCoin us
        lC           = Coin (liquidityCurrency us) $ lpTicker lp
        psVal        = coin psC 1
        lVal         = coin lC rpDiff
        inVal        = txOutValue $ txOutTxOut o
        inA          = coinValueOf inVal rpCoinA
        inB          = coinValueOf inVal rpCoinB
        (outA, outB) = calculateRemoval inA inB liquidity rpDiff
        val          = psVal <> coin rpCoinA outA <> coin rpCoinB outB
        redeemer     = Redeemer $ PlutusTx.toData Remove

        lookups  = Constraints.scriptInstanceLookups usInst          <>
                   Constraints.otherScript usScript                  <>
                   Constraints.monetaryPolicy (liquidityPolicy us)   <>
                   Constraints.unspentOutputs (Map.singleton oref o) <>
                   Constraints.ownPubKeyHash pkh

        tx       = Constraints.mustPayToTheScript dat val          <>
                   Constraints.mustForgeValue (negate lVal)        <>
                   Constraints.mustSpendScriptOutput oref redeemer

    ledgerTx <- submitTxConstraintsWith lookups tx
    void $ awaitTxConfirmed $ txId ledgerTx

    logInfo $ "removed liquidity from pool: " ++ show lp

add :: Contract () UniswapSchema Text ()
add = do
    AddParams{..} <- endpoint @"add"
    let us = uniswap apUniswap
    pkh                           <- pubKeyHash <$> ownPubKey
    (_, (oref, o, lp, liquidity)) <- findUniswapFactoryAndPool us apCoinA apCoinB
    when (apAmountA < 0 || apAmountB < 0) $ throwError "amounts must not be negative"
    let outVal = txOutValue $ txOutTxOut o
        oldA   = coinValueOf outVal apCoinA
        oldB   = coinValueOf outVal apCoinB
        newA   = oldA + apAmountA
        newB   = oldB + apAmountB
        delL   = calculateAdditionalLiquidity oldA oldB liquidity apAmountA apAmountB
        inVal  = coin apCoinA apAmountA <> coin apCoinB apAmountB
    when (delL <= 0) $ throwError "insufficient liquidity"
    logInfo @String $ printf "oldA = %d, oldB = %d, newA = %d, newB = %d, delL = %d" oldA oldB newA newB delL

    let usInst       = uniswapInstance us
        usScript     = uniswapScript us
        dat          = Pool lp $ liquidity + delL
        psC          = poolStateCoin us
        lC           = Coin (liquidityCurrency us) $ lpTicker lp
        psVal        = coin psC 1
        lVal         = coin lC delL
        val          = psVal <> coin apCoinA newA <> coin apCoinB newB
        redeemer     = Redeemer $ PlutusTx.toData Add

        lookups  = Constraints.scriptInstanceLookups usInst             <>
                   Constraints.otherScript usScript                     <>
                   Constraints.monetaryPolicy (liquidityPolicy us)      <>
                   Constraints.ownPubKeyHash pkh                        <>
                   Constraints.unspentOutputs (Map.singleton oref o)

        tx       = Constraints.mustPayToTheScript dat val          <>
                   Constraints.mustForgeValue lVal                 <>
                   Constraints.mustSpendScriptOutput oref redeemer

    logInfo @String $ printf "val = %s, inVal = %s" (show val) (show inVal)
    logInfo $ show lookups
    logInfo $ show tx

    ledgerTx <- submitTxConstraintsWith lookups tx
    void $ awaitTxConfirmed $ txId ledgerTx

    logInfo $ "added liquidity to pool: " ++ show lp

swap :: Contract () UniswapSchema Text ()
swap = do
    SwapParams{..} <- endpoint @"swap"
    unless (spAmountA > 0 && spAmountB == 0 || spAmountA == 0 && spAmountB > 0) $ throwError "exactly one amount must be positive"
    let us = uniswap spUniswap
    (_, (oref, o, lp, liquidity)) <- findUniswapFactoryAndPool us spCoinA spCoinB
    let outVal = txOutValue $ txOutTxOut o
    let oldA = coinValueOf outVal spCoinA
        oldB = coinValueOf outVal spCoinB
    (newA, newB) <- if spAmountA > 0 then do
        let outB = findSwapA oldA oldB spAmountA
        when (outB == 0) $ throwError "no payout"
        return (oldA + spAmountA, oldB - outB)
                                     else do
        let outA = findSwapB oldA oldB spAmountB
        when (outA == 0) $ throwError "no payout"
        return (oldA - outA, oldB + spAmountB)
    pkh <- pubKeyHash <$> ownPubKey

    logInfo @String $ printf "oldA = %d, oldB = %d, old product = %d, newA = %d, newB = %d, new product = %d" oldA oldB (oldA * oldB) newA newB (newA * newB)

    let inst    = uniswapInstance us
        val     = coin spCoinA newA <> coin spCoinB newB <> coin (poolStateCoin us) 1

        lookups = Constraints.scriptInstanceLookups inst                 <>
                  Constraints.otherScript (Scripts.validatorScript inst) <>
                  Constraints.unspentOutputs (Map.singleton oref o)      <>
                  Constraints.ownPubKeyHash pkh

        tx      = mustSpendScriptOutput oref (Redeemer $ PlutusTx.toData Swap) <>
                  Constraints.mustPayToTheScript (Pool lp liquidity) val

    logInfo $ show tx
    ledgerTx <- submitTxConstraintsWith lookups tx
    logInfo $ show ledgerTx
    void $ awaitTxConfirmed $ txId ledgerTx

    logInfo $ "swapped with: " ++ show lp

findUniswapInstance :: Uniswap -> Coin -> (UniswapDatum -> Maybe a) -> Contract w UniswapSchema Text (TxOutRef, TxOutTx, a)
findUniswapInstance us c f = do
    let addr = uniswapAddress us
    logInfo @String $ printf "looking for Uniswap instance at address %s containing coin %s " (show addr) (show c)
    utxos <- utxoAt addr
    go  [x | x@(_, o) <- Map.toList utxos, coinValueOf (txOutValue $ txOutTxOut o) c == 1]
  where
    go [] = throwError "Uniswap instance not found"
    go ((oref, o) : xs) = case txOutType $ txOutTxOut o of
        PayToPubKey   -> throwError "unexpected out type"
        PayToScript h -> case Map.lookup h $ txData $ txOutTxTx o of
            Nothing -> throwError "datum not found"
            Just (Datum e) -> case PlutusTx.fromData e of
                Nothing -> throwError "datum has wrong type"
                Just d  -> case f d of
                    Nothing -> go xs
                    Just a  -> do
                        logInfo @String $ printf "found Uniswap instance with datum: %s" (show d)
                        return (oref, o, a)

findUniswapFactory :: Uniswap -> Contract w UniswapSchema Text (TxOutRef, TxOutTx, [LiquidityPool])
findUniswapFactory us@Uniswap{..} = findUniswapInstance us usCoin $ \case
    Factory lps -> Just lps
    Pool _ _    -> Nothing

findUniswapPool :: Uniswap -> LiquidityPool -> Contract w UniswapSchema Text (TxOutRef, TxOutTx, Integer)
findUniswapPool us lp = findUniswapInstance us (poolStateCoin us) $ \case
        Pool lp' l
            | lp == lp' -> Just l
        _               -> Nothing

findUniswapFactoryAndPool :: Uniswap
                          -> Coin
                          -> Coin
                          -> Contract w UniswapSchema Text ( (TxOutRef, TxOutTx, [LiquidityPool])
                                                         , (TxOutRef, TxOutTx, LiquidityPool, Integer)
                                                         )
findUniswapFactoryAndPool us coinA coinB = do
    (oref1, o1, lps) <- findUniswapFactory us
    case [ lp'
         | lp' <- lps
         , lp' == LiquidityPool coinA coinB
         ] of
        [lp] -> do
            (oref2, o2, a) <- findUniswapPool us lp
            return ( (oref1, o1, lps)
                   , (oref2, o2, lp, a)
                   )
        _    -> throwError "liquidity pool not found"

findSwapA :: Integer -> Integer -> Integer -> Integer
findSwapA oldA oldB inA
    | ub' <= 1   = 0
    | otherwise  = go 1 ub'
  where
    cs :: Integer -> Bool
    cs outB = checkSwap oldA oldB (oldA + inA) (oldB - outB)

    ub' :: Integer
    ub' = head $ dropWhile cs [2 ^ i | i <- [0 :: Int ..]]

    go :: Integer -> Integer -> Integer
    go lb ub
        | ub == (lb + 1) = lb
        | otherwise      =
      let
        m = div (ub + lb) 2
      in
        if cs m then go m ub else go lb m

findSwapB :: Integer -> Integer -> Integer -> Integer
findSwapB oldA oldB = findSwapA oldB oldA

findValue :: Value -> Contract w UniswapSchema Text UtxoMap
findValue v = do
    pkh   <- pubKeyHash <$> ownPubKey
    utxos <- utxoAt $ PubKeyAddress pkh
    go Map.empty v $ Map.toList utxos
  where
    go :: UtxoMap -> Value -> [(TxOutRef, TxOutTx)] -> Contract w UniswapSchema Text UtxoMap
    go acc w _
        | Value.leq w mempty  = return acc
    go _   w []               = throwError $ pack $ "insufficient funds: need " ++ show v ++ ", have " ++ show (v <> negate w)
    go acc w ((oref, o) : xs) = go (Map.insert oref o acc) (w <> negate (txOutValue $ txOutTxOut o)) xs

-- | Provides the following endpoints:
--
--      [@start@]: Creates a Uniswap "factory".
--          This factory will keep track of the existing liquidity pools and enforce that there will be at most one liquidity pool
--          for any pair of tokens at any given time.
--      [@create@]: Create a liquidity pool for a pair of coins. The creator provides liquidity for both coins and gets liquidity tokens in return.
--      [@swap@]: Use a liquidity pool two swap one sort of coins in the pool against the other.
--      [@close@]: Close a liquidity pool by burning all remaining liquidity tokens in exchange for all liquidity remaining in the pool.
--      [@remove@]: Removes some liquidity from a liquidity pool in exchange for liquidity tokens.
--      [@add@]: Adds some liquidity to an existing liquidity pool in exchange for newly minted liquidity tokens.
endpoints :: Contract () UniswapSchema Text ()
endpoints = (start `select` create `select` swap `select` close `select` remove `select` add) >> endpoints