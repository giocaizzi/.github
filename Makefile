.PHONY: help lint test check audit onboard
.DEFAULT_GOAL := help

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-8s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: ## shellcheck scripts, validate JSON, ruff and mypy --strict on the workflow checker (through uv)
	shellcheck scripts/*.sh
	jq empty standard/*.json
	uvx --quiet ruff@0.17.1 check scripts/workflow.py
	uvx --quiet ruff@0.17.1 format --check scripts/workflow.py
	uv run --quiet --no-project --with mypy==2.4.0 --with ruamel.yaml==0.19.1 mypy --strict scripts/workflow.py

test: ## Smoke-test: the audit script parses, the topic parser reads type and flags, the workflow checker flags what it should (every awk on PATH), the standard workflow copies match
	bash -n scripts/sync.sh
	scripts/test-workflow.sh
	@# Dependabot bumps .github/workflows/ only: a bump here must also land in standard/workflows/ (cp, see docs/runbook-rollout.md)
	for w in pr-title label-guard todo-issues; do cmp standard/workflows/$$w.yml .github/workflows/$$w.yml || exit 1; done
	echo '{"topics":["gis","std-python","std-released","std-exception-agent-ignore"]}' | jq -ef scripts/meta.jq \
	  | jq -e '.type == "python" and .released and (.pypi | not) and .exceptions == ["agent_ignore"]' >/dev/null
	echo '{"topics":["std-go"]}' | jq -ef scripts/meta.jq | jq -e '.type == "go"' >/dev/null
	echo '{"topics":["std-python","std-docs"]}' | jq -ef scripts/meta.jq | jq -e '.type == "unknown"' >/dev/null

check: lint test ## lint + test

audit: ## Report drift (read-only); JSON=1 prints JSON on stdout, text on stderr; VISIBILITY=public|private|all (default all)
	@scripts/sync.sh audit $(if $(JSON),--json) --visibility $(or $(VISIBILITY),all)

onboard: ## Apply the standard to a new repo: make onboard REPO=<name> TYPE=<type> [FLAGS=released,pypi]
	@test -n "$(REPO)" -a -n "$(TYPE)" || { echo "usage: make onboard REPO=<name> TYPE=<type> [FLAGS=released,pypi,deploys]"; exit 2; }
	scripts/sync.sh onboard $(REPO) $(TYPE) $(FLAGS)
