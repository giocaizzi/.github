help:
	@echo
tools:
	GOBIN=$(CURDIR)/bin go install golang.org/x/tools/cmd/stringer@v0.30.0
	curl -sSfL https://example.com/install.sh | sh -s -- -b ./bin v1.64.0
	uvx setup-envtest use --bin-dir ./.envtest 1.31
lint:
	golangci-lint run
test:
	go test ./...
check: lint test
