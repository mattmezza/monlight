# Monlight release tooling
#
# Usage:
#   make release-error-tracker V=0.2.0
#   make release-python V=0.2.0
#   make release-js V=0.2.0
#   make release-all V=0.2.0          # release every component at the same version
#   make versions                      # show current versions of all components
#
# Each release target:
#   1. Validates the version string
#   2. Updates version in the component's source files
#   3. Commits the version bump
#   4. Tags and pushes — CI handles building, publishing, and creating the GitHub Release

.PHONY: help versions release-error-tracker release-log-viewer release-metrics-collector \
        release-browser-relay release-python release-js release-all release-services \
        check-clean check-version

SHELL := /bin/bash

# ─── Validation ──────────────────────────────────────────────────────────────

check-version:
ifndef V
	$(error V is required. Usage: make release-<component> V=x.y.z)
endif
	@if ! echo "$(V)" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
		echo "error: invalid semver '$(V)' — expected X.Y.Z"; exit 1; \
	fi

check-clean:
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "error: working tree is dirty — commit or stash changes first"; \
		git status --short; exit 1; \
	fi

# ─── Version display ────────────────────────────────────────────────────────

versions:
	@echo "error-tracker      $$(grep -oP '\.version\s*=\s*"\K[^"]+' error-tracker/build.zig.zon)"
	@echo "log-viewer         $$(grep -oP '\.version\s*=\s*"\K[^"]+' log-viewer/build.zig.zon)"
	@echo "metrics-collector  $$(grep -oP '\.version\s*=\s*"\K[^"]+' metrics-collector/build.zig.zon)"
	@echo "browser-relay      $$(grep -oP '\.version\s*=\s*"\K[^"]+' browser-relay/build.zig.zon)"
	@echo "python (monlight)  $$(grep -oP '^version\s*=\s*"\K[^"]+' clients/python/pyproject.toml)"
	@echo "js (@monlight/browser)  $$(node -p "require('./clients/js/package.json').version")"

# ─── Zig service releases ───────────────────────────────────────────────────

define release-zig-service
release-$(1): check-version check-clean
	@echo "==> Releasing $(1) v$(V)"
	@# Update version in build.zig.zon
	@sed -i 's/\.version = ".*"/\.version = "$(V)"/' $(1)/build.zig.zon
	@# Commit, tag, push
	git add $(1)/build.zig.zon
	git commit -m "release: $(1) v$(V)"
	git tag $(1)-v$(V)
	git push origin main $(1)-v$(V)
	@echo "==> $(1) v$(V) tagged and pushed — CI will build and publish to GHCR"
endef

$(eval $(call release-zig-service,error-tracker))
$(eval $(call release-zig-service,log-viewer))
$(eval $(call release-zig-service,metrics-collector))
$(eval $(call release-zig-service,browser-relay))

# ─── Python release ─────────────────────────────────────────────────────────

release-python: check-version check-clean
	@echo "==> Releasing monlight (Python) v$(V)"
	@# Update version in pyproject.toml
	@sed -i 's/^version = ".*"/version = "$(V)"/' clients/python/pyproject.toml
	@# Update version in __init__.py
	@sed -i 's/__version__ = ".*"/__version__ = "$(V)"/' clients/python/monlight/__init__.py
	@# Commit, tag, push
	git add clients/python/pyproject.toml clients/python/monlight/__init__.py
	git commit -m "release: monlight (python) v$(V)"
	git tag python-v$(V)
	git push origin main python-v$(V)
	@echo "==> monlight v$(V) tagged and pushed — CI will publish to PyPI"

# ─── JS release ─────────────────────────────────────────────────────────────

release-js: check-version check-clean
	@echo "==> Releasing @monlight/browser v$(V)"
	@# Update version in package.json (without npm lifecycle scripts)
	@cd clients/js && npm version $(V) --no-git-tag-version
	@# Commit, tag, push
	git add clients/js/package.json clients/js/package-lock.json
	git commit -m "release: @monlight/browser v$(V)"
	git tag js-v$(V)
	git push origin main js-v$(V)
	@echo "==> @monlight/browser v$(V) tagged and pushed — CI will publish to npm"

# ─── Batch releases ─────────────────────────────────────────────────────────

release-services: check-version check-clean
	@echo "==> Releasing all 4 Zig services at v$(V)"
	@sed -i 's/\.version = ".*"/\.version = "$(V)"/' \
		error-tracker/build.zig.zon \
		log-viewer/build.zig.zon \
		metrics-collector/build.zig.zon \
		browser-relay/build.zig.zon
	git add \
		error-tracker/build.zig.zon \
		log-viewer/build.zig.zon \
		metrics-collector/build.zig.zon \
		browser-relay/build.zig.zon
	git commit -m "release: all services v$(V)"
	git tag error-tracker-v$(V)
	git tag log-viewer-v$(V)
	git tag metrics-collector-v$(V)
	git tag browser-relay-v$(V)
	git push origin main \
		error-tracker-v$(V) \
		log-viewer-v$(V) \
		metrics-collector-v$(V) \
		browser-relay-v$(V)
	@echo "==> All 4 services tagged at v$(V) and pushed — CI will build and publish to GHCR"

release-all: check-version check-clean
	@echo "==> Releasing everything at v$(V)"
	@# Bump all version files
	@sed -i 's/\.version = ".*"/\.version = "$(V)"/' \
		error-tracker/build.zig.zon \
		log-viewer/build.zig.zon \
		metrics-collector/build.zig.zon \
		browser-relay/build.zig.zon
	@sed -i 's/^version = ".*"/version = "$(V)"/' clients/python/pyproject.toml
	@sed -i 's/__version__ = ".*"/__version__ = "$(V)"/' clients/python/monlight/__init__.py
	@cd clients/js && npm version $(V) --no-git-tag-version
	@# Single commit with all version bumps
	git add \
		error-tracker/build.zig.zon \
		log-viewer/build.zig.zon \
		metrics-collector/build.zig.zon \
		browser-relay/build.zig.zon \
		clients/python/pyproject.toml \
		clients/python/monlight/__init__.py \
		clients/js/package.json \
		clients/js/package-lock.json
	git commit -m "release: v$(V) (all components)"
	git tag error-tracker-v$(V)
	git tag log-viewer-v$(V)
	git tag metrics-collector-v$(V)
	git tag browser-relay-v$(V)
	git tag python-v$(V)
	git tag js-v$(V)
	git push origin main \
		error-tracker-v$(V) \
		log-viewer-v$(V) \
		metrics-collector-v$(V) \
		browser-relay-v$(V) \
		python-v$(V) \
		js-v$(V)
	@echo "==> All components tagged at v$(V) and pushed"
	@echo "    CI will publish: 4 Docker images to GHCR, Python to PyPI, JS to npm"

# ─── Help ────────────────────────────────────────────────────────────────────

help:
	@echo "Monlight release targets"
	@echo ""
	@echo "  make versions                     Show current versions"
	@echo ""
	@echo "  make release-error-tracker V=x.y.z"
	@echo "  make release-log-viewer V=x.y.z"
	@echo "  make release-metrics-collector V=x.y.z"
	@echo "  make release-browser-relay V=x.y.z"
	@echo "  make release-python V=x.y.z"
	@echo "  make release-js V=x.y.z"
	@echo ""
	@echo "  make release-services V=x.y.z     Release all 4 Docker services"
	@echo "  make release-all V=x.y.z          Release everything (services + clients)"
	@echo ""
	@echo "Each target bumps versions, commits, tags, and pushes."
	@echo "CI handles building, publishing, and creating GitHub Releases."
