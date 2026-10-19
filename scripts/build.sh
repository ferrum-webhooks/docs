#!/usr/bin/env bash
# Build the site into ./site. MkDocs wants its pages in a subfolder, so copy them there first.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf .build_docs && mkdir .build_docs
tar --exclude=.git --exclude=.github --exclude=.build_docs --exclude=site --exclude=scripts --exclude=mkdocs.yml \
    --exclude=requirements.txt --exclude=LICENSE -cf - . | tar -C .build_docs -xf -
mkdocs build --strict
