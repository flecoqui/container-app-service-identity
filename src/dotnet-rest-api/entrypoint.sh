#!/bin/bash
set -e
./dotnet-rest-api  --urls="http://0.0.0.0:${PORT_HTTP}"
