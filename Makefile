.PHONY: help lint test check audit
.DEFAULT_GOAL := help

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-8s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: ## shellcheck scripts, validate JSON
	shellcheck scripts/*.sh
	jq empty standard/*.json

test: ## Smoke-test: the audit script parses its own standard
	bash -n scripts/sync.sh

check: lint test ## lint + test

audit: ## Report drift of all repos against the standard (read-only)
	scripts/sync.sh audit
