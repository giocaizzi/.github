.PHONY: help lint test check audit onboard
.DEFAULT_GOAL := help

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-8s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: ## shellcheck scripts, validate JSON
	shellcheck scripts/*.sh
	jq empty standard/*.json

test: ## Smoke-test: the audit script parses, the topic parser reads type and flags
	bash -n scripts/sync.sh
	echo '{"topics":["gis","std-python","std-released","std-exception-agent-ignore"]}' | jq -ef scripts/meta.jq \
	  | jq -e '.type == "python" and .released and (.pypi | not) and .exceptions == ["agent_ignore"]' >/dev/null
	echo '{"topics":["std-python","std-docs"]}' | jq -ef scripts/meta.jq | jq -e '.type == "unknown"' >/dev/null

check: lint test ## lint + test

audit: ## Report drift (read-only); JSON=1 prints JSON on stdout, text on stderr; VISIBILITY=public|private|all (default all)
	@scripts/sync.sh audit $(if $(JSON),--json) --visibility $(or $(VISIBILITY),all)

onboard: ## Apply the standard to a new repo: make onboard REPO=<name> TYPE=<type> [FLAGS=released,pypi]
	@test -n "$(REPO)" -a -n "$(TYPE)" || { echo "usage: make onboard REPO=<name> TYPE=<type> [FLAGS=released,pypi,deploys]"; exit 2; }
	scripts/sync.sh onboard $(REPO) $(TYPE) $(FLAGS)
