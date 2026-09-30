# Developer shortcuts. Every target works offline except `tf-init`.
SHELL := /bin/bash
TF ?= $(shell command -v tofu || command -v terraform)
SH_FILES := $(shell git ls-files -co --exclude-standard '*.sh' 'automation/terraform/modules/cloud-init/files/wgctl')

.PHONY: help check test lint style shellcheck fmt tf-init scan-images redact-images

help:
	@echo "make check          run lint, style and every test"
	@echo "make test           run the test scripts only"
	@echo "make lint           shellcheck and terraform fmt"
	@echo "make style          flag em dashes, en dashes and trailing spaces"
	@echo "make scan-images    OCR the screenshots for IPs, OCIDs and secrets"
	@echo "make tf-init        terraform init (needs registry access)"

check: lint style test scan-images

shellcheck:
	shellcheck $(SH_FILES)

fmt:
	$(TF) fmt -recursive automation/terraform

lint: shellcheck
	$(TF) fmt -check -recursive automation/terraform

style:
	python3 tools/check_style.py

test:
	bash tests/test_wgctl.sh
	bash tests/test_verify_vpn.sh
	bash tests/test_ssh_tools.sh
	bash tests/test_cloud_init_render.sh
	bash tests/test_terraform.sh
	python3 tests/test_screenshot_guard.py

tf-init:
	cd automation/terraform && $(TF) init

# Set LITERALS=path to a private file with your real IPs and names (never committed).
scan-images:
	python3 tools/screenshot_guard.py scan docs/images $(if $(LITERALS),--literals $(LITERALS),) --boxes tools/redaction-boxes.json --root docs/images --fast

redact-images:
	python3 tools/screenshot_guard.py redact docs/images $(if $(LITERALS),--literals $(LITERALS),) --boxes tools/redaction-boxes.json --root docs/images
