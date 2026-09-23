# Postman collections

Import the `.json` files into Postman. Each collection's `base_url` variable defaults to the port
`deploy/docker-compose.yml` publishes for that service, so nothing needs editing for a local run.

| File | Service | Port | Owner |
|---|---|---|---|
| `pad-team-17-pair2-applicant.postman_collection.json` | Applicant | 8081 | Catalin |
| `pad-team-17-pair2-credential.postman_collection.json` | Credential | 8082 | Catalin |
| `pad-team-17-pair3.postman_collection.json` | Server Rules, University Record | 8083, 8084 | Anastasia |
| `pad-team-17-pair4-moderation.postman_collection.json` | Moderation | 8085 | Daniela |
| `pad-team-17-pair4-discord-dms.postman_collection.json` | Discord DMs | 8086 | Daniela |

## Running the services first

```bash
cd deploy
cp .env.example .env      # fill in the passwords
docker compose up -d
```

## Applicant and Credential

Each collection runs start to finish on its own: creating an applicant, or a set of credentials,
stores its id in a collection variable that the later requests reuse.

Every request asserts that `deception` is absent from the response. That field is the ground-truth
answer to the puzzle the players solve, so a regression that exposes it fails the collection rather
than reaching a demo.

Session Service is mocked until it exists. Two fixed session ids, already set as collection
variables, make the mock answer `404 SESSION_NOT_FOUND` and `409 SESSION_NOT_ACTIVE`.
