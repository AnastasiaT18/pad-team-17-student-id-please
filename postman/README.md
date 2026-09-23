# Postman collections

One collection per pair. Import the `.json` into Postman - the collection-level variables default
to the ports `deploy/docker-compose.yml` publishes, so nothing needs editing for a local run.

| File | Services | Owner |
|---|---|---|
| `pad-team-17-pair2.postman_collection.json` | Applicant, Credential | Catalin |
| `pad-team-17-pair3.postman_collection.json.json` | Server Rules, University Record | Anastasia |

## Running the services first

```bash
cd deploy
cp .env.example .env      # fill in the passwords
docker compose up -d
```

## Pair 2

The requests are ordered so the folder can be run start to finish: creating an applicant stores its
id in a collection variable that the later requests reuse.

Every request asserts that `deception` is absent from the response. That field is the ground-truth
answer to the puzzle the players solve, so a regression that exposes it fails the collection rather
than reaching a demo.
