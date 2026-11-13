---------------------------- MODULE OnionRetry ----------------------------
(* Finite model of Sources/Onion/Public/NetworkingHandler.swift (1.0.0):   *)
(* NetworkingHandler.run -> tryToLoad (3 attempts) ->                      *)
(* tryToRunAndRefreshTokenWhenNeeded (401 => refreshToken, one resend).    *)
(* The server is a script: resp[i] is the outcome of the i-th apiClient    *)
(* call, ref[j] the outcome of the j-th refreshToken(): "ok" (new token),  *)
(* "fail" (throws) or "notoken" (returns but token stays nil). TLC         *)
(* enumerates every script, upload and plain requests, and both initial    *)
(* token states, so each law holds for every server/login behaviour.       *)
(* Result: "ok"; "err" = a request error (retried by tryToLoad);           *)
(* "refreshErr" = NetworkingHandlerError.unableToRefreshToken (never       *)
(* retried). The legacy_* mutants re-introduce the bugs fixed in 1.0.0.    *)
EXTENDS Naturals, Sequences

CONSTANTS Mutant   \* "none" for the real semantics, otherwise a seeded bug

Outcomes   == {"ok", "e401", "eoth"}
RefOutcome == {"ok", "fail", "notoken"}
Resps      == [1..6 -> Outcomes]      \* at most 3 attempts x (send + resend)
Refs       == [1..3 -> RefOutcome]    \* at most one refresh per attempt

Init0(tok) == [a |-> 1, f |-> 1, tok |-> tok, calls |-> <<>>, kinds |-> <<>>,
               nref |-> 0, nfail |-> 0, stale |-> 0, wrong |-> 0,
               res |-> "none", why |-> "none"]

\* One apiClient call: record header and API used (upload/run), consume a response.
Call(S, hdr, kind) == [S EXCEPT !.a = @ + 1, !.calls = Append(@, hdr), !.kinds = Append(@, kind)]
Out(resp, S) == resp[S.a - 1]

