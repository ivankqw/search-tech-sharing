COMPOSE?=docker compose
SERVICE?=sqlserver
SQLCMD?=/opt/mssql-tools18/bin/sqlcmd
SA_PASSWORD?=Your_password123

.PHONY: up down logs wait seed fts test init all

up:
	$(COMPOSE) up -d $(SERVICE)

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f $(SERVICE)

wait:
	$(COMPOSE) exec -T $(SERVICE) bash -c "/scripts/wait_for_sql.sh localhost,1433 SA $(SA_PASSWORD) 180"

seed:
	$(COMPOSE) exec -T $(SERVICE) $(SQLCMD) -C -S localhost -U SA -P $(SA_PASSWORD) -v SeedSynthetic=1 -i /scripts/setup_database.sql

schema:
	$(COMPOSE) exec -T $(SERVICE) $(SQLCMD) -C -S localhost -U SA -P $(SA_PASSWORD) -v SeedSynthetic=0 -i /scripts/setup_database.sql

fts:
	$(COMPOSE) exec -T $(SERVICE) $(SQLCMD) -C -S localhost -U SA -P $(SA_PASSWORD) -i /scripts/create_fulltext.sql

load_csv:
	$(COMPOSE) exec -T $(SERVICE) $(SQLCMD) -C -S localhost -U SA -P $(SA_PASSWORD) -d SearchDemo -i /scripts/load_companies_from_csv.sql

test:
	$(COMPOSE) exec -T $(SERVICE) $(SQLCMD) -C -S localhost -U SA -P $(SA_PASSWORD) -d SearchDemo -b -i /scripts/test_fulltext.sql

init: up wait seed fts

all: init test
