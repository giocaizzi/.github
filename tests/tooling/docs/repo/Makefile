help lint test check:
	@true
# GOBIN=$(CURDIR)/bin go install ... (a comment: never flagged)
tools:
	@# --bin-dir ./bin in a recipe comment
	setup-envtest use --bin-dir $(HOME)/.local/share/envtest 1.31
	curl -sSfL https://example.com/install.sh | sh -s -- -b /usr/local/bin
