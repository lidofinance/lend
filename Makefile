# For convenience, add the following to your aliases:
# `function f() { make forge ARGS="$*"; }`

forge:
	@FOUNDRY_PROFILE=no_via_ir forge $(ARGS)

# Build with the AST attached, then render the "API Reference" section of SPECIFICATION.md from it.
# The generator reads only solc artifacts and resolves `@inheritdoc` itself, so no `forge doc`.
doc:
	@FOUNDRY_PROFILE=no_via_ir forge build --ast
	@python3 tools/gen_api_from_artifacts.py

.PHONY: forge doc
