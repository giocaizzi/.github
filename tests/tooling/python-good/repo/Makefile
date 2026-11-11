.PHONY: help lint test check
help: ## help
	@echo help
lint: ## lint
	uv run ruff check .
	uv run ruff format --check .
	uv run mypy .
test: ## test
	uv run pytest
check: lint test
