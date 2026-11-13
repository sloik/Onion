---------------------------- MODULE OnionRetry ----------------------------
(* Finite model of Sources/Onion/Public/NetworkingHandler.swift:           *)
(* NetworkingHandler.run -> tryToLoad (3 attempts) ->                      *)
(* tryToRunAndRefreshTokenWhenNeeded (401 => refreshToken, one retry).     *)
(* The server is abstracted as a script: resp[i] is the outcome of the     *)
(* i-th apiClient call, ref[j] whether the j-th refreshToken() succeeds.   *)
(* TLC enumerates every script, so each law holds for every behaviour of   *)
(* the server and the login handler. Tokens are naturals (0 = no token);   *)
(* refresh success bumps the token. Header 0 = the request's own header.   *)
EXTENDS Naturals, Sequences

CONSTANTS Mutant   \* "none" for the real semantics, otherwise a seeded bug

Outcomes == {"ok", "e401", "eoth"}
Resps    == [1..6 -> Outcomes]      \* at most 3 attempts x (run + retry) calls
Refs     == [1..3 -> BOOLEAN]       \* at most one refresh per attempt

\* State of the handler while running: next response index, next refresh
\* index, current login token, headers sent, refreshes done, and two
\* counters of calls that carried the wrong Authorization value.
Init0(tok) == [a |-> 1, f |-> 1, tok |-> tok, calls |-> <<>>, nref |-> 0,
               stale |-> 0, wrong |-> 0, res |-> "none"]

\* One apiClient call: record the header, consume a response.
Call(S, hdr) ==
  [S EXCEPT !.a = @ + 1, !.calls = Append(@, hdr)]

\* Outcome of the call just made, given the response script.
Out(resp, S) == resp[S.a - 1]

\* tryToRunAndRefreshTokenWhenNeeded for an authorized request.
AuthAttempt(resp, ref, S0) ==
  LET hdr0 == IF S0.tok # 0 /\ Mutant # "ignores_token" THEN S0.tok ELSE 0
      S1   == Call(S0, hdr0)
      o1   == Out(resp, S1)
      S1w  == [S1 EXCEPT !.wrong = @ + (IF hdr0 # S0.tok /\ S0.tok # 0 THEN 1 ELSE 0)]
      \* 401 branch: refreshToken, then rerun with the new token.
      refOk == ref[S1w.f]
      S2    == [S1w EXCEPT !.f = @ + 1, !.nref = @ + 1]
      newTok == S2.tok + 1
      S3    == [S2 EXCEPT !.tok = newTok]
      hdr3  == IF Mutant = "stale_token" THEN S2.tok ELSE newTok
      S4    == Call(S3, hdr3)
      S4s   == [S4 EXCEPT !.stale = @ + (IF hdr3 # newTok THEN 1 ELSE 0)]
      o4    == Out(resp, S4s)
  IN IF o1 = "ok" THEN [S1w EXCEPT !.res = "ok"]
     ELSE IF o1 = "e401" /\ Mutant = "ok_on_401" THEN [S1w EXCEPT !.res = "ok"]
     ELSE IF o1 = "e401" THEN
            (IF ~refOk THEN [S2 EXCEPT !.res = "err"]   \* wrapped unableToRefreshToken
             ELSE IF o4 = "ok" THEN [S4s EXCEPT !.res = "ok"]
             ELSE [S4s EXCEPT !.res = "err"])           \* retry failure is wrapped, no 2nd refresh
     ELSE [S1w EXCEPT !.res = "err"]

\* Non-authorized request: apiClient.run directly.
PlainAttempt(resp, ref, S0) ==
  LET S1 == Call(S0, 0)
      S2 == IF Mutant = "unauth_refreshes" /\ Out(resp, S1) = "e401"
            THEN [S1 EXCEPT !.f = @ + 1, !.nref = @ + 1] ELSE S1
  IN [S2 EXCEPT !.res = IF Out(resp, S1) = "ok" THEN "ok" ELSE "err"]

\* tryToLoad: attempts 1 and 2 swallow errors; attempt 3 is final.
TryToLoad(Attempt(_, _, _), resp, ref, S0) ==
  LET A1 == Attempt(resp, ref, S0)
      A2 == IF A1.res = "ok" THEN A1 ELSE Attempt(resp, ref, [A1 EXCEPT !.res = "none"])
      A3 == IF A2.res = "ok" THEN A2 ELSE Attempt(resp, ref, [A2 EXCEPT !.res = "none"])
  IN A3

AuthRun(resp, ref, tok)  == TryToLoad(AuthAttempt,  resp, ref, Init0(tok))
PlainRun(resp, ref, tok) == TryToLoad(PlainAttempt, resp, ref, Init0(tok))

VARIABLE c
Init == c \in [resp : Resps, ref : Refs, tok : {0, 1}]
Next == UNCHANGED c
Spec == Init /\ [][Next]_c

A == AuthRun(c.resp, c.ref, c.tok)
P == PlainRun(c.resp, c.ref, c.tok)

TypeOK == c \in [resp : Resps, ref : Refs, tok : {0, 1}]
\* Retry budget: never more than 3 attempts, <= 2 API calls each, <= 1 refresh each.
BoundedWork ==
  Len(A.calls) <= 6 /\ A.nref <= 3 /\ Len(P.calls) <= 3
\* Success means the server's answer to the last call really was ok.
SuccessMeansLastCallOk ==
  /\ (A.res = "ok" => c.resp[Len(A.calls)] = "ok")
  /\ (P.res = "ok" => c.resp[Len(P.calls)] = "ok")
\* A healthy server needs exactly one call and no refresh.
HealthyFirstTry ==
  c.resp[1] = "ok" =>
    /\ A.res = "ok" /\ Len(A.calls) = 1 /\ A.nref = 0
    /\ P.res = "ok" /\ Len(P.calls) = 1
\* refreshToken is only ever called after a 401.
RefreshOnlyAfter401 ==
  (\A i \in 1..6 : c.resp[i] # "e401") => A.nref = 0
\* Requests that do not need a JWT never touch the login handler.
PlainNeverRefreshes == P.nref = 0
\* Plain path succeeds iff one of the 3 attempts is ok.
PlainOkIffSomeOk ==
  (P.res = "ok") <=> (\E i \in 1..3 : c.resp[i] = "ok")
\* After a successful refresh the retried call carries the NEW token.
RetryUsesFreshToken == A.stale = 0
\* A call made with a known token carries that token, not the stale header.
CurrentTokenOverridesHeader == A.wrong = 0
\* Every run terminates with a verdict.
AlwaysDecides == A.res \in {"ok", "err"} /\ P.res \in {"ok", "err"}
=============================================================================