AuthAttempt(resp, ref, up, S0) ==
  LET k0   == IF up THEN "upload" ELSE "run"
      hdr0 == IF S0.tok # 0 /\ Mutant # "ignores_token" THEN S0.tok ELSE 0
      S1   == Call(S0, hdr0, k0)
      o1   == Out(resp, S1)
      S1w  == [S1 EXCEPT !.wrong = @ + (IF hdr0 # S0.tok /\ S0.tok # 0 THEN 1 ELSE 0)]
      r    == ref[S1w.f]
      S2   == [S1w EXCEPT !.f = @ + 1, !.nref = @ + 1,
                          !.nfail = @ + (IF r = "ok" THEN 0 ELSE 1)]
      newTok == S2.tok + 1
      S3   == [S2 EXCEPT !.tok = newTok]
      hdr3 == IF Mutant = "stale_token" THEN S2.tok ELSE newTok
      k3   == IF up /\ Mutant # "legacy_resend_uses_run" THEN "upload" ELSE "run"
      S4   == Call(S3, hdr3, k3)
      S4s  == [S4 EXCEPT !.stale = @ + (IF hdr3 # newTok THEN 1 ELSE 0)]
      o4   == Out(resp, S4s)
  IN IF o1 = "ok" THEN [S1w EXCEPT !.res = "ok"]
     ELSE IF o1 = "e401" /\ Mutant = "ok_on_401" THEN [S1w EXCEPT !.res = "ok"]
     ELSE IF o1 = "e401" THEN
            (IF r = "fail" THEN [S2 EXCEPT !.res = "refreshErr", !.why = "refresh_failed"]
             ELSE IF r = "notoken" THEN
               (IF Mutant = "legacy_no_token_crash" THEN [S2 EXCEPT !.res = "crash"]
                ELSE [S2 EXCEPT !.res = "refreshErr", !.why = "no_token"])
             ELSE IF o4 = "ok" THEN [S4s EXCEPT !.res = "ok"]
             ELSE IF o4 = "e401" THEN [S4s EXCEPT !.res = "refreshErr", !.why = "still_401"]
             ELSE IF Mutant = "legacy_wraps_resend_errors"
                  THEN [S4s EXCEPT !.res = "refreshErr", !.why = "resend_error"]
             ELSE [S4s EXCEPT !.res = "err"])
     ELSE [S1w EXCEPT !.res = "err"]

PlainAttempt(resp, ref, up, S0) ==
  LET S1 == Call(S0, 0, "run")
      S2 == IF Mutant = "unauth_refreshes" /\ Out(resp, S1) = "e401"
            THEN [S1 EXCEPT !.f = @ + 1, !.nref = @ + 1] ELSE S1
  IN [S2 EXCEPT !.res = IF Out(resp, S1) = "ok" THEN "ok" ELSE "err"]

\* tryToLoad: attempts 1 and 2 swallow request errors; a refreshErr ends the run
\* at once (pre-1.0.0 it was retried too: legacy_retries_refresh_failure).
Again(S) == S.res = "err" \/ (S.res = "refreshErr" /\ Mutant = "legacy_retries_refresh_failure")
TryToLoad(Attempt(_, _, _, _), resp, ref, up, S0) ==
  LET A1 == Attempt(resp, ref, up, S0)
      A2 == IF Again(A1) THEN Attempt(resp, ref, up, [A1 EXCEPT !.res = "none", !.why = "none"]) ELSE A1
      A3 == IF Again(A2) THEN Attempt(resp, ref, up, [A2 EXCEPT !.res = "none", !.why = "none"]) ELSE A2
  IN A3

VARIABLE c
Init == c \in [resp : Resps, ref : Refs, tok : {0, 1}, up : BOOLEAN]
Next == UNCHANGED c
Spec == Init /\ [][Next]_c

A == TryToLoad(AuthAttempt,  c.resp, c.ref, c.up, Init0(c.tok))
P == TryToLoad(PlainAttempt, c.resp, c.ref, c.up, Init0(c.tok))

TypeOK == c \in [resp : Resps, ref : Refs, tok : {0, 1}, up : BOOLEAN]
BoundedWork == Len(A.calls) <= 6 /\ A.nref <= 3 /\ Len(P.calls) <= 3
SuccessMeansLastCallOk ==
  /\ (A.res = "ok" => c.resp[Len(A.calls)] = "ok")
  /\ (P.res = "ok" => c.resp[Len(P.calls)] = "ok")
HealthyFirstTry ==
  c.resp[1] = "ok" =>
    /\ A.res = "ok" /\ Len(A.calls) = 1 /\ A.nref = 0
    /\ P.res = "ok" /\ Len(P.calls) = 1
RefreshOnlyAfter401 == (\A i \in 1..6 : c.resp[i] # "e401") => A.nref = 0
PlainNeverRefreshes == P.nref = 0
PlainOkIffSomeOk == (P.res = "ok") <=> (\E i \in 1..3 : c.resp[i] = "ok")
RetryUsesFreshToken == A.stale = 0
CurrentTokenOverridesHeader == A.wrong = 0
\* Every run ends with a verdict and never crashes (no `token!` after refresh).
AlwaysDecides == A.res \in {"ok", "err", "refreshErr"} /\ P.res \in {"ok", "err"}
\* --- 1.0.0 contract ---
\* A failed refresh (throws or leaves no token) is never retried: at most one per run,
\* and it ends the run with unableToRefreshToken.
RefreshFailsAtMostOnce == A.nfail <= 1 /\ (A.nfail = 1 => A.res = "refreshErr")
\* unableToRefreshToken is only reported when the token really could not be renewed.
ErrorLabelHonest == A.res = "refreshErr" => A.why \in {"refresh_failed", "no_token", "still_401"}
\* A resend that is still 401 with the new token is not retried (no 2nd refresh after it).
StillUnauthorizedEnds == A.why = "still_401" => c.resp[Len(A.calls)] = "e401"
\* An upload request always goes through upload(), including the resend after a refresh.
UploadAlwaysUsesUpload ==
  c.up => \A i \in 1..Len(A.kinds) : A.kinds[i] = "upload"
=============================================================================
