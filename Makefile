# For convenience, add the following to your aliases:
# `function f() { make forge ARGS="$*"; }`

forge:
	@FOUNDRY_PROFILE=no_via_ir forge $(ARGS)

# Build with the AST attached, then render the "API Reference" section of SPECIFICATION.md from it.
# The generator reads only solc artifacts and resolves `@inheritdoc` itself, so no `forge doc`.
# --force: a plain `forge build` refreshes the artifacts without the AST, and an incremental
# `--ast` build then skips compilation and leaves them AST-less.
doc:
	@FOUNDRY_PROFILE=no_via_ir forge build --ast --force
	@python3 tools/gen_api_from_artifacts.py

.PHONY: forge doc
