# Rendered by Terraform — Metabase + Postgres on a single ECS.
# Postgres lives in an `internal: true` Docker network and never publishes
# port 5432 → unreachable from outside the host.
services:
  postgres:
    image: postgres:16-alpine
    container_name: metabase-postgres
    restart: unless-stopped
    networks: [internal]
    environment:
      POSTGRES_DB: metabase
      POSTGRES_USER: metabase
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets:
      - db_password
    volumes:
      - pg_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U metabase -d metabase"]
      interval: 10s
      timeout: 5s
      retries: 10

  metabase:
    image: metabase/metabase:${metabase_tag}
    container_name: metabase
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    networks: [internal, public]
    ports:
      - "3000:3000"            # only Metabase exposed; Postgres stays inside `internal`
    environment:
      MB_DB_TYPE: postgres
      MB_DB_DBNAME: metabase
      MB_DB_HOST: postgres
      MB_DB_PORT: "5432"
      MB_DB_USER: metabase
      MB_DB_PASS_FILE: /run/secrets/db_password
      JAVA_TIMEZONE: Asia/Bangkok
    secrets:
      - db_password
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:3000/api/health"]
      interval: 15s
      timeout: 5s
      start_period: 90s
      retries: 20

networks:
  internal:
    driver: bridge
    internal: true            # DB network has NO route to the host / outside
  public:
    driver: bridge

volumes:
  pg_data:                    # persisted under /var/lib/docker/volumes (= EVS mount)

secrets:
  db_password:
    file: /opt/metabase/.secrets/db_password
