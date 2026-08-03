Golden files for the corpus tests.

Excluded from the test target in `Package.swift` rather than declared as
resources: the tests read these through `#filePath` so they can rewrite them in
place under `REGENERATE_GOLDENS=1`, which a copied resource bundle could not do.
