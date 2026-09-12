.PHONY: up down build deploy logs ps test lint

up:
	docker compose up -d --build

down:
	docker compose down

build:
	docker compose build

deploy:
	./deploy.sh

logs:
	docker compose logs -f

ps:
	docker compose ps

test:
	cd backend && uv run pytest
	cd frontend && npm run build

lint:
	cd backend && uv run ruff check .
	cd frontend && npm run build
