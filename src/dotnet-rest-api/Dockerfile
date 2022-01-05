ARG ARG_PORT_HTTP=8000
ARG ARG_APP_VERSION="1.0.0.1"
# stage 1
FROM mcr.microsoft.com/dotnet/sdk:6.0  AS build-image

WORKDIR /app
COPY ./*.json ./
COPY ./*.csproj ./
COPY ./*.cs ./
RUN dotnet restore
RUN dotnet publish --self-contained -r linux-x64 -c Release -o out

# stage 2
FROM mcr.microsoft.com/dotnet/aspnet:6.0  AS release-image
ARG ARG_PORT_HTTP
ENV PORT_HTTP ${ARG_PORT_HTTP}

ARG ARG_APP_VERSION
ENV APP_VERSION=${ARG_APP_VERSION}

WORKDIR /app

COPY --from=build-image ./app/out ./
COPY ./entrypoint.sh ./
EXPOSE $PORT_HTTP/tcp

CMD ["./entrypoint.sh"]
