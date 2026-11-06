# recipes

One `<LG-id>.yaml` per exploitable (instance, profile): the structured, ordered exploit recipe
(preconditions -> steps -> observable) defined in ../README.md. The runtimes trigger for that
instance automates the steps; the scorer references the `observable`. Main only; populated at
injection. `state`-gated instances live here (multi-step DB/session manipulation).
