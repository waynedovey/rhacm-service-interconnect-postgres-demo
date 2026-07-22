REPO_URL ?=
REVISION ?= main

.PHONY: validate bootstrap verify test cleanup

validate:
	./scripts/validate.sh

bootstrap:
	@test -n "$(REPO_URL)" || (echo "Set REPO_URL=https://github.com/ORG/REPO.git" && exit 1)
	./bootstrap.sh --repo-url "$(REPO_URL)" --revision "$(REVISION)"

verify:
	./verify.sh

test:
	./scripts/test-demo.sh

cleanup:
	./cleanup.sh
