.PHONY: help lint test check audit onboard
.DEFAULT_GOAL := help

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-8s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: ## shellcheck scripts, validate JSON
	shellcheck scripts/*.sh
	jq empty standard/*.json

test: ## Smoke-test: the audit script and standard/repos.yaml parse
	bash -n scripts/sync.sh
	grep -E '^- \{' standard/repos.yaml | sed -E 's/^- //; s/([A-Za-z0-9_.-]+)/"\1"/g' \
	  | jq -se 'all(.[]; (.type | IN("python","typescript","infra","config","docs")) and (.released | IN("true","false")))' >/dev/null

check: lint test ## lint + test

audit: ## Report drift of all repos (read-only); JSON=1 prints JSON on stdout, text on stderr
	@scripts/sync.sh audit $(if $(JSON),--json)

onboard: ## Apply the standard to a new repo: make onboard REPO=<name>
	@test -n "$(REPO)" || { echo "usage: make onboard REPO=<name>"; exit 2; }
	scripts/sync.sh onboard $(REPO)
