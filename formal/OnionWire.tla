---------------------------- MODULE OnionWire ----------------------------
(* Finite model of the pure parts of Sources/Onion: APIClient response     *)
(* validation (commonValidationAndDecode), Request defaults, Paginated     *)
(* query items, BearerToken.httpField and the String header helpers.       *)
(* Abstractions: HTTP status kinds are the enumerated set StatusKinds;     *)
(* decoding is a boolean (does JSONDecoder accept the body); token strings *)
(* are a 2-element set; header strings are tagged tuples, not text.        *)
EXTENDS Naturals

CONSTANTS Mutant   \* "none" for the real semantics, otherwise a seeded bug

StatusKinds == {"informational", "successful", "redirection", "clientError", "serverError"}
Tokens      == {"t0", "t1"}
Nums        == 0..2

\* APIClient.commonValidationAndDecode -> "ok" or "notSuccessStatus"/"decodeError"
Validate(kind, outputIsData, decodes) ==
  IF kind # "successful" /\ ~(Mutant = "accepts_redirect" /\ kind = "redirection")
  THEN "notSuccessStatus"
  ELSE IF outputIsData THEN "ok"
  ELSE IF decodes THEN "ok" ELSE "decodeError"

\* Request protocol extension defaults.
DefaultMethod == "GET"
DefaultAuthNeeded == TRUE

\* Paginated.paginationQueryItems: ordered [limit, offset].
QueryItems(off, lim) ==
  IF Mutant = "swaps_query_items"
  THEN << <<"offset", off>>, <<"limit", lim>> >>
  ELSE << <<"limit", lim>>, <<"offset", off>> >>
DefaultLimit == 20

\* String.bearer / String.basic and BearerToken.httpField.
Bearer(t) == <<"Bearer", t>>
Basic(c)  == <<"Basic", c>>
HttpField(t) == [name |-> "Authorization",
                 value |-> IF Mutant = "basic_scheme" THEN Basic(t) ELSE Bearer(t)]

VARIABLE c
Cfg == [kind : StatusKinds, isData : BOOLEAN, decodes : BOOLEAN,
        off : Nums, lim : Nums, tok : Tokens]
Init == c \in Cfg
Next == UNCHANGED c
Spec == Init /\ [][Next]_c

TypeOK == c \in Cfg
\* Only 2xx responses can succeed; everything else throws notSuccessStatus
\* before any decoding is attempted.
OnlySuccessfulStatusSucceeds ==
  Validate(c.kind, c.isData, c.decodes) = "ok" => c.kind = "successful"
NonSuccessNeverDecodes ==
  c.kind # "successful" => Validate(c.kind, c.isData, c.decodes) = "notSuccessStatus"
\* Raw Data output bypasses the decoder; other outputs need a decodable body.
DataOutputSkipsDecoding ==
  c.kind = "successful" =>
    Validate(c.kind, c.isData, c.decodes) = (IF c.isData \/ c.decodes THEN "ok" ELSE "decodeError")
DefaultsAreGetAndAuthorized == DefaultMethod = "GET" /\ DefaultAuthNeeded
\* Query items are [limit, offset] in that order and carry the exact values.
QueryItemsLimitThenOffset ==
  QueryItems(c.off, c.lim) = << <<"limit", c.lim>>, <<"offset", c.off>> >>
DefaultLimitIs20 == DefaultLimit = 20
\* BearerToken.httpField is Authorization: Bearer <token>.
BearerFieldUsesBearerScheme ==
  /\ HttpField(c.tok).name = "Authorization"
  /\ HttpField(c.tok).value = Bearer(c.tok)
=============================================================================
