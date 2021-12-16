------------------------------------------------------------------------
-- The Agda standard library
--
-- A simple tactic for used to automatically compute the function
-- argument to cong.
--
-- The main use for this tactic is getting a similar experience to
-- 'rewrite' during equational reasoning. This allows us to write very
-- succinct proofs:
--
-- example : ∀ m n → m ≡ n → suc (suc (m + 0)) + m ≡ suc (suc n) + (n + 0)
-- example m n eq = begin
--     suc (suc (m + 0)) + m
--   ≡⟨ rw (+-identityʳ m) ⟩
--     suc (suc m) + m
--   ≡⟨ rw eq ⟩
--     suc (suc n) + n
--   ≡˘⟨ rw (+-identityʳ n) ⟩
--     suc (suc n) + (n + 0)
--   ∎
------------------------------------------------------------------------

{-# OPTIONS --without-K --safe #-}

module Tactic.Rewrite where

open import Function using (_$_)

open import Data.Bool.Base            using (true; false; if_then_else_; _∧_)
open import Data.Char.Base   as Char  using (toℕ)
open import Data.Float.Base  as Float using (_≡ᵇ_)
open import Data.List.Base   as List  using ([]; _∷_)
open import Data.Maybe.Base  as Maybe using (Maybe; just; nothing)
open import Data.Nat.Base    as Nat   using (ℕ; zero; suc; _≡ᵇ_; _+_)
open import Data.Unit.Base            using (⊤)
open import Data.Word.Base   as Word  using (toℕ)
open import Data.Product

open import Relation.Binary.PropositionalEquality as Eq using (_≡_; refl; cong)

-- 'Data.String.Properties' defines this via 'Dec', so let's use the builtin
-- for maximum speed.
import Agda.Builtin.String as String renaming (primStringEquality to _≡ᵇ_)

open import Reflection
open import Reflection.Abstraction
open import Reflection.AlphaEquality        as Alpha
open import Reflection.Argument             as Arg
open import Reflection.Argument.Information as ArgInfo
open import Reflection.Argument.Visibility  as Visibility
open import Reflection.Meta                 as Meta
open import Reflection.Name                 as Name
open import Reflection.Term                 as Term

open import Reflection.TypeChecking.Monad.Syntax

----------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------

private
  -- Descend past a variable.
  var-descend : ℕ → ℕ → ℕ
  var-descend ϕ x = if ϕ Nat.≤ᵇ x then suc x else x

  -- Descend a variable underneath pattern variables.
  pattern-descend : ℕ → Pattern → (Pattern × ℕ)
  patterns-descend : ℕ → Args Pattern → (Args Pattern × ℕ)

  pattern-descend ϕ (con c ps) =
    let (ps' , ϕ') = patterns-descend ϕ ps
    in (con c ps' , ϕ')
  pattern-descend ϕ (dot t)    = (dot t) , ϕ
  pattern-descend ϕ (var x)    = var (var-descend ϕ x) , suc ϕ
  pattern-descend ϕ (lit l)    = (lit l) , ϕ
  pattern-descend ϕ (proj f)   = (proj f) , ϕ
  pattern-descend ϕ (absurd x) = absurd (var-descend ϕ x) , suc ϕ

  patterns-descend ϕ ((arg i p) ∷ ps) =
    let (p' , ϕ') = pattern-descend ϕ p
        (ps' , ϕ'') = patterns-descend ϕ' ps
    in (arg i p ∷ ps' , ϕ'')
  patterns-descend ϕ []       =
    [] , ϕ

  -- Helper for constructing applications of 'cong'
  `cong : Term → Term → Term
  `cong f eq = def (quote cong) (4 ⋯⟅∷⟆ vArg (lam visible (abs "ϕ" f)) ∷ 2 ⋯⟅∷⟆ vArg eq ∷ [])

  -- Construct an error when the goal is not 'x ≡ y' for some 'x' and 'y'.
  not-equality-error : ∀ {A : Set} Term → TC A
  not-equality-error goal = typeError (strErr "Cannot rewrite a goal that is not equality: " ∷ termErr goal ∷ [])

  -- Extract out both endpoints of an equality type.
  endpoints : Term → TC (Term × Term)
  endpoints goal@(def x (lvl ∷ tp ∷ (arg _ e0) ∷ (arg _ e1) ∷ [])) =
    if x Name.≡ᵇ (quote _≡_) then return (e0 , e1) else not-equality-error goal 
  endpoints (meta m args) = blockOnMeta m
  endpoints goal = not-equality-error goal 

----------------------------------------------------------------------
-- Anti-Unification
--
-- The core idea of the tactic is that we can compute the input
-- to 'cong' by syntactically anti-unifying both sides of the
-- equality, and then using that to construct a lambda
-- where all the differences are replaced by the lambda-abstracted
-- variable.
--
-- For instance, the two terms 'suc (m + (m + 0)) + (m + 0)' and
-- 'suc (m + m) + (m + 0)' would anti unify to 'suc (m + _) + (m + 0)'
-- which we can then use to construct the lambda 'λ ϕ → suc (m + ϕ) + (m + 0)'.
----------------------------------------------------------------------

private
  anti-unify : ℕ → Term → Term → Term
  anti-unify-args : ℕ → Args Term → Args Term → Maybe (Args Term)
  anti-unify-clauses : ℕ → Clauses → Clauses → Maybe Clauses
  anti-unify-clause : ℕ → Clause → Clause → Maybe Clause
  
  anti-unify ϕ (var x args) (var y args') with x Nat.≡ᵇ y | anti-unify-args ϕ args args'
  ... | _     | nothing    = var ϕ []
  ... | false | just uargs = var ϕ uargs
  ... | true  | just uargs = var (var-descend ϕ x) uargs
  anti-unify ϕ (con c args) (con c' args') with c Name.≡ᵇ c' | anti-unify-args ϕ args args'
  ... | _     | nothing    = var ϕ []
  ... | false | just uargs = var ϕ []
  ... | true  | just uargs = con c uargs
  anti-unify ϕ (def f args) (def f' args') with f Name.≡ᵇ f' | anti-unify-args ϕ args args'
  ... | _     | nothing    = var ϕ []
  ... | false | just uargs = var ϕ []
  ... | true  | just uargs = def f uargs
  anti-unify ϕ (lam v (abs s t)) (lam _ (abs _ t')) =
    lam v (abs s (anti-unify (suc ϕ) t t'))
  anti-unify ϕ (pat-lam cs args) (pat-lam cs' args') with anti-unify-clauses ϕ cs cs' | anti-unify-args ϕ args args'
  ... | nothing  | _       = var ϕ []
  ... | _        | nothing = var ϕ []
  ... | just ucs | just uargs = pat-lam ucs uargs
  anti-unify ϕ (Π[ s ∶ arg i a ] b) (Π[ _ ∶ arg _ a' ] b') =
    Π[ s ∶ arg i (anti-unify ϕ a a') ] anti-unify (suc ϕ) b b'
  anti-unify ϕ (sort (set t)) (sort (set t')) =
    sort (set (anti-unify ϕ t t'))
  anti-unify ϕ (sort (lit n)) (sort (lit n')) with n Nat.≡ᵇ n'
  ... | true  = sort (lit n)
  ... | false = var ϕ []
  anti-unify ϕ (sort (prop t)) (sort (prop t')) =
    sort (prop (anti-unify ϕ t t'))
  anti-unify ϕ (sort (propLit n)) (sort (propLit n')) with n Nat.≡ᵇ n'
  ... | true  = sort (propLit n)
  ... | false = var ϕ []
  anti-unify ϕ (sort (inf n)) (sort (inf n')) with n Nat.≡ᵇ n'
  ... | true  = sort (inf n)
  ... | false = var ϕ []
  anti-unify ϕ (sort unknown) (sort unknown) =
    sort unknown
  anti-unify ϕ (lit (nat n)) (lit (nat n')) with n Nat.≡ᵇ n'
  ... | true  = lit (nat n)
  ... | false = var ϕ []
  anti-unify ϕ (lit (word64 n)) (lit (word64 n')) with Word.toℕ n Nat.≡ᵇ Word.toℕ n'
  ... | true  = lit (word64 n)
  ... | false = var ϕ []
  anti-unify ϕ (lit (float x)) (lit (float x')) with x Float.≡ᵇ x'
  ... | true  = lit (float x)
  ... | false = var ϕ []
  anti-unify ϕ (lit (char c)) (lit (char c')) with Char.toℕ c Nat.≡ᵇ Char.toℕ c'
  ... | true  = lit (char c)
  ... | false = var ϕ []
  anti-unify ϕ (lit (string s)) (lit (string s')) with s String.≡ᵇ s'
  ... | true = lit (string s)
  ... | false = var ϕ []
  anti-unify ϕ (lit (name x)) (lit (name x')) with x Name.≡ᵇ x'
  ... | true  = lit (name x)
  ... | false = var ϕ []
  anti-unify ϕ (lit (meta x)) (lit (meta x')) with x Meta.≡ᵇ x'
  ... | true = lit (meta x)
  ... | false = var ϕ []
  anti-unify ϕ (meta x args) (meta x' args') with x Meta.≡ᵇ x' | anti-unify-args ϕ args args'
  ... | _     | nothing    = var ϕ []
  ... | false | _          = var ϕ []
  ... | true  | just uargs = meta x uargs
  anti-unify ϕ unknown unknown = unknown
  anti-unify ϕ _ _ = var ϕ []
  
  anti-unify-args ϕ (arg i t ∷ args) (arg _ t' ∷ args') =
    Maybe.map (arg i (anti-unify ϕ t t') ∷_) (anti-unify-args ϕ args args')
  anti-unify-args ϕ [] [] =
    just []
  anti-unify-args ϕ _ _ =
    nothing
  
  anti-unify-clause ϕ (clause Γ pats t) (clause Δ pats' t') =
    Maybe.when (Γ =α=-Telescope Δ ∧ pats =α=-ArgsPattern pats')
      let (upats , ϕ') = patterns-descend ϕ pats in
      (clause Γ upats (anti-unify ϕ' t t'))
  anti-unify-clause ϕ (absurd-clause Γ pats) (absurd-clause Δ pats') =
    Maybe.when (Γ =α=-Telescope Δ ∧ pats =α=-ArgsPattern pats') (absurd-clause Γ pats)
  anti-unify-clause ϕ _ _ =
    nothing
  
  anti-unify-clauses ϕ (c ∷ cs) (c' ∷ cs') =
    Maybe.ap (Maybe.map _∷_ (anti-unify-clause ϕ c c')) (anti-unify-clauses ϕ cs cs')
  anti-unify-clauses ϕ _ _ =
    just []


----------------------------------------------------------------------
-- Rewriting
----------------------------------------------------------------------

macro
  rw : Term → Term → TC ⊤
  rw eq hole =
    -- NOTE: We avoid doing normalisation here as this tactic
    -- is mainly meant for equational reasoning. In that context,
    -- the endpoints are already specified in the form that the
    -- programmer expects them to be in, so normalising buys us
    -- nothing.
    withNormalisation false $ do
      goal ← reduce hole >>= inferType 
      (e0 , e1) ← endpoints goal
      let f = anti-unify 0 e0 e1
      unify (`cong f eq) hole


open Eq.≡-Reasoning
open import Data.Nat.Properties

example : ∀ (m n : ℕ) → m ≡ n → suc (suc (m + 0)) + m ≡ suc (suc n) + (n + 0)
example m n eq = begin
    suc (suc (m + 0)) + m
  ≡⟨ rw (+-identityʳ m) ⟩
    suc (suc m) + m
  ≡⟨ rw eq ⟩
    suc (suc n) + n
  ≡˘⟨ rw (+-identityʳ n) ⟩
    suc (suc n) + (n + 0)
  ∎
