#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

REPO_ROOT=$(dirname "${BASH_SOURCE[0]}")/..

cd $REPO_ROOT
docker run --rm -v ${PWD}:/app -w /app golangci/golangci-lint:v1.56.2 golangci-lint run -v ./pkg/config -v ./pkg/controller -v ./pkg/constants -v ./pkg/container -v ./pkg/controller -v ./pkg/loadbalancer -v ./pkg/provider
