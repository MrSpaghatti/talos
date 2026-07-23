.PHONY: build test lint nph

PYTHON ?= python3

build:
	cd talos_core && nimble build -y
	cd talos_agent && nimble build -y
	cd talos_code && nimble build -y

test:
	cd talos_core && nimble test -y 2>&1
	cd talos_agent && nimble test -y 2>&1
	cd talos_code && nimble test -y 2>&1

lint: nph

nph:
	nimpretty --outputDir:src src/talos_core/src/talos_core/*.nim 2>/dev/null || echo "nimpretty not available"
