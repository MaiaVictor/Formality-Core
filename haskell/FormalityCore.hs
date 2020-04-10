{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DerivingVia #-}
module FormalityCore where

import           Data.List           hiding (all, find, union)
import qualified Data.Map.Strict     as M
import           Data.Maybe
import           Data.Foldable       hiding (all, find)
import           Data.Bits           ((.&.), xor, shiftR, shiftL, Bits)
import           Data.Word
import           Data.Char           (ord)

import qualified Data.Sequence as Seq
import           Data.Sequence (Seq(..), (<|), (|>))

import Control.Monad.ST
import Data.STRef
import qualified Data.IntMap.Strict         as IM
import Data.IntMap.Strict (IntMap)

import Data.Maybe

import Data.Map (Map)
import qualified Data.Map as Map

import           Control.Applicative
import           Control.Monad

import           Prelude             hiding (all, mod)

-- Formality-Core types
-- ====================

type Name = String
type Done = Bool   -- Annotation flag
type Eras = Bool   -- Erasure mark

-- Formality-Core terms (from parsing)
data TermP
  = VarP Int                         -- Variable
  | RefP Name                        -- Reference
  | TypP                             -- Type type
  | AllP Eras Name Name TermP TermP  -- Forall
  | LamP Eras Name TermP             -- Lambda
  | AppP Eras TermP TermP            -- Application
  | LetP Name TermP TermP            -- Let expression
  | AnnP Bool TermP TermP            -- Type annotation
  deriving Show

-- Formality-Core expression definitions
data DefP = DefP { _nameP :: Name, _typeP :: TermP, _termP :: TermP } deriving Show
newtype ModuleP = ModuleP (M.Map Name DefP) deriving Show

-- shift all indices by an increment above a depth in a term
shiftP :: Int -> Int -> TermP -> TermP
shiftP 0 _ term     = term
shiftP inc dep term = let go n x = shiftP inc (dep + n) x in case term of
  VarP i         -> VarP (if i < dep then i else (i + inc))
  RefP n         -> RefP n
  TypP           -> TypP
  AllP e s n h b -> AllP e s n (go 1 h) (go 2 b)
  LamP e n b     -> LamP e n (go 1 b)
  AppP e f a     -> AppP e (go 0 f) (go 0 a)
  LetP n x b     -> LetP n (go 0 x) (go 1 b)
  AnnP d t x     -> AnnP d (go 0 t) (go 0 x)

-- substitute a value for an index at a certain depth in a term
substP :: TermP -> Int -> TermP -> TermP
substP v dep term = let go n x = substP (shiftP n 0 v) (dep + n) x in
  case term of
    VarP i         -> if i == dep then v else VarP (i - if i > dep then 1 else 0)
    RefP n         -> RefP n
    TypP           -> TypP
    AllP e s n h b -> AllP e s n (go 1 h) (go 2 b)
    LamP e n b     -> LamP e n (go 1 b)
    AppP e f a     -> AppP e (go 0 f) (go 0 a)
    LetP n x b     -> LetP n (go 0 x) (go 1 b)
    AnnP d t x     -> AnnP d (go 0 t) (go 0 x)

-- "femtoparsec" parser combinator library
-- =======================================

-- a parser of things is function from strings to
-- perhaps a pair of a string and a thing
data Parser a = Parser { runParser :: String -> Maybe (String, a) }

instance Functor Parser where
  fmap f p = Parser $ \i -> case runParser p i of
    Just (i', a) -> Just (i', f a)
    Nothing      -> Nothing

instance Applicative Parser where
  pure a       = Parser $ \i -> Just (i, a)
  (<*>) fab fa = Parser $ \i -> case runParser fab i of
    Just (i', f) -> runParser (f <$> fa) i'
    Nothing      -> Nothing

instance Alternative Parser where
  empty     = Parser $ \i -> Nothing
  (<|>) a b = Parser $ \i -> case runParser a i of
    Just (i', x) -> Just (i', x)
    Nothing      -> runParser b i

instance Monad Parser where
  return a  = Parser $ \i -> Just (i, a)
  (>>=) p f = Parser $ \i -> case runParser p i of
    Just (i', a) -> runParser (f a) i'
    Nothing      -> Nothing

choice :: [Parser a] -> Parser a
choice = asum

takeWhileP :: (Char -> Bool) -> Parser String
takeWhileP f = Parser $ \i -> Just (dropWhile f i, takeWhile f i)

takeWhile1P :: (Char -> Bool) -> Parser String
takeWhile1P f = Parser $ \i -> case i of
  (x : xs) -> if f x then runParser (takeWhileP f) i else Nothing
  _        -> Nothing

satisfy :: (Char -> Bool) -> Parser Char
satisfy f = Parser $ \i -> case i of
  (x:xs) -> if f x then Just (xs, x) else Nothing
  _       -> Nothing

anyChar :: Parser Char
anyChar = satisfy (const True)

manyTill :: Parser a -> Parser end -> Parser [a]
manyTill p end = go
  where
    go = ([] <$ end) <|> ((:) <$> p <*> go)

skipMany :: Parser a -> Parser ()
skipMany p = go
  where
    go = (p *> go) <|> pure ()

string :: String -> Parser String
string str = Parser $ \i -> case stripPrefix str i of
  Just i' -> Just (i', str)
  Nothing -> Nothing

-- Formality-Core parser
-- =====================

-- is a space character
isSpace :: Char -> Bool
isSpace c = c `elem` " \t\n"

-- is a name character
isName :: Char -> Bool
isName c = c `elem` (['0'..'9'] ++ ['a'..'z'] ++ ['A'..'Z'] ++ "_" ++ ".")

-- consume whitespace
whitespace :: Parser ()
whitespace = takeWhile1P isSpace >> return ()

-- parse // line comments
lineComment :: Parser ()
lineComment =
  choice
    [ string "//" >> takeWhileP (/= '\n') >> string "\n" >> return ()
    , string "--" >> takeWhileP (/= '\n') >> return ()
    ]

-- parse `/* */` block comments
blockComment :: Parser ()
blockComment = 
  choice
    [ string "/*" >> manyTill anyChar (string "*/") >> return ()
    , string "{-" >> manyTill anyChar (string "-}") >> return ()
    ]

-- space and comment consumer
space :: Parser ()
space = skipMany $ choice [whitespace, lineComment, blockComment]

-- parse a symbol (literal string followed by whitespace or comments)
sym :: String -> Parser String
sym s = string s <* space

-- parse an optional character
opt :: Char -> Parser Bool
opt c = isJust <$> optional (string (c:[]))

-- parse a valid name, non-empty
nam :: Parser String
nam = takeWhile1P isName

-- Parses a parenthesis, `(<term>)`
par :: [Name] -> Parser TermP
par vs = string "(" >> space >> trm vs <* space <* string ")"

-- Parses a dependent function type, `(<name> : <term>) => <term>`
-- optionally with a self-type: `<name>(<name> : <term>) => <term>`
all :: [Name] -> Parser TermP
all vs = do
  s <- maybe "" id <$> (optional nam)
  e <- (string "(" >> return False) <|> (string "<" >> return True)
  n <- maybe "" id <$> (optional nam <* space)
  t <- sym ":" >> trm (s : vs) <* space
  (if e then sym ">" else sym ")")
  b <- sym "->" >> trm (n : s : vs)
  return $ AllP e s n t b

-- Parses a dependent function value, `(<name>) => <term>`
lam :: [Name] -> Parser TermP
lam vs = do
  e <- (string "(" >> return False) <|> (string "<" >> return True)
  n <- maybe "" id <$> (space >> (optional nam) <* space)
  (if e then sym ">" else sym ")")
  b <- trm (n : vs)
  return $ LamP e n b

-- Parses the type of types, `Type`
typ :: Parser TermP
typ = string "Type" >> return TypP

-- Parses variables, `<name>`
var :: [Name] -> Parser TermP
var vs = (\n -> maybe (RefP n) VarP (elemIndex n vs)) <$> nam

let_ :: [Name] -> Parser TermP
let_ vs = do
  n <- sym "let" >> nam <* space
  x <- sym "=" >> trm vs <* space <* optional (sym ";")
  t <- trm (n:vs)
  return $ LetP n x t

-- Parses a sequence of applications:
-- `<term>(<term>)...(<term>)` or `<term> | (<term>); | ... | (<term>);`.
-- note that this parser differs from the JS parser due to Haskell's laziness
app :: [Name] -> TermP -> Parser TermP
app vs f = foldl (\t (a,e) -> AppP e t a) f <$> (some $ arg vs)
  where
  arg vs = choice
    [ do
      e <- (string "(" >> return False) <|> (string "<" >> return True)
      t <- space >> trm vs <* space <* (if e then string ">" else string ")")
      return (t,e)
    , (,False) <$> (space >> sym "|" >> trm vs <* space <* string ";")
    ]

-- Parse non-dependent function type `<term> -> <term>`
arr :: [Name] -> TermP -> Parser TermP
arr vs h = do
  b <- space >> sym "->" >> trm ("":"":vs)
  return $ AllP False "" "" (shiftP 1 0 h) b

-- Parses an annotation, `<term> :: <term>`
ann :: [Name] -> TermP -> Parser TermP
ann vs x = do
  space >> sym "::"
  t <- trm vs
  return $ AnnP False t x

-- Parses a term
trm :: [Name] -> Parser TermP
trm vs = do
  t <- choice [all vs, lam vs, let_ vs, typ, var vs, par vs]
  t <- app vs t <|> return t
  t <- arr vs t <|> return t
  ann vs t <|> return t

parseTerm :: String -> Maybe TermP
parseTerm str = snd <$> runParser (trm []) str

-- Parses a definition
def :: Parser DefP
def = DefP <$> (nam <* space) <*> (sym ":" >> trm []) <*> (space >> trm [])

-- Parses a module
mod :: Parser ModuleP
mod = ModuleP . M.fromList <$> fmap (\d -> (_nameP d, d)) <$> defs
  where
   defs = (space >> many (def <* space))

testMod :: IO (Maybe (String, ModuleP))
testMod = do
  a <- readFile "test.fm"
  return $ runParser mod a

testString1 = intercalate "\n"
  [ "identity : (A : Type) -> (a : A) -> A"
  , "(A) => (a) => a"
  , ""
  , "const : (A : Type) -> (a : A) -> (b : B) -> B"
  , "(A) => (a) => (b) => B"
  , ""
  , "apply_twice : (A : Type) -> (f : (x : A) -> A) -> (x : A) -> A"
  , "(A) => (f) => (x) => f(f(x))"
  ]

-- Stringification, or, pretty-printing
-- ===================================

--instance Show TermP where
--  show t = go [] t 
--    where
--      cat = concat
--      era e x = if e then cat ["<",cat x,">"] else cat ["(",cat x,")"]
--      go :: [Name] -> TermP -> String
--      go vs t = case t of
--        VarP i         -> vs !! i
--        RefP n         -> n
--        TypP           -> "Type"
--        AllP False "" "" h b -> case h of
--          RefP m -> cat [m," -> ",go ("":"":vs) b]
--          VarP i -> cat [vs !! i," -> ",go ("":"":vs) b]
--          TypP   -> cat ["Type -> ",go ("":"":vs) b]
--          _     -> cat [era False [go ("":vs) h], " -> ", go ("":"":vs) b]
--        AllP e s n h b -> cat [s,era e [n," : ",go (s:vs) h]," -> ",go (n:s:vs) b]
--        LamP e n b     -> cat [era e [n]," ",go (n:vs) b]
--        AppP e f a     -> case f of
--          (RefP n) -> cat [n,era e [go vs a]]
--          (VarP i) -> cat [vs !! i,era e [go vs a]]
--          f       -> cat ["(", go vs f,")", era e [go vs a]]
--        LetP n x b     -> cat ["let ", n," = ",go vs x,";", go (n:vs) b]
--        AnnP d x y     -> cat [go vs y," :: ",go vs x]


--instance Show Def where
--  show (Def n t d) = concat [n," : ", show t, "\n", show d]
--
--instance Show Module where
--  show (Module m)  = go $ snd <$> (M.toList m)
--    where
--      go []     = ""
--      go [d]    = show d
--      go (d:ds) = show d ++ "\n\n" ++ go ds

-- Hashing
-- =============

newtype Hash = Hash {_word32 :: Word32} deriving (Eq,Num,Bits,Show) via Word32

mix64 :: Word64 -> Word64
mix64 h =
  let h1     = xor h (shiftR h 33)
      h2     = h1 * 0xff51afd7ed558ccd
      h3     = xor h2 (shiftR h2 33)
      h4     = h3 * 0xc4ceb9fe1a85ec53
   in xor h4 (shiftR h4 33)

hashTwo :: Hash -> Hash -> Hash
hashTwo (Hash x) (Hash y) = Hash $ fromIntegral pos
  where
     pre = (fromIntegral x) `xor` (shiftL (fromIntegral y) 32)
     pos = shiftR (mix64 $ pre) 32

instance Semigroup Hash where
  (<>) = hashTwo

instance Monoid Hash where
  mempty = 0
  mappend = (<>)

hashStr :: String -> Hash
hashStr str = foldMap (fromIntegral . ord) str

-- Formality-Core Terms
data Term
  = Var { _hash :: Hash, _indx :: Int}
  | Ref { _hash :: Hash, _name :: Name }
  | Typ { _hash :: Hash }
  | All { _hash :: Hash, _eras :: Eras, _self :: Name
        , _name :: Name, _bind :: Term, _body :: Term
        }
  | Lam { _hash :: Hash, _eras :: Eras, _name :: Name, _body :: Term}
  | App { _hash :: Hash, _eras :: Eras, _func :: Term, _argm :: Term}
  | Let { _hash :: Hash, _name :: Name, _expr :: Term, _body :: Term}
  | Ann { _hash :: Hash, _done :: Bool, _type :: Term, _term :: Term}
  deriving Show



-- Formality-Core definitions
data Def = 
  Def { _defName :: Name, _defHash :: Hash, _defType :: Term, _defTerm :: Term } deriving Show

-- Formality-Core Module
data Module = Module { _modHash :: Hash, _defs :: M.Map Name Def } deriving Show

emptyMod = Module 0 M.empty

toModule :: ModuleP -> Module
toModule (ModuleP defs) =
  let ds = toDef <$> defs
      hash = foldMap (_defHash) ds
  in  Module hash ds

toDef :: DefP -> Def
toDef (DefP n t d) = 
  let t' = toTerm t
      d' = toTerm d
   in Def n (_hash t' <> _hash d') t' d'

toTerm :: TermP -> Term
toTerm t = let go = toTerm in case t of
  VarP i         -> Var (1 <> fromIntegral i) i
  RefP n         -> Ref (2 <> hashStr n) n
  TypP           -> Typ (3 <> 0)
  AllP e s n h b ->
    let h' = go h
        b' = go b
        hash = 4 <> _hash h' <> _hash b'
    in All hash e s n h' b'
  LamP e n b     ->
    let b'   = go b
        hash = 5  <> _hash b'
    in Lam hash e n b'
  AppP e f a     ->
    let f'   = go f
        a'   = go a
        hash = 6 <> _hash f' <> _hash a'
     in App hash e f' a'
  LetP n x b     ->
    let x'   = go x
        b'   = go x
        hash = 7 <> _hash x' <> _hash b'
     in Let hash n x' b'
  AnnP d t x     ->
    let t'   = go t
        x'   = go x
        hash = 8 <> _hash t' <> _hash x'
     in Ann hash d t' x'

fromTerm :: Term -> TermP
fromTerm t = let go = fromTerm in case t of
  Var _ i         -> VarP i
  Ref _ n         -> RefP n
  Typ _           -> TypP
  All _ e s n h b -> AllP e s n (go h) (go b)
  Lam _ e n b     -> LamP e n (go b)
  App _ e f a     -> AppP e (go f) (go a)
  Let _ n x b     -> LetP n (go x) (go b)
  Ann _ d t x     -> AnnP d (go t) (go x)

-- Substitution
-- ============

-- shift all indices by an increment above a depth in a term
shift :: Int -> Int -> Term -> Term
shift 0 _ term     = term
shift inc dep term = let go n x = shift inc (dep + n) x in case term of
  Var h i         -> if i < dep then term else
    Var (1 <> (fromIntegral $ i + inc)) (i + inc)
  All h e s n t b -> 
    let t'   = go 1 t
        b'   = go 2 b
        hash = 4 <> _hash t' <> _hash b'
    in  All hash e s n t' b'
  Lam h e n b     -> 
    let b'   = go 1 b
        hash = 5 <> _hash b'
    in Lam hash e n b'
  App h e f a     ->
    let f'   = go 0 f
        a'   = go 0 a
        hash = 6 <> _hash f' <> _hash a'
     in App hash e f' a'
  Let h n x b     ->
    let x'   = go 0 x
        b'   = go 1 x
        hash =  7 <> _hash x' <> _hash b'
     in Let hash n x' b'
  Ann h c t x     ->
    let t'   = go 0 t
        x'   = go 0 x
        hash = 8 <> _hash t' <> _hash x'
     in Ann hash c t' x'
  _               -> term

-- substitute a value for an index at a certain depth in a term
subst :: Term -> Int -> Term -> Term
subst v dep term = let go n x = subst (shift n 0 v) (dep + n) x in
  case term of
    Var h i -> case compare i dep of
      EQ -> v
      LT -> Var (1 <> (fromIntegral $ i - 1)) (i - 1)
      GT -> Var h i
    All h e s n t b -> 
      let t'   = (go 1 t)
          b'   = (go 2 b)
          hash = 4 <> (_hash t') <> (_hash b')
      in  All hash e s n t' b'
    Lam h e n b     -> 
      let b'   = go 1 b
          hash = 5 <> _hash b'
      in Lam hash e n b'
    App h e f a     ->
      let f'   = go 0 f
          a'   = go 0 a
          hash = 6 <> _hash f' <> _hash a'
       in App hash e f' a'
    Let h n x b     ->
      let x'   = go 0 x
          b'   = go 1 x
          hash = 7 <> _hash x' <> _hash b'
       in Let hash n x' b'
    Ann h c t x     ->
      let t'   = go 0 t
          x'   = go 0 x
          hash = 8 <> _hash t' <> _hash x'
       in Ann hash c t' x'
    _               -> term

-- Evaluation
-- ==========

-- Erase computationally irrelevant terms
erase :: Term -> Term
erase term = let go = erase; in case term of
  All h e s n t b -> 
    let t'   = go t
        b'   = go b
        hash = 4 <> _hash t' <> _hash b'
    in  All hash e s n t' b'
  Lam h True n b  -> subst (Ref (hashStr "<erased>") "<erased>") 0 b
  Lam h e n b     -> 
    let b'   = go b
        hash =  5 <> _hash b'
    in Lam hash e n b'
  App h True f a   -> go f
  App h e f a     ->
    let f'   = go f
        a'   = go a
        hash = 6 <> _hash f' <> _hash a'
     in App hash e f' a'
  Let h n x b     ->
    let x'   = go x
        b'   = go x
        hash = 7 <> _hash x' <> _hash b'
     in Let hash n x' b'
  Ann h c t x     -> go x

-- lookup the value of an expression in a module
deref :: Name -> Module -> Term
deref n (Module _ defs) = maybe (Ref (hashStr n) n) _defTerm (M.lookup n defs)

-- lower-order interpreter
evalTerm :: Term -> Module -> Term
evalTerm term mod = go term
  where
  go :: Term -> Term
  go t = case t of
    Lam h e n b     -> 
      let b'   = go b
          hash = 5 <> _hash b
       in Lam hash e n (go b)
    App h e f a     -> case go f of
      Lam h e n b -> go (subst a 0 b)
      f           ->
        let a' = go a
            hash = 6 <> _hash a'
         in App hash e f (go a)
    Ann h d t x     -> go x
    Let h n x b     -> subst x 0 b
    Ref h n         -> case (deref n mod) of
      Ref h' m -> go (deref n mod)
      x        -> go x
    _               -> term

-- Higher Order Abstract Syntax terms
data TermH
  = VarH Int
  | RefH Name
  | TypH
  | AllH Eras Name Name (TermH -> TermH) (TermH -> TermH -> TermH)
  | LamH Eras Name (TermH -> TermH)
  | AppH Eras TermH TermH
  | LetH Name TermH (TermH -> TermH)
  | AnnH Bool TermH TermH

-- convert lower-order terms to higher order terms
toTermH :: Term -> TermH
toTermH t = go [] t
  where
    go :: [TermH] -> Term -> TermH
    go vs t = case t of
      Var _ i         -> case find vs i of
        Nothing -> VarH i
        Just x  -> x
      Ref _ n         -> RefH n
      Typ _           -> TypH
      All _ e s n h b -> AllH e s n (\x -> go (x:vs) h) (\x y -> go (y:x:vs) b)
      Lam _ e n b     -> LamH e n (\x -> go (x:vs) b)
      App _ e f a     -> AppH e (go vs f) (go vs a)
      Let _ n x b     -> LetH n (go vs x) (\x -> go (x:vs) b)
      Ann _ d t x     -> AnnH d (go vs t) (go vs x)

-- convert higher-order terms to lower-order terms
fromTermH :: TermH -> Term
fromTermH t = go 0 t
  where
    go :: Int -> TermH -> Term
    go d t = case t of
      VarH n         -> Var (fromIntegral $ n) n
      RefH n         -> Ref (hashStr n) n
      TypH           -> Typ (3 <> 0)
      AllH e s n h b -> 
        let h'   = go (d + 1) (h $ VarH d)
            b'   = go (d + 2) (b (VarH $ d + 1) (VarH $ d + 1))
            hash = 4 <> _hash h' <> _hash b'
         in All hash e s n h' b'
      LamH e n b     -> 
        let b' = go (d + 1) (b $ VarH d)
            hash = 5 <> _hash b'
         in Lam hash e n b'
      AppH e f a     -> 
        let f'   = go d f
            a'   = go d a
            hash = 6 <> _hash f' <> _hash a'
         in App hash e f' a'
      LetH n x b     ->
        let x'   = go d x
            b'   = go (d + 1) (b $ VarH d)
            hash = 7 <> _hash x' <> _hash b'
         in Let hash n x' b'
      AnnH b t x     ->
        let t'   = go d t
            x'   = go d x
            hash = 8 <> _hash t' <> _hash x'
         in Ann hash b t' x'

-- HOAS reduction
reduceTermH :: Module -> TermH -> TermH
reduceTermH defs t = go t
  where
    go :: TermH -> TermH
    go t = case t of
      RefH n         -> case deref n defs of
        Ref _ m -> RefH m
        x       -> go (toTermH x)
      LamH True n b  -> (b $ RefH "<erased>")
      AppH True f a  -> go f
      AppH False f a -> case go f of
        LamH e n b -> go (b a)
        f          -> AppH False f (go a)
      LetH n x b     -> go (b x)
      AnnH d t x     -> go x
      _              -> t

-- convert term to higher order and reduce
reduce :: Module -> Term -> Term
reduce defs = fromTermH . reduceTermH defs . toTermH

-- HOAS normalization
normalizeTermH :: Module -> TermH -> TermH
normalizeTermH defs t = go t
  where
    go :: TermH -> TermH
    go t = case t of
      AllH e s n h b -> AllH e s n (\x -> go $ h x) (\x y -> go $ b x y)
      LamH e n b   -> LamH e n (\x -> go $ b x)
      AppH e f a   -> AppH e (go f) (go a)
      AnnH d t x   -> go x
      LetH n x b   -> LetH n (go x) (\x -> go $ b x)
      _            -> t

-- convert term to higher order and normalize
normalize :: Module -> Term -> Term
normalize defs = fromTermH . normalizeTermH defs . toTermH


-- Union Find
-- ===========

-- An lightweight implementation of Tarjan's Union-Find algorithm for hashable
-- types. This is a port of the /equivalence/ package and uses mutable
-- references.

-- Each equivalence class has one member, or root, that serves as its
-- representative element. Every element in the class is either the root
-- (distance 0), points directly to the root (distance 1), 
-- or points to an element with a smaller distance to the root.
--
-- Therefore, whenever we want to test whether two elements are in the same
-- class, we follow their references until we hit their roots, and then compare
-- their roots for equality.
--
-- This algorithm performs lazy path compression. Whenever we traverse a path 
-- containing nodes with a distance from root > 1, once we hit the root we
-- update all the nodes in that path to point to the root directly:
--
-- *           *
-- |         /   \
-- a   =>   a     b
-- |
-- b

-- Additionally, when we merge two classes via `union`, the root of the smaller
-- class will point to the root of the larger
--
-- *1      *2           *2
-- |   +   |    =>    /  |
-- a       b         *1  b
--         |         |   |
--         c         a   c
--
-- The integer values in the Val type are intended for use with some `a -> Int`
-- hashing function

type Val = Int

-- A reference to a node
newtype NRef s = NRef { _ref :: STRef s (Node s) } deriving Eq

-- A Node is either root or a link
data Node s
  = Root {_value :: Val, _weight :: Int}
  | Node {_value :: Val, _parent :: NRef s}

-- An equivalence relation is a reference to a map of elements to node references
data Equiv s = Equiv {_elems :: STRef s (IntMap (NRef s))}

-- A new equivalence relation
newEquiv :: ST s (Equiv s)
newEquiv = Equiv <$> (newSTRef IM.empty)

-- create a new class in a relation with a value as root
singleton :: Equiv s -> Val -> ST s (NRef s)
singleton eq val = do
  root <- NRef <$> newSTRef (Root {_value = val, _weight = 1})
  modifySTRef (_elems eq) (IM.insert val root)
  return root

-- given a reference, find a reference to the root of its equivalence class.
-- This function performs path compression
findRoot :: NRef s -> ST s (NRef s)
findRoot ref = do
  node <- readSTRef (_ref ref)
  case node of
    Root {} -> return ref
    Node {_parent = refToParent} -> do
      refToRoot <- findRoot refToParent
      if refToRoot /= refToParent then
        writeSTRef (_ref ref) node{_parent = refToRoot} >> return refToRoot
      else return refToRoot

-- combine two equivalence classes, merging the smaller into the larger
union :: NRef s -> NRef s -> ST s ()
union refX refY = do
  refToRootX <- findRoot refX
  refToRootY <- findRoot refY
  when (refToRootX /= refToRootY) $ do
    (Root vx wx) <- readSTRef (_ref refToRootX)
    (Root vy wy) <- readSTRef (_ref refToRootY)
    if (wx >= wy) then do
      writeSTRef (_ref refToRootY) (Node vy refToRootX)
      writeSTRef (_ref refToRootX) (Root vx (wx + wy))
    else do
      writeSTRef (_ref refToRootX) (Node vx refToRootY)
      writeSTRef (_ref refToRootY) (Root vy (wx + wy))

-- Are these two references pointing to the same root?
equivalent :: NRef s -> NRef s -> ST s Bool
equivalent x y = (==) <$> findRoot x <*> findRoot y

isEquivalent :: Equiv s -> Val -> Val -> ST s Bool
isEquivalent eq a b = do
  elems <- readSTRef (_elems eq)
  case (IM.lookup a elems, IM.lookup b elems) of
    (Just x,Just y) -> (==) <$> findRoot x <*> findRoot y
    _               -> equate eq a b >> return (a == b)

getRef :: Equiv s -> Val -> ST s (Maybe (NRef s))
getRef eq x = do
  m <- readSTRef (_elems eq)
  return $ IM.lookup x m

equate :: Equiv s -> Val -> Val -> ST s ()
equate eq x y = do
  rx <- (maybe (singleton eq x) return) =<< (getRef eq x)
  ry <- (maybe (singleton eq y) return) =<< (getRef eq y)
  union rx ry

-- Equality
-- ========

congruent :: Equiv s -> Term -> Term -> ST s Bool
congruent eq a b = do
  let getHash = fromIntegral . _word32 . _hash
  i <- isEquivalent eq (getHash a) (getHash b)
  if i then return True else do
  let go = congruent eq
  case (a,b) of
    (All _ _ _ _ h b, All _ _ _ _ h' b') -> (&&) <$> go h h' <*> go b b'
    (Lam _ _ _ b,     Lam _ _ _ b')      -> go b b'
    (App _ _ f a,     App _ _ f' a')     -> (&&) <$> go f f' <*> go a a'
    (Let _ _ x b,     Let _ _ x' b')     -> (&&) <$> go x x' <*> go b b'
    (Ann _ _ t x,     Ann _ _ t' x')     -> go x x'
    _                                    -> return False

equal :: Module -> Term -> Term -> Bool
equal mod a b = runST $ (newEquiv >>= (\e -> go e $ Seq.singleton (a,b,0)))
  where
    getHash = fromIntegral . _word32 . _hash
    mkRef x = Ref (2 <> hashStr ("%" ++ (show x))) ("%" ++ (show x))
    go :: Equiv s -> Seq (Term,Term,Int) -> ST s Bool
    go _  Empty              = return True
    go eq ((a,b,depth):<|vs) = do
      let a' = reduce mod a
      let b' = reduce mod b
      id <- congruent eq a' b'
      equate eq (getHash a)  (getHash a')
      equate eq (getHash b)  (getHash b')
      equate eq (getHash a') (getHash b')
      if id then (go eq vs)
      else case (a',b') of
        (All _ _ _ _ ah ab, All _ _ _ _ bh bb) -> do
          let ah'  = subst (mkRef $ depth + 0) 0 ah
          let bh'  = subst (mkRef $ depth + 0) 0 bh
          let ab'  = subst (mkRef $ depth + 1) 1 ab
          let ab'' = subst (mkRef $ depth + 0) 0 ab'
          let bb'  = subst (mkRef $ depth + 1) 1 bb
          let bb'' = subst (mkRef $ depth + 0) 0 bb'
          go eq (vs:|>(ah',bh', depth + 1):|>(ab'',bb'', depth + 2))
        (Lam _ _ _ ab,     Lam _ _ _ bb)      -> do
          let ab' = subst (mkRef $ depth + 0) 0 ab
          let bb' = subst (mkRef $ depth + 0) 0 bb
          go eq (vs:|>(ab',bb', depth + 1))
        (App _ _ af aa,     App _ _ bf ba)  -> do
          go eq (vs:|>(af,bf,depth):|>(aa,ba,depth))
        (Let _ _ ax ab,     Let _ _ bx bb)     -> do
          let ab' = subst (mkRef $ depth + 0) 0 ab
          let bb' = subst (mkRef $ depth + 0) 0 bb
          go eq (vs:|>(ax,bx,depth):|>(ab',bb',depth + 1))
        (Ann _ _ _ ax,     Ann _ _ _ bx)     -> do
          go eq (vs:|>(ax,bx,depth))
        _ -> return False

data TypeError = TypeError String deriving Show

typecheck :: Module -> [Term] -> [Name] -> Term -> Term ->  Either TypeError Term
typecheck mod ctx nam typ trm  = case (trm, reduce mod typ) of
  (Lam _ e n b, typv@(All _ te _ tn th tb)) -> do
--    let self_typ = Ann True Typ typv
    let bind_typ = subst trm 0 th
    let body_typ = subst (shift 0 1 trm) 1 tb
    if (e /= te) then Left $ TypeError "Erasure mismatch"
    else typecheck mod (bind_typ:ctx) (n:nam) body_typ b
  (Lam _ _ _ _, _) -> Left $ TypeError "Lambda has a non-function type"
  _                -> do 
    infr <- typeinfer mod ctx nam trm
    if (equal mod typ infr) then return typ
    else Left $ TypeError $
      intercalate "\n" 
        [ "Unexpected type: "
        , "Expected: ", show typ
        , "Inferred: ", show infr
        , "Inferred on: ", show trm
        , "Context: ", show ctx
        , "Names:    ", show nam
        ]

find :: [a] -> Int -> Maybe a
find xs i
  | i < 0 || i >= length xs = Nothing
  | otherwise = Just $ xs !! i

typeinfer :: Module -> [Term] -> [Name] -> Term -> Either TypeError Term
typeinfer mod ctx nam term = case term of
  Var _ i         -> case find ctx i of
    Nothing -> Left $ TypeError "Unbound variable"
    Just x  -> return $ shift (i + 1) 0 x
  Ref _ n         -> case M.lookup n (_defs mod) of
    Nothing -> Left $ TypeError "Undefined Reference"
    Just d  -> return $ _defType d
  Typ h       -> return $ Typ h
  App _ e f a     -> do
    func_typ <- reduce mod <$> typeinfer mod ctx nam f
    case func_typ of
      All _ te ts tn th tb -> do
        when (e /= te) (Left $ TypeError "Erasure mismatch")
        let expe_typ = subst f 0 tb
        typecheck mod ctx nam expe_typ a
        let term_typ = subst (shift 1 0 f) 1 tb
        return $ subst (shift 0 0 a) 0 term_typ
      _ -> Left $ TypeError "Non-function application"
  Let _ n x b     -> do
    expr_type <- typeinfer mod ctx nam x
    body_type <- typeinfer mod (expr_type:ctx) (n:nam) b
    return $ subst x 0 body_type
  All h e s n bind body -> do
    let self_type = Ann (8 <> (3 <> 0) <> h) True (Typ (3 <> 0)) term
    bind_typ <- typeinfer mod (self_type:ctx) (s:nam) bind
    typecheck mod (bind:self_type:ctx) (n:s:nam) (Typ (3 <> 0)) body
    return $ Typ (3 <> 0)
  Ann _ True t x  -> return t
  Ann _ False t x -> typecheck mod ctx nam t x
  _ -> Left $ TypeError "Can't infer type"

typecheckDef :: Module -> Def -> IO ()
typecheckDef m (Def nam _ typ term) = do
  let x = typecheck m [] [] typ term
  case x of
    Left (TypeError s) -> do
      putStrLn ("Checking: " ++ nam)
      putStrLn s >> return ()
    Right t            -> print t


typecheckName :: Module -> Name -> Either TypeError Term
typecheckName m n = case (_defs m) M.! n of
  (Def _ _ term typ) -> typecheck m [] [] typ term

typecheckMod :: IO ()
typecheckMod = do
  a <- readFile "test.fm"
  case runParser mod a of
   Nothing    -> putStrLn "Parse Error"
   Just (x,m) -> do
     when (x /= "") (putStrLn "expected EOF")
     let mod = toModule m
     sequence (typecheckDef mod <$> (_defs mod))
     return ()
