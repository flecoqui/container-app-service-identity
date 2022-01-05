#!/bin/bash
set -e
PORT=7000
export PORT_HTTP=${PORT}
((PORT=PORT+1))
export PORT_HTTPS=${PORT}
export APP_VERSION=$(date +"%y%M%d.%H%M%S")
echo "PORT_HTTP $PORT_HTTP"
echo "APP_VERSION $APP_VERSION"
echo "ASPNETCORE_URLS $ASPNETCORE_URLS"
dotnet run --urls="http://0.0.0.0:${PORT_HTTP};https://0.0.0.0:${PORT_HTTPS}"
