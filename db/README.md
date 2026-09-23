# Database schemas

One database per service. No service reads another's tables; the only way to data you do not own
is that owner's API or an event it published.

The files here are **copies for reading**. Each service applies its own schema with Flyway when it
starts, so the Postgres containers in `deploy/docker-compose.yml` come up empty and the service
migrates them. That keeps the schema versioned next to the code that depends on it, instead of in
a folder somebody has to remember to run.

| Folder | Service | Owner |
|---|---|---|
| `applicant/` | Applicant Service | Catalin |
| `credential/` | Credential Service | Catalin |
