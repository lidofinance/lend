# Build with the AST attached, then render API_REFERENCE.md from it.
# The generator reads only solc artifacts and resolves `@inheritdoc` itself, so no `forge doc`.
# --force: a plain `forge build` refreshes the artifacts without the AST, and an incremental
# `--ast` build then skips compilation and leaves them AST-less.
doc:
	@forge build --ast --force
	@python3 tools/gen_api_from_artifacts.py

.PHONY: doc
