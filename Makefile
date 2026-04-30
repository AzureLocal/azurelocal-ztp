# Makefile for common development tasks

.PHONY: help setup test lint clean build deploy docs

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup: ## Set up development environment
	@echo "Setting up development environment..."
	# Add setup commands here

test: ## Run all tests
	@echo "Running tests..."
	# Add test commands here

lint: ## Run linting
	@echo "Running linters..."
	# Add lint commands here

clean: ## Clean build artifacts
	@echo "Cleaning..."
	rm -rf build/
	rm -rf dist/
	rm -rf .terraform/

build: ## Build the project
	@echo "Building..."
	# Add build commands here

deploy: ## Deploy to development environment
	@echo "Deploying to dev..."
	# Add deployment commands here

docs: ## Build documentation
	@echo "Building docs..."
	asciidoctor docs/*.adoc -D docs/build/

validate: ## Validate all IaC
	@echo "Validating IaC..."
	# Add validation commands here