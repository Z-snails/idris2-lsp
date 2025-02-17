module Language.LSP.CodeAction.RefineHole

import Core.Case.CaseTree
import Core.Context
import Core.Core
import Core.Env
import Core.Metadata
import Core.UnifyState
import Data.String
import Idris.REPL.Common
import Idris.REPL.Opts
import Idris.Resugar
import Idris.Syntax
import Language.JSON
import Language.LSP.CodeAction
import Language.LSP.CodeAction.Utils
import Language.LSP.Message
import Language.LSP.Message.Derive
import Language.Reflection
import Libraries.Data.NameMap
import Parser.Source
import Parser.Rule.Source
import Server.Configuration
import Server.Log
import Server.Utils
import TTImp.Interactive.ExprSearch
import TTImp.TTImp
import TTImp.TTImp.Functor
import TTImp.Utils

%language ElabReflection
%hide TT.Name

export
record RefineHoleWithHintsParams where
  constructor MkRefineHoleWithHintsParams
  codeAction : CodeActionParams
  hints : List String

%runElab deriveJSON defaultOpts `{RefineHoleWithHintsParams}

dropLams : Nat -> RawImp -> RawImp
dropLams Z tm = tm
dropLams (S k) (ILam _ _ _ _ _ sc) = dropLams k sc
dropLams _ tm = tm

dropLamsTm : {vars : _} -> Nat -> Env Term vars -> Term vars -> (vars' ** (Env Term vars', Term vars'))
dropLamsTm Z env tm = (_ ** (env, tm))
dropLamsTm (S k) env (Bind _ _ b sc) = dropLamsTm k (b :: env) sc
dropLamsTm _ env tm = (_ ** (env, tm))

isHole : Defs -> Name -> Core Bool
isHole defs n = do
  Just def <- lookupCtxtExact n defs.gamma
    | Nothing => pure False
  pure $ case def.definition of
    Hole _ _ => True
    _        => False

isRawHole : RawImp' nm -> Bool
isRawHole (ILam fc x y z argTy lamTy) = isRawHole lamTy
isRawHole (IHole fc x) = False
isRawHole _ = True

||| Checks if the name is visible in the namespace of the hole.
checkVisibleName : Ref Ctxt Defs => Name -> Name -> GlobalDef -> Core Bool
checkVisibleName hole name def = do
  (Just nameNS, _) <- displayName <$> toFullNames name
    | _ => pure False
  (Just holeNS, _) <- displayName <$> toFullNames hole
    | _ => pure False
  if nameNS == holeNS
     then pure True
     else pure $ !(isVisible nameNS) && def.visibility /= Private

||| Check if the name has the exact type and is not a hole
nameHasType : Ref LSPConf LSPConfiguration
           => Ref Ctxt Defs
           => Ref MD Metadata
           => Ref UST UState
           => Name -> Name -> ClosedTerm -> Core Bool
nameHasType hole name expected = do
  defs <- get Ctxt
  Just def <- lookupCtxtExact name defs.gamma
    | Nothing => pure False
  True <- checkVisibleName hole name def
    | False => pure False
  nt <- normaliseAll defs [] def.type
  ex <- normaliseAll defs [] expected
  equivTypes nt ex

findFirstN : Nat -> (a -> Core (Maybe b)) -> List a -> Core (List b)
findFirstN Z f xs = pure []
findFirstN (S k) f [] = pure []
findFirstN (S k) f (x :: xs) = case !(f x) of
  Nothing => findFirstN (S k) f xs
  Just y  => (y ::) <$> findFirstN k f xs

||| Keeps the name with same preffix as the hole, ignoring namespaces.
typeMatchingNames : Ref LSPConf LSPConfiguration
                 => Ref Ctxt Defs
                 => Ref MD Metadata
                 => Ref UST UState
                 => Name -> ClosedTerm -> Nat -> Core (List Name)
typeMatchingNames hole ty limit = do
  defs <- get Ctxt
  let holeUNR = userNameRoot hole
  let find = findFirstN limit $ \fun =>
        let funUNR = userNameRoot fun
         in if holeUNR /= funUNR && !(nameHasType hole fun ty)
               then pure $ Just fun
               else pure Nothing
  find $ keys $ namesResolvedAs defs.gamma

buildCodeAction : Name -> URI -> Range -> String -> CodeAction
buildCodeAction name uri range str =
  MkCodeAction
    { title       = "Refine hole on \{show $ dropAllNS name} as ~ \{strSubstr 0 50 str} ..."
    , kind        = Just RefactorRewrite
    , diagnostics = Just []
    , isPreferred = Just False
    , disabled    = Nothing
    , edit        = Just $ MkWorkspaceEdit
        { changes           = Just (singleton uri [MkTextEdit range str])
        , documentChanges   = Nothing
        , changeAnnotations = Nothing
        }
    , command     = Nothing
    , data_       = Nothing
    }
    
||| Tries to resolve a type like Nat, Maybe
||| It ignores the type parameters
resolveTypeName : Ref Ctxt Defs
               => Ref LSPConf LSPConfiguration
               => {vars : _}
               -> Term vars
               -> Core (Maybe Name)
resolveTypeName (Ref {name, _}) = Just <$> toFullNames name
resolveTypeName (Bind {scope, _}) = resolveTypeName scope -- ignores explicit/implicit parameters
resolveTypeName (App {fn, _}) = resolveTypeName fn        -- ignores type parameters
resolveTypeName other = logD RefineHole "resolveTypeName: \{show other}" >> pure Nothing

keepNonHoleNames : Ref Ctxt Defs => List Name -> Core (List Name)
keepNonHoleNames names = do
  defs <- get Ctxt
  filterM (map not . isHole defs) names

hasHints : List Name -> RawImp -> Bool
hasHints hs tm = not $ null $ intersect hs (findAllNames [] tm)

export
refineHoleKind : CodeActionKind
refineHoleKind = Other "refactor.rewrite.RefineHole"

isAllowed : CodeActionParams -> Bool
isAllowed params =
  maybe True (\filter => (refineHoleKind `elem` filter) || (RefactorRewrite `elem` filter)) params.context.only

refineHole' : Ref LSPConf LSPConfiguration
           => Ref MD Metadata
           => Ref Ctxt Defs
           => Ref UST UState
           => Ref Syn SyntaxInfo
           => Ref ROpts REPLOpts
           => CodeActionParams -> List Name -> Core (List CodeAction)
refineHole' params hints = do
  let True = isAllowed params
    | False => logI RefineHole "Skipped" >> pure []
  logI RefineHole "Checking for \{show params.textDocument.uri} at \{show params.range}"

  withSingleLine RefineHole params (pure []) $ \line => do
    fuel <- gets LSPConf searchLimit
    nameLocs <- gets MD nameLocMap
    let col = params.range.start.character
    let Just (loc@(_, nstart, nend), name) = findPointInTreeLoc (line, col) nameLocs
      | Nothing => logD RefineHole "No name found at \{show line}:\{show col}}" >> pure []
    logD RefineHole "Found name \{show name}"

    defs <- get Ctxt
    toBrack <- gets Syn (elemBy (\x, y => dropNS x == dropNS y) name . bracketholes)
    let showPTerm : IPTerm -> String = if toBrack then show . addBracket replFC else show
    let opts = MkSearchOpts True True Nothing 2 False False True False False Nothing
    names <- lookupCtxtName name defs.gamma
    solutions <-
      case names of
           [(n, nidx, def@(MkGlobalDef {definition = (Hole locs _), _}))] => do
             catch (do searchtms <- the (Core (List RawImp)) $ if null hints
                          then do matchingNames <- keepNonHoleNames =<< typeMatchingNames n def.type 1000
                                  similar <- keepNonHoleNames =<< maybe [] (map fst . snd) <$> getSimilarNames n
                                  fst <$> searchN fuel (exprSearchOpts opts replFC name (matchingNames ++ similar))
                          else do filtered <- filterS (hasHints hints) <$> exprSearchOpts opts replFC name hints
                                  fst <$> searchN fuel filtered
                       let searchtms = filter isRawHole searchtms
                       traverse (map showPTerm . pterm . map defaultKindedName . dropLams locs) searchtms)
                   (\case Timeout _ => logI RefineHole "Timed out" >> pure []
                          err => logC RefineHole "Unexpected error while searching" >> throw err)
           [(n, nidx, def@(MkGlobalDef {definition = (PMDef pi [] (STerm _ tm) _ _), _}))] => case holeInfo pi of
             NotHole => logD RefineHole "\{show name} is not a metavariable" >> pure []
             SolvedHole locs => do
               (_ ** (env, tm')) <- dropLamsTm locs [] <$> normaliseHoles defs [] tm
               itm <- resugar env tm'
               pure [showPTerm itm]
           _ => logD RefineHole "\{show name} is not a metavariable" >> pure []

    let range = MkRange (uncurry MkPosition nstart) (uncurry MkPosition nend)
    let actions = buildCodeAction name params.textDocument.uri range <$> solutions
    pure actions

export
refineHole : Ref LSPConf LSPConfiguration
          => Ref MD Metadata
          => Ref Ctxt Defs
          => Ref UST UState
          => Ref Syn SyntaxInfo
          => Ref ROpts REPLOpts
          => CodeActionParams -> Core (List CodeAction)
refineHole params = refineHole' params []

export
refineHoleWithHints : Ref LSPConf LSPConfiguration
                   => Ref MD Metadata
                   => Ref Ctxt Defs
                   => Ref UST UState
                   => Ref Syn SyntaxInfo
                   => Ref ROpts REPLOpts
                   => RefineHoleWithHintsParams -> Core (List CodeAction)
refineHoleWithHints params = do
  defs <- get Ctxt
  hs <- for params.hints $ \str => do
    let Right (_, _, n) = runParser (Virtual Interactive) Nothing str name
      | _ => pure []
    ns <- lookupCtxtName n defs.gamma
    pure $ fst <$> ns
  refineHole' params.codeAction (concat hs)
