FROM mcr.microsoft.com/mssql/server:2022-latest

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && curl -sSL https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-2022.list -o /etc/apt/sources.list.d/mssql-server-2022.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends mssql-server-fts \
    && apt-get purge -y curl \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*
USER mssql
