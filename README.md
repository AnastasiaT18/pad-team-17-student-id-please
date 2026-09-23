# Student ID, please

A cooperative game about Discord server moderation, built as a microservices project for the PAD course. A team of players runs moderation "shifts" for a university Discord server — one 
Moderator reviews applicants directly, while several Junior Moderators consult scattered university records and credentials to help verify who's really who, before a decision 
(Accept / Reject / Flag / Ban) gets made and checked against the current access rules.

The system is split into 8 microservices, each owning a distinct piece of the game's state — see the boundaries and diagram below.

## Team 17
- Anastasia Tiganescu, FAF-231 — Server Rules + University Record Services
- Catalin Darzu, FAF-231  — Applicant and Credential Services
- Daniela Cojocari, FAF-231  — Moderation + Discord DMS Services
- Janeta Grigoras, FAF-231  — Player + Server Moderation Session Services

---

## Service Boundaries

### Player Service
Owns the identity of the players themselves — accounts, authentication, profiles, friends, XP/levels, and their progression history as moderators, including shifts completed and 
disciplinary actions taken. 

It does not contain any data about the people attempting to join the university server — that responsibility belongs entirely to the applicant-side services 
below. At the end of a shift, it receives the results from the Server Moderation Session Service to update a player's XP and level.

### Server Moderation Session Service
Owns the state of an active moderation shift: which players are in it, their assigned roles (Moderator vs Junior Moderators), the applicant currently being reviewed, how many applications
have been processed, and the running session score and penalties. 

It does not own applicant, credential, or record data, nor the decision logic itself — it only orchestrates the shift. 
It calls the Applicant Service to advance to the next applicant, provisions channels through the Discord DMs Service, and publishes the shift's final results to the Player Service once it ends.

### Applicant Service
Owns an applicant's basic identity — name, student ID, major, year, university status, courses, and role — including cases where an applicant intentionally provides false information. 

It does not own the applicant's credentials or the hidden university records, only references to them. Whichever of Applicant Service, Credential Service, or University Record Service is 
contacted first for a new applicant initializes that applicant's profile and propagates it to the other two, so all three stay in sync.

### Credential Service
Owns the documents an applicant presents — student ID, university email, enrollment confirmation, course registration — and determines their validity, flagging anything expired, forged,
inconsistent, or incomplete. 

It validates structure and authenticity only; it does not decide whether the applicant should actually be admitted. It participates in the same first-contact propagation pattern as Applicant
Service, syncing with both Applicant Service and University Record Service whenever a new applicant appears.

### Server Rules Service
Owns the current access rule set for the Discord server — for example, "only FAF students may join," "first-years can't access certain channels," or "banned students can never re-enter" — 
along with the logic to evaluate an applicant against it. 

It does not store applicant data itself; it's simply handed what it needs, per request, to run that evaluation. It supplies the correctness check the Moderation Service relies on when 
finalizing a decision.

### University Record Service
Owns the hidden, ground-truth university data moderators may need to verify a claim — enrollment lists, course lists, academic year, schedules, and server message records. This information 
is deliberately partitioned across the Junior Moderator players, so a given player can only see the records they've been assigned, never the full picture. It also participates in the 
first-contact propagation pattern, syncing with Applicant Service and Credential Service whenever a new applicant is created.

### Moderation Service
Owns the actual admission decision for each applicant — Accept, Reject, Flag, or Ban — along with whether that decision was correct and the resulting record of violated rules and penalties.

It does not own the rules themselves, nor any raw applicant, credential, or record data — only the outcome of applying them. To reach a decision, it gathers information from the Applicant, 
Credential, and University Record Services, then checks correctness against the Server Rules Service.

### Discord DMs Service
Provides the real-time, Discord-like communication between the Moderator and Junior Moderators, organized into channels tied to the active session (e.g. #enrollment-check, #faculty-check,
#general-mod-chat). Different players have access to different channels depending on what information they've been assigned. 

It transports messages only — it never verifies whether what's being said is actually correct. It relies on the Server Moderation Session Service to know which channels should exist for 
the current session.

## Architecture Diagram

![Architecture diagram](architecture_diagram.svg)

Arrows point from the service that initiates a call to the service it calls.

New applicants can enter through any of Applicant Service, Credential Service or
University Record Service. Whichever is contacted first mints the `applicant_id`,
decides that applicant's `deception`, and publishes its `*_initialized` event; the
other two build their own side of the applicant from it. All three end up describing
the same person, and the deception stays consistent across claim, documents and
records because it is decided once, at the point of entry.

Moderation Service is the only service that reaches into the applicant-data cluster 
after an applicant already exists — it queries Applicant, Credential, and University 
Record Services to gather what it needs before checking the decision against Server Rules.

---

## Technologies and Communication Patterns

### Languages

Two halves, two languages.

**TypeScript / NestJS — Player, Session, Moderation, Discord DMs.**
This half holds live connections: 4 players connected for the whole shift, mostly idle.
Node handles many idle sockets cheaply, and Socket.IO rooms map 1:1 onto Discord channels,
so we don't write socket plumbing. Session and Moderation sit here because score updates and
decision results must reach connected players immediately.
Trade-off: types vanish at runtime, so DTOs are validated with `class-validator` at the edge.

**Java 21 / Spring Boot — Applicant, Credential, Server Rules, University Record.**
This half is data modelling and rule evaluation: claim vs truth, document validity, partitioned
records, rule predicates. Static types, Bean Validation and JPA catch bad state at compile or
validation time instead of during a demo.
Trade-off: heavier services and slower startup — acceptable, since nothing here holds a live connection.

**Pinned:** JDK 21 LTS, Node 24 LTS.

| Service | Pair | Stack | DB |
|---|---|---|---|
| Player | 1 | TypeScript · NestJS | PostgreSQL |
| Server Moderation Session | 1 | TypeScript · NestJS | PostgreSQL |
| Applicant | 2 | Java 21 · Spring Boot, JPA | PostgreSQL |
| Credential | 2 | Java 21 · Spring Boot, JPA | PostgreSQL |
| Server Rules | 3 | Java 21 · Spring Boot | PostgreSQL (rule sets only) |
| University Record | 3 | Java 21 · Spring Boot, JPA | PostgreSQL |
| Moderation | 4 | TypeScript · NestJS | PostgreSQL |
| Discord DMs | 4 | TypeScript · NestJS, Socket.IO | PostgreSQL |

### Communication

| Direction | Protocol | Why |
|---|---|---|
| Client → system | REST + JSON via API gateway | Discrete actions (login, join shift, query record, submit verdict). One place to check the JWT. |
| Client → Discord DMs | WebSocket (Socket.IO) | Chat must be pushed, not polled. |
| Service → service, needs an answer | gRPC | Moderation makes 4 calls (Applicant, Credential, Record, Rules) before answering. The `.proto` is one contract both languages generate from, so Java and TS can't drift. |
| Service → service, fire and forget | RabbitMQ events | `applicant_initialized`, `decision_made`, `shift_ended`. Publisher doesn't wait; a consumer being down doesn't fail the shift. |

### Data management

One database per service. No service reads another's tables — only its API or its events.

Applicant, Credential and University Record hold the same applicant in three databases. Whichever
of the three is contacted first mints the `applicant_id` and the `deception`, then publishes its
`*_initialized` event; the other two build their own side from it. Consumers are idempotent on
`applicant_id`, so a redelivery can't duplicate data, and an applicant is initialized only once no
matter how many of the three events arrive.

Consistency is eventual — acceptable here, since an applicant is only shown to the Moderator after
the session advances to them.

### Conventions

| Thing | Decision |
|---|---|
| Auth | `Authorization: Bearer <JWT>` |
| IDs | UUID v4, as string |
| Timestamps | RFC 3339 UTC — `2026-09-15T14:03:00Z` |
| Errors | `{ "error": { "code": "STRING_CODE", "message": "human text" } }` |
| JSON | `snake_case` |
| Paths | plural — `/applicants/{applicant_id}` |

---
## Communication Contract

Data lives in one database per service. Services never touch each other's tables, only their APIs and events, as described above.

### Player Service

**Client-facing REST (via API Gateway)**

`POST /players` - register a new player account
```json
// Request
{ "username": "string", "email": "string", "password": "string" }

// Response 201
{ "player_id": "uuid", "username": "string", "email": "string", "xp": 0, "level": 1, "created_at": "RFC3339" }
```

**Errors:** `422 VALIDATION_FAILED` if username, email, or password is missing or malformed, `409 EMAIL_ALREADY_REGISTERED` if the email is already in use.

`POST /players/login` - authenticate
```json
// Request
{ "email": "string", "password": "string" }

// Response 200
{ "player_id": "uuid", "token": "jwt string" }
```

**Errors:** `401 INVALID_CREDENTIALS` if the email/password combination is wrong.


`GET /players/{player_id}` - fetch profile
```json
// Response 200
{
  "player_id": "uuid",
  "username": "string",
  "xp": 0,
  "level": 1,
  "friends": ["uuid"],
  "shifts_completed": 0,
  "disciplinary_actions": 0
}
```

**Errors:** `404 PLAYER_NOT_FOUND`.


`PATCH /players/{player_id}` - update profile fields
```json
// Request (any subset)
{ "username": "string", "email": "string" }

// Response 200
{
  "player_id": "uuid",
  "username": "string",
  "xp": 0,
  "level": 1,
  "friends": ["uuid"],
  "shifts_completed": 0,
  "disciplinary_actions": 0
}
```

**Errors:** `422 VALIDATION_FAILED` if a field is malformed, `403 FORBIDDEN` if the caller isn't this player, `404 PLAYER_NOT_FOUND`.


`GET /players/{player_id}/friends` - list a player's friends
```json
// Response 200
{ "friends": [ { "player_id": "uuid", "username": "string" } ] }
```

**Errors:** `404 PLAYER_NOT_FOUND`.


`POST /players/{player_id}/friends` - add another player as a friend
```json
// Request
{ "friend_id": "uuid" }

// Response 200
{ "friends": [ { "player_id": "uuid", "username": "string" } ] }
```

**Errors:** `404 PLAYER_NOT_FOUND` if `friend_id` doesn't exist, `409 ALREADY_FRIENDS` if the friendship already exists.


**Events consumed (RabbitMQ)**

`shift_ended` - published by Session Service when a shift ends.
```json
{
  "session_id": "uuid",
  "results": [
    { "player_id": "uuid", "xp_gained": 0, "shift_completed": true, "disciplinary_action": false }
  ]
}
```
Applied per `player_id` to update `xp`, `level`, `shifts_completed`, `disciplinary_actions`.
Idempotent on `(session_id, player_id)`.

---

### Server Moderation Session Service

**Client-facing REST (via API Gateway)**

`POST /sessions` - create a session
```json
// Response 201
{ "session_id": "uuid", "status": "created", "roles": { "moderator": "uuid", "junior_moderators": ["uuid"] } }
```

**Errors:** `422 VALIDATION_FAILED` if the request is malformed.


`POST /sessions/{session_id}/join` - the calling player (identified via JWT) joins an existing, not-yet-started session as Junior Moderator
```json
// Response 200
{ "session_id": "uuid", "status": "created", "roles": { "moderator": "uuid", "junior_moderators": ["uuid"] } }
```

**Errors:** `404 SESSION_NOT_FOUND`, `409 SESSION_ALREADY_STARTED` if the session is no longer in `created` status, `409 ALREADY_JOINED` if the calling player is already in this session.


`POST /sessions/{session_id}/start` - mark the session active, start the shift, and assign each Junior Moderator the record scope(s) they'll have access to for the whole shift (via
`UniversityRecordService.AssignScopes`, below).
```json
// Response 200
{ "session_id": "uuid", "status": "active", "started_at": "RFC3339" }
```

**Errors:** `403 NOT_MODERATOR` if the caller isn't the session's Moderator, `409 SESSION_ALREADY_STARTED` if it's already active or ended.


`GET /sessions/{session_id}` - full state
```json
// Response 200
{
  "session_id": "uuid",
  "status": "created | active | ended",
  "roles": { "moderator": "uuid", "junior_moderators": ["uuid"] },
  "current_applicant_id": "uuid | null",
  "processed_count": 0,
  "score": 0,
  "started_at": "RFC3339 | null",
  "ended_at": "RFC3339 | null"
}
```

**Errors:** `404 SESSION_NOT_FOUND`.


`GET /sessions/{session_id}/current-applicant` - the applicant currently under review
```json
// Response 200
{ "applicant_id": "uuid | null", "processed_count": 0 }
```

**Errors:** `404 SESSION_NOT_FOUND`.


`POST /sessions/{session_id}/end` - end the shift and finalize results
```json
// Response 200
{
  "session_id": "uuid",
  "status": "ended",
  "final_score": 0,
  "results": [ { "player_id": "uuid", "xp_gained": 0, "shift_completed": true, "disciplinary_action": false } ]
}
```

**Errors:** `403 NOT_MODERATOR` if the caller isn't the session's Moderator, `409 SESSION_NOT_ACTIVE` if the session isn't currently active.

Triggers publishing `shift_ended` (below).

**Outgoing gRPC calls (needs an answer)**

`ApplicantService.GetNextApplicant`
```proto
rpc GetNextApplicant (NextApplicantRequest) returns (NextApplicantResponse);
message NextApplicantRequest { string session_id = 1; }
message NextApplicantResponse { string applicant_id = 1; }
```

`DiscordDmsService.ProvisionChannels`
```proto
rpc ProvisionChannels (ProvisionChannelsRequest) returns (ProvisionChannelsResponse);
message ProvisionChannelsRequest {
  string session_id = 1;
  repeated string participant_ids = 2;
}
message ProvisionChannelsResponse { repeated Channel channels = 1; }
message Channel { string channel_id = 1; string name = 2; }
```

`UniversityRecordService.AssignScopes`
```proto
rpc AssignScopes (AssignScopesRequest) returns (AssignScopesResponse);
message AssignScopesRequest {
  string session_id = 1;
  repeated PlayerScopeAssignment assignments = 2;
}
message PlayerScopeAssignment {
  string player_id = 1;
  repeated string scopes = 2; // enrollment | courses | schedule | messages
}
message AssignScopesResponse { bool success = 1; }
```

**Events published (RabbitMQ)**

`shift_ended` - published when a shift ends.
```json
{
  "session_id": "uuid",
  "results": [
    { "player_id": "uuid", "xp_gained": 0, "shift_completed": true, "disciplinary_action": false }
  ]
}
```

**Events consumed (RabbitMQ)**

`decision_made` - published by Moderation Service after each verdict.
```json
{
  "session_id": "uuid",
  "applicant_id": "uuid",
  "verdict": "accept | reject | flag | ban",
  "correct": true,
  "penalty": 0
}
```
Applied to update `score`, `processed_count`, clear `current_applicant_id`, and trigger the next
`GetNextApplicant` call.

### Applicant Service

**Client-facing REST (via API Gateway)**

`POST /applicants` - generate a new applicant profile for a moderation session
```json
// Request
{ "session_id": "uuid" }

// Response 201
{
  "applicant_id": "uuid",
  "name": "string",
  "student_id": "string",
  "major": "string",
  "year": 0,
  "university_status": "faf_student | other_major | teaching_assistant | staff | alumni | outsider",
  "courses": ["string"],
  "role": "string"
}
```
`deception` is stored internally and travels between the three applicant-side services over
RabbitMQ, but it is never returned in any player-facing response, and it is not part of any gRPC
message either — not even the one Moderation Service calls. It is the ground-truth answer the game
is built around: a player who could read it would have nothing left to investigate, and a player
who could infer it from what Moderation returns before submitting a verdict would have the same
advantage. Correctness is decided by Server Rules Service from the claim, the documents and the
records — never from `deception` itself.


**Errors:** `422 VALIDATION_FAILED` if `session_id` is missing, `400 VALIDATION_FAILED` if the body
is not valid JSON, `404 SESSION_NOT_FOUND` if the session does not exist, `409 SESSION_NOT_ACTIVE` if
it is not running. The session check is served by a mock until Server Moderation Session Service
exists - see "Running this service" below.

`GET /applicants/{applicant_id}` - fetch an applicant's profile
```json
// Response 200
{
  "applicant_id": "uuid",
  "name": "string",
  "student_id": "string",
  "major": "string",
  "year": 0,
  "university_status": "faf_student | other_major | teaching_assistant | staff | alumni | outsider",
  "courses": ["string"],
  "role": "string"
}
```

**Errors:** `400 VALIDATION_FAILED` if the id is not a UUID, `404 APPLICANT_NOT_FOUND`.

`GET /applicants?session_id={session_id}` - every applicant, or only those of one shift, oldest first
```json
// Response 200
[ { "applicant_id": "uuid", "name": "string", "student_id": "string", "...": "as above" } ]
```

`PATCH /applicants/{applicant_id}` - the applicant amends their claim

Any subset of the claimed fields; whatever is left out stays as it was. Only the claim moves:
`student_id` is the card the applicant is holding and `deception` is what the documents and records
were generated from, so neither can be rewritten. The documents and records keep describing what
the applicant presented on arrival, which is what makes a changed story suspicious. Nothing is
published - the claim is Applicant Service's alone.
```json
// Request - every field optional
{
  "name": "string",
  "major": "string",
  "year": 1,
  "university_status": "faf_student | other_major | teaching_assistant | staff | alumni | outsider",
  "courses": ["string"],
  "role": "string"
}

// Response 200 - the amended profile, same shape as GET
```
**Errors:** `422 VALIDATION_FAILED` if no field is given, if `year` is outside 1-6, if a text field is
blank, or if the body tries to change `student_id`, `applicant_id` or `session_id`;
`400 VALIDATION_FAILED` if the body is not valid JSON; `404 APPLICANT_NOT_FOUND`;
`409 SESSION_NOT_ACTIVE` if the applicant's shift is no longer running.

`DELETE /applicants/{applicant_id}` - removes the applicant
```json
// Response 204 - no body
```
**Errors:** `400 VALIDATION_FAILED` if the id is not a UUID, `404 APPLICANT_NOT_FOUND`.

**Incoming gRPC**

`ApplicantService.GetNextApplicant` - called by Server Moderation Session Service to advance a
shift to its next applicant. Generates the applicant if the session has none pending.

```proto
rpc GetNextApplicant (NextApplicantRequest) returns (NextApplicantResponse);

message NextApplicantRequest { string session_id = 1; }

message NextApplicantResponse { string applicant_id = 1; }
```

`ApplicantService.GetApplicant` - returns the applicant's claimed profile so Moderation can check a
decision against the rules. Server-to-server, so it does not pass through the API Gateway.
`deception` is not part of the message.

```proto
rpc GetApplicant (GetApplicantRequest) returns (Applicant);

message GetApplicantRequest { string applicant_id = 1; }

message Applicant {
  string applicant_id = 1;
  string name = 2;
  string student_id = 3;
  string major = 4;
  int32 year = 5;
  string university_status = 6;
  repeated string courses = 7;
  string role = 8;
}
```


**Events published (RabbitMQ)**

`applicant_initialized` - published when Applicant Service is contacted first for a new applicant.
```json
{
  "applicant_id": "uuid",
  "deception": "none | false_major | false_year | impersonation | expired_status",
  "name": "string",
  "student_id": "string",
  "major": "string",
  "year": 0,
  "university_status": "faf_student | other_major | teaching_assistant | staff | alumni | outsider",
  "courses": ["string"],
  "role": "string"
}
```
Consumed by Credential Service and University Record Service to build their own documents/records
for this applicant, so all three stay in sync.

**Events consumed (RabbitMQ)**

`credential_initialized` - published by Credential Service when it's contacted first instead.
```json
{
  "applicant_id": "uuid",
  "deception": "none | false_major | false_year | impersonation | expired_status",
  "name": "string",
  "student_id": "string",
  "student_id_doc": { "valid": true, "issue": "none | expired | forged | inconsistent | incomplete" },
  "university_email": "string",
  "enrollment_confirmation": { "valid": true, "issue": "none | expired | forged | inconsistent | incomplete" },
  "course_registration": ["string"]
}
```

`record_initialized` - published by University Record Service when it's contacted first instead.
```json
{
  "applicant_id": "uuid",
  "deception": "none | false_major | false_year | impersonation | expired_status",
  "name": "string",
  "student_id": "string",
  "enrollment_status": "string",
  "academic_year": 0,
  "courses": ["string"],
  "previously_banned": false
}
```

Applicant Service builds its profile from whichever of these arrives, if it wasn't the one that
initialized the applicant itself, and takes `deception` from that event rather than deciding its
own. That is what keeps the claim, the documents and the records describing the same lie.
Idempotent on `applicant_id` — an applicant is only initialized once, however many of the events arrive.

### Running this service

**To run it (no private repo access needed):**
1. Pull the public image — `docker pull kutulin/pad-17-applicant-service:0.3.0`
   (or let the team's Docker Compose file, in this CPR, pull it for you)
2. Provide the required environment variables (values shared directly within the team, never committed):
   - `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`
   - `RABBITMQ_HOST`, `RABBITMQ_PORT`, `RABBITMQ_USER`, `RABBITMQ_PASSWORD`
   - `MESSAGING_ENABLED` — set to `false` to run without a broker, for a Postman run
   - `SESSION_DIRECTORY`, `MOCK_ENDED_SESSIONS`, `MOCK_UNKNOWN_SESSIONS` — optional; the defaults mock Server Moderation Session Service
3. Run via the team's `docker-compose.yml` (see `deploy/` in this CPR) — it references this image by tag, along with PostgreSQL and RabbitMQ.

**Ports:** `8081` (REST)

**DockerHub:** `kutulin/pad-17-applicant-service:0.3.0` (public)

**Schema:** applied by Flyway at startup, so the database container comes up empty and the service migrates it. The same SQL is mirrored under `db/applicant/` for reading.

**Mocked until the other services exist:** the shift lookup behind `404 SESSION_NOT_FOUND` / `409 SESSION_NOT_ACTIVE` belongs to Server Moderation Session Service. Until it runs, a mock treats every session as running except `00000000-0000-0000-0000-000000000404` (not found) and `00000000-0000-0000-0000-0000000e0d0d` (not running), which the Postman collection uses to demonstrate both paths.

**Source code / build details:** private repo `pad-team-17-applicant-service` (professor has collaborator access) — only needed if inspecting the implementation itself, not for running the service.


---

### Credential Service

**Client-facing REST (via API Gateway)**

`POST /credentials` - generate credentials for a new applicant, when Credential Service is the
first of the three applicant-side services to be contacted. It mints the `applicant_id` and the
`deception`, then propagates both through `credential_initialized`.
```json
// Request
{ "session_id": "uuid" }

// Response 201
{
  "applicant_id": "uuid",
  "student_id_doc": { "valid": true, "issue": "none | expired | forged | inconsistent | incomplete" },
  "university_email": "string",
  "enrollment_confirmation": { "valid": true, "issue": "none | expired | forged | inconsistent | incomplete" },
  "course_registration": ["string"]
}
```

**Errors:** `422 VALIDATION_FAILED` if `session_id` is missing, `400 VALIDATION_FAILED` if the body
is not valid JSON, `404 SESSION_NOT_FOUND` if the session does not exist, `409 SESSION_NOT_ACTIVE` if
it is not running. The session check is served by a mock until Server Moderation Session Service
exists - see "Running this service" below.

`GET /credentials/{applicant_id}` - fetch an applicant's credentials and their validity
```json
// Response 200
{
  "applicant_id": "uuid",
  "student_id_doc": { "valid": true, "issue": "none | expired | forged | inconsistent | incomplete" },
  "university_email": "string",
  "enrollment_confirmation": { "valid": true, "issue": "none | expired | forged | inconsistent | incomplete" },
  "course_registration": ["string"]
}
```

**Errors:** `400 VALIDATION_FAILED` if the id is not a UUID, `404 APPLICANT_NOT_FOUND` if no
credentials exist for that applicant.

`GET /credentials` - every document set Credential Service holds
```json
// Response 200
[ { "applicant_id": "uuid", "student_id_doc": { "valid": true, "issue": "none" }, "...": "as above" } ]
```

`PATCH /credentials/{applicant_id}` - the applicant hands in corrected documents

Only the self-reported documents can be handed in again: `university_email` and
`course_registration`. The student ID card and the enrollment confirmation cannot, and neither can
their verdicts - a verdict is this service's finding, never client input. A corrected mailbox does
not un-forge a forged card, and an expired confirmation stays expired. Nothing is published.
```json
// Request - every field optional
{
  "university_email": "string",
  "course_registration": ["string"]
}

// Response 200 - the documents after resubmission, same shape as GET
```
**Errors:** `422 VALIDATION_FAILED` if no field is given, if `university_email` is not an email
address, if `course_registration` is empty, or if the body tries to set `student_id_doc`,
`enrollment_confirmation` or `applicant_id`; `400 VALIDATION_FAILED` if the body is not valid JSON;
`404 APPLICANT_NOT_FOUND`.

`DELETE /credentials/{applicant_id}` - removes the document set
```json
// Response 204 - no body
```
**Errors:** `400 VALIDATION_FAILED` if the id is not a UUID, `404 APPLICANT_NOT_FOUND`.

**Incoming gRPC**

`CredentialService.GetCredentials` - returns the applicant's documents and their validity so
Moderation can check a decision against the rules. Server-to-server, so it does not pass through
the API Gateway. It returns the same verdict the players see; this service still never compares a
document against University Record data.

```proto
rpc GetCredentials (GetCredentialsRequest) returns (Credentials);

message GetCredentialsRequest { string applicant_id = 1; }

message Credentials {
  string applicant_id = 1;
  DocumentStatus student_id_doc = 2;
  string university_email = 3;
  DocumentStatus enrollment_confirmation = 4;
  repeated string course_registration = 5;
}

message DocumentStatus { bool valid = 1; string issue = 2; }
```


**Events published (RabbitMQ)**

`credential_initialized` - published when Credential Service is the first to be contacted for a new applicant.
```json
{
  "applicant_id": "uuid",
  "deception": "none | false_major | false_year | impersonation | expired_status",
  "name": "string",
  "student_id": "string",
  "student_id_doc": { "valid": true, "issue": "none | expired | forged | inconsistent | incomplete" },
  "university_email": "string",
  "enrollment_confirmation": { "valid": true, "issue": "none | expired | forged | inconsistent | incomplete" },
  "course_registration": ["string"]
}
```
Consumed by Applicant Service and University Record Service to build their own data for this
applicant.

**Events consumed (RabbitMQ)**

`applicant_initialized` - published by Applicant Service when it's contacted first instead.
```json
{
  "applicant_id": "uuid",
  "deception": "none | false_major | false_year | impersonation | expired_status",
  "name": "string",
  "student_id": "string",
  "major": "string",
  "year": 0,
  "university_status": "faf_student | other_major | teaching_assistant | staff | alumni | outsider",
  "courses": ["string"],
  "role": "string"
}
```

`record_initialized` - published by University Record Service when it's contacted first instead.
```json
{
  "applicant_id": "uuid",
  "deception": "none | false_major | false_year | impersonation | expired_status",
  "name": "string",
  "student_id": "string",
  "enrollment_status": "string",
  "academic_year": 0,
  "courses": ["string"],
  "previously_banned": false
}
```
Credential Service builds its documents from whichever event arrives, if it wasn't the one that
initialized the applicant itself, and forges them according to that event's `deception` — so a
document contradicts the records in a specific, discoverable way instead of at random.
Idempotent on `applicant_id`.

### Running this service

**To run it (no private repo access needed):**
1. Pull the public image — `docker pull kutulin/pad-17-credential-service:0.3.0`
   (or let the team's Docker Compose file, in this CPR, pull it for you)
2. Provide the required environment variables (values shared directly within the team, never committed):
   - `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`
   - `RABBITMQ_HOST`, `RABBITMQ_PORT`, `RABBITMQ_USER`, `RABBITMQ_PASSWORD`
   - `MESSAGING_ENABLED` — set to `false` to run without a broker, for a Postman run
   - `SESSION_DIRECTORY`, `MOCK_ENDED_SESSIONS`, `MOCK_UNKNOWN_SESSIONS` — optional; the defaults mock Server Moderation Session Service
3. Run via the team's `docker-compose.yml` (see `deploy/` in this CPR) — it references this image by tag, along with PostgreSQL and RabbitMQ.

**Ports:** `8082` (REST)

**DockerHub:** `kutulin/pad-17-credential-service:0.3.0` (public)

**Schema:** applied by Flyway at startup, so the database container comes up empty and the service migrates it. The same SQL is mirrored under `db/credential/` for reading.

**Mocked until the other services exist:** the shift lookup behind `404 SESSION_NOT_FOUND` / `409 SESSION_NOT_ACTIVE` belongs to Server Moderation Session Service. Until it runs, a mock treats every session as running except `00000000-0000-0000-0000-000000000404` (not found) and `00000000-0000-0000-0000-0000000e0d0d` (not running), which the Postman collection uses to demonstrate both paths.

**Source code / build details:** private repo `pad-team-17-credential-service` (professor has collaborator access) — only needed if inspecting the implementation itself, not for running the service.


---
### Server Rules Service

Holds no applicant data — evaluates whatever it's handed, per request.

**Client-facing REST (via API Gateway)**

`GET /rules` - fetch the current active rule set
```json
// Response 200
{
  "rules": [
    { "rule_id": "uuid", "description": "string", "condition": "string" }
  ]
}
```

`PUT /rules` - replace the active rule set (Moderator only, between shifts)
```json
// Request
{
  "rules": [
    { "description": "string", "condition": "string" }
  ]
}

// Response 200
{
  "rules": [
    { "rule_id": "uuid", "description": "string", "condition": "string" }
  ]
}

// Response 422 — rules is missing, null, or a rule is missing description/condition
{ "error": { "code": "VALIDATION_FAILED", "message": "human text" } }

// Response 400 — request body is not valid JSON
{ "error": { "code": "VALIDATION_FAILED", "message": "Request body is malformed" } }
```

### Rule condition format

A `condition` string has the shape `<field> <operator> <value>`. **Matching means the applicant violates the rule** — write conditions to describe the disqualifying state, not the allowed one.

Supported fields and operators:

| Field | Type | Operators |
|---|---|---|
| `university_status` | string | `==`, `!=` |
| `year` | number | `==`, `!=`, `>=`, `<=`, `>`, `<` |
| `credentials_valid` | boolean | `==`, `!=` |
| `previously_banned` | boolean | `==`, `!=` |
| `courses` | list | `contains`, `!=` (not contains) |

Examples:
- previously_banned == true → violation if the applicant was previously banned
- courses != PAD → violation if the applicant hasn't taken PAD
- university_status != faf_student → violation if the applicant isn't an FAF student
- year <= 1 → violation if the applicant is a first-year

Malformed conditions (unparseable syntax, unknown fields, non-numeric values on a numeric field) are silently skipped rather than causing an error — the applicant just isn't evaluated against that specific rule.

No events published or consumed — Server Rules Service doesn't participate in the applicant propagation pattern.

**Incoming gRPC (called by Moderation Service)**

`EvaluateApplicant` — see Moderation Service's outgoing gRPC calls above for the full request/response shape. Moderation Service assembles the request from Applicant, Credential, and University Record Services' responses; Server Rules Service never fetches applicant data itself.

### Running this service

**To run it (no private repo access needed):**
1. Pull the public image — `docker pull anastasiatiganescu/server-rules-service:v0.1.1`
   (or let the team's Docker Compose file, in this CPR, pull it for you)
2. Provide the required environment variables (values shared directly within the team, never committed):
   - `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`
3. Run via the team's `docker-compose.yml` (see `deploy/` in this CPR) — it references this image by tag, along with PostgreSQL.

**Ports:** `8080` (REST), `9090` (gRPC)

**DockerHub:** `anastasiatiganescu/server-rules-service:v0.1.1` (public, `linux/amd64` + `linux/arm64`)

**Source code / build details:** private repo `pad-team-17-server-rules-service` (professor has collaborator access) — only needed if inspecting the implementation itself, not for running the service.

---

### University Record Service

**Client-facing REST (via API Gateway)**

`POST /records` - generate ground-truth records for a new applicant, when University Record Service is the first of the three applicant-side services to be contacted. It mints the applicant_id and the deception, then propagates both through record_initialized.
```json
// Request
{ "session_id": "uuid" }

// Response 201
{
  "applicant_id": "uuid",
  "enrollment_status": "string",
  "academic_year": 0,
  "courses": ["string"],
  "previously_banned": false
}

// Response 400 — request body is not valid JSON
{ "error": { "code": "VALIDATION_FAILED", "message": "Request body is malformed" } }

// Response 422 — session_id is missing or blank
{ "error": { "code": "VALIDATION_FAILED", "message": "human text" } }
```
Errors: `404 SESSION_NOT_FOUND` if the session does not exist, `409 SESSION_NOT_ACTIVE` (Not yet enforced — see the service's own README.)


`GET /sessions/{session_id}/records/{applicant_id}` - fetch the records the calling player is assigned to see, for this applicant, in this session
```json
// Request
// header: Authorization: Bearer <JWT>   (identifies the calling player)

// Response 200
{
  "assigned_scopes": ["enrollment"],
  "data": { "enrollment": { "enrollment_status": "string" } }
}

// Response 401 — missing or malformed Authorization header / token
{ "error": { "code": "UNAUTHORIZED", "message": "human text" } }

// Response 403 — player has no scope assignment for this session
{ "error": { "code": "NOT_ASSIGNED_TO_SESSION", "message": "human text" } }

// Response 404 — no record exists for this applicant
{ "error": { "code": "VALIDATION_FAILED", "message": "applicant not found" } }
```
The service no longer trusts a client-supplied `scope` value. Instead it looks up which scope(s)
the calling player (from the JWT) was assigned via `AssignScopes` — a gRPC call made by Server
Moderation Session Service when the shift starts — and returns only that data. A player who
wasn't in the session, or has no assignment, gets `403`. This is the actual enforcement point
for the partitioning promised in Service Boundaries.


**Incoming gRPC (called by Server Moderation Session Service at shift start)**

`AssignScopes`
```proto
rpc AssignScopes (AssignScopesRequest) returns (AssignScopesResponse);
message AssignScopesRequest {
  string session_id = 1;
  repeated PlayerScopeAssignment assignments = 2;
}
message PlayerScopeAssignment {
  string player_id = 1;
  repeated string scopes = 2; // enrollment | courses | schedule | messages
}
message AssignScopesResponse { bool success = 1; }
```
Idempotent per `(session_id, player_id)` — a repeated call for the same pair replaces the stored scopes rather than duplicating the row.

**Events published (RabbitMQ)**

`record_initialized` - published when University Record Service is the first to be contacted for a new applicant.
```json
{
  "applicant_id": "uuid",
  "deception": "none | false_major | false_year | impersonation | expired_status",
  "name": "string",
  "student_id": "string",
  "enrollment_status": "string",
  "academic_year": 0,
  "courses": ["string"],
  "previously_banned": false
}
```
Consumed by Applicant Service and Credential Service to build their own data for this applicant.

**Events consumed (RabbitMQ)**

`applicant_initialized` - published by Applicant Service when it's contacted first instead.
```json
{
  "applicant_id": "uuid",
  "deception": "none | false_major | false_year | impersonation | expired_status",
  "name": "string",
  "student_id": "string",
  "major": "string",
  "year": 0,
  "university_status": "faf_student | other_major | teaching_assistant | staff | alumni | outsider",
  "courses": ["string"],
  "role": "string"
}
```

`credential_initialized` - published by Credential Service when it's contacted first instead.
```json
{
  "applicant_id": "uuid",
  "deception": "none | false_major | false_year | impersonation | expired_status",
  "name": "string",
  "student_id": "string",
  "student_id_doc": { "valid": true, "issue": "none | expired | forged | inconsistent | incomplete" },
  "university_email": "string",
  "enrollment_confirmation": { "valid": true, "issue": "none | expired | forged | inconsistent | incomplete" },
  "course_registration": ["string"]
}
```
University Record Service builds its records from whichever event arrives, if it wasn't the one that initialized the applicant itself. Idempotent on `applicant_id`.

Not yet consuming `decision_made` (see Moderation Service below) — planned for a future lab, so previously_banned isn't updated when a Moderator bans an applicant

### Running this service

**To run it (no private repo access needed):**
1. Pull the public image — `docker pull anastasiatiganescu/university-record-service:v0.1.1`
   (or let the team's Docker Compose file, in this CPR, pull it for you)
2. Provide the required environment variables (values shared directly within the team, never committed):
   - `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`
   - `RABBITMQ_HOST`, `RABBITMQ_PORT`, `RABBITMQ_USERNAME`, `RABBITMQ_PASSWORD`
   - `JWT_SECRET`
3. Run via the team's `docker-compose.yml` (see `deploy/` in this CPR) — it references this image by tag, along with PostgreSQL and RabbitMQ.

**Ports:** `8080` (REST), `9090` (gRPC)

**DockerHub:** `anastasiatiganescu/university-record-service:v0.1.1` (public, `linux/amd64` + `linux/arm64`)

**Note:** `JWT_SECRET` must match whatever signing secret Player Service uses once real authentication is wired in (Lab 2+) — currently a local placeholder for testing the scope-filtering mechanism only.

**Source code / build details:** private repo `pad-team-17-university-record-service` (professor has collaborator access) — only needed if inspecting the implementation itself, not for running the service.

---

### Moderation Service

The Moderation Service is responsible for processing moderator decisions for applicants.

For each submitted verdict, it gathers applicant information, credentials, and university records, sends the relevant data to the Server Rules Service for evaluation, compares the moderator's verdict with the expected verdict, calculates the penalty, stores the decision, and publishes a `decision_made` event.

The Moderation Service does not define the rules that determine whether an applicant should be accepted, rejected, flagged, or banned. That responsibility belongs to the Server Rules Service.

For Lab 1, dependencies on other microservices and RabbitMQ are implemented using mocks. The interfaces are kept separate so they can later be replaced by gRPC clients and a RabbitMQ publisher.

#### Requirements

To run the service locally, the following software is required:

- Node.js 24+
- npm
- PostgreSQL 16+

Alternatively, Docker can be used to run both the service and its PostgreSQL database:

- Docker
- Docker Compose

The service uses the following main technologies:

- TypeScript
- NestJS
- TypeORM
- PostgreSQL
- gRPC for future synchronous service-to-service communication
- RabbitMQ for future asynchronous event publishing

Create a `.env` file based on `.env.example`:

```env
PORT=3000

DB_HOST=localhost
DB_PORT=5432
DB_USERNAME=moderation
DB_PASSWORD=change_me
DB_DATABASE=moderation
```

Use the actual values defined in `.env.example` if they differ from the example above.

For local development, install the dependencies and start the service:

```bash
npm install
npm run start:dev
```

When running locally, the Moderation Service is available at:

```text
http://localhost:3000
```


#### Running with Docker

The service and its PostgreSQL database can be started using Docker Compose:

```bash
docker compose -f deploy/docker-compose.yml up -d
```

The Moderation Service runs on port `3000` inside its container and is exposed on the host at:

```text
http://localhost:8085
```

The deployment also starts the PostgreSQL database used by the Moderation Service.

The published Docker image is:

```text
dannacojocari/moderation-service:0.2.0
```

The image supports:

```text
linux/amd64
linux/arm64
```

PostgreSQL data is stored in a persistent Docker volume.

To check the containers:

```bash
docker compose -f deploy/docker-compose.yml ps
```

To stop the service:

```bash
docker compose -f deploy/docker-compose.yml down
```

#### Communication

The Moderation Service uses different communication mechanisms depending on the operation.

**REST**

REST is used by clients to submit and manage moderation decisions.

**gRPC**

gRPC is the planned synchronous service-to-service communication mechanism.

The Moderation Service requires information from:

- Applicant Service
- Credential Service
- University Record Service
- Server Rules Service

For Lab 1, these dependencies are represented by mock implementations behind service interfaces. The mocks can later be replaced by gRPC clients without changing the moderation decision logic.

**RabbitMQ**

RabbitMQ is the planned asynchronous communication mechanism for publishing moderation results.

After a new decision is successfully persisted, the Moderation Service publishes a `decision_made` event.

For Lab 1, the RabbitMQ publisher is represented by a mock implementation. The same publisher abstraction can later be backed by RabbitMQ.

#### Decisions REST API

`POST /sessions/{session_id}/applicants/{applicant_id}/decision` - submit a moderator verdict for an applicant

```json
{
  "verdict": "accept"
}
```

Possible verdicts are:

```text
accept
reject
flag
ban
```

A successful response uses the following format:

```json
{
  "id": "uuid",
  "session_id": "uuid",
  "applicant_id": "uuid",
  "moderator_id": "uuid",
  "verdict": "accept",
  "correct": true,
  "violated_rule_ids": [],
  "penalty": 0,
  "created_at": "2026-09-20T12:00:00.000Z",
  "updated_at": "2026-09-20T12:00:00.000Z"
}
```

Only one decision may exist for the same applicant within the same session.

`GET /decisions` - list all stored moderation decisions

`GET /decisions/{decision_id}` - retrieve a specific moderation decision

`PATCH /decisions/{decision_id}` - update the verdict of an existing decision

```json
{
  "verdict": "reject"
}
```

Only `verdict` may be modified by the client.

The following fields are controlled by the service:

- `session_id`
- `applicant_id`
- `moderator_id`
- `correct`
- `violated_rule_ids`
- `penalty`

When the verdict is updated, the Moderation Service evaluates the applicant again and recalculates `correct`, `violated_rule_ids`, and `penalty`.

A moderator may only update decisions that they own.

`DELETE /decisions/{decision_id}` - delete a moderation decision

A moderator may only delete decisions that they own.

A successful deletion returns:

```text
204 No Content
```

#### Decision Evaluation

The Moderation Service does not determine which verdict an applicant should receive.

It gathers the required information and sends the evaluation data to the Server Rules Service. The Server Rules Service returns an `expected_verdict` and any violated rules.

The Moderation Service determines correctness using:

```text
correct = submitted_verdict == expected_verdict
```

The rules that determine whether an applicant should be accepted, rejected, flagged, or banned belong to the Server Rules Service.

#### Penalty Calculation

The Moderation Service calculates a penalty by comparing the submitted verdict with the expected verdict.

| Expected | Accept | Flag | Reject | Ban |
|---|---:|---:|---:|---:|
| Accept | 0 | 1 | 2 | 3 |
| Flag | 1 | 0 | 1 | 2 |
| Reject | 2 | 1 | 0 | 2 |
| Ban | 3 | 2 | 1 | 0 |

A correct decision always has a penalty of `0`. Larger differences from the expected moderation action result in higher penalties.

#### gRPC Contracts

The following contracts describe the synchronous dependencies required by the Moderation Service.

##### `ApplicantService.GetApplicant`

```proto
rpc GetApplicant (GetApplicantRequest) returns (Applicant);

message GetApplicantRequest {
  string applicant_id = 1;
}

message Applicant {
  string applicant_id = 1;
  string name = 2;
  string student_id = 3;
  string major = 4;
  int32 year = 5;
  string university_status = 6;
  repeated string courses = 7;
  string role = 8;
}
```

##### `CredentialService.GetCredentials`

```proto
rpc GetCredentials (GetCredentialsRequest) returns (Credentials);

message GetCredentialsRequest {
  string applicant_id = 1;
}

message Credentials {
  string applicant_id = 1;
  DocumentStatus student_id_doc = 2;
  string university_email = 3;
  DocumentStatus enrollment_confirmation = 4;
  repeated string course_registration = 5;
}

message DocumentStatus {
  bool valid = 1;
  string issue = 2;
}
```

##### `UniversityRecordService.GetRecordSnapshot`

```proto
rpc GetRecordSnapshot (GetRecordSnapshotRequest)
    returns (RecordSnapshot);

message GetRecordSnapshotRequest {
  string applicant_id = 1;
}

message RecordSnapshot {
  string applicant_id = 1;
  string enrollment_status = 2;
  int32 academic_year = 3;
  repeated string courses = 4;
  bool previously_banned = 5;
}
```

This is a server-to-server request and returns the record information required by the Moderation Service independently of what information is visible to an individual player.

##### `ServerRulesService.EvaluateApplicant`

```proto
rpc EvaluateApplicant (EvaluateApplicantRequest)
    returns (EvaluateApplicantResponse);

message EvaluateApplicantRequest {
  string applicant_id = 1;
  string university_status = 2;
  int32 year = 3;
  repeated string courses = 4;
  bool credentials_valid = 5;
  bool previously_banned = 6;
}

message EvaluateApplicantResponse {
  string expected_verdict = 1;
  repeated string violated_rule_ids = 2;
}
```

`expected_verdict` must contain one of:

```text
accept | reject | flag | ban
```

`EvaluateApplicantRequest` is assembled by the Moderation Service using information obtained from the Applicant, Credential, and University Record services.

The Server Rules Service determines the expected verdict and violated rules. It does not fetch the applicant data itself.

For Lab 1, all four gRPC dependencies are represented by mock implementations.

#### RabbitMQ Events

##### `decision_made`

A `decision_made` event is published after a new moderation decision has been successfully persisted.

```json
{
  "session_id": "uuid",
  "applicant_id": "uuid",
  "verdict": "accept",
  "correct": true,
  "penalty": 0
}
```

The event allows other services, particularly the Server Moderation Session Service, to react to the result of a moderation decision without creating a synchronous dependency on the Moderation Service.

For Lab 1, event publishing is represented by a mock publisher. RabbitMQ integration will replace this mock during service integration.

#### Persistence

The Moderation Service owns its PostgreSQL database.

The main entities are:

- `decisions` - stores the moderator verdict, correctness, penalty, applicant, session, and moderator
- `decision_violations` - stores rule IDs violated by the applicant for a decision

A decision may contain multiple violated rules.

Deleting a decision also removes its associated violation records.

No other microservice directly accesses the Moderation Service database.

#### Postman Collection

The REST API can be tested using:

```text
postman/pad-team-17-pair4-moderation.postman_collection.json
```

The collection uses variables for:

- `base_url`
- `session_id`
- `applicant_id`
- `decision_id`

The `decision_id` variable is automatically populated after a decision is successfully created.

The collection covers:

- Creating a moderation decision
- Retrieving all decisions
- Retrieving a decision by ID
- Updating a decision and verifying recalculation
- Rejecting an invalid verdict
- Rejecting modifications to protected fields
- Rejecting duplicate decisions
- Retrieving a nonexistent decision
- Deleting a decision
- Verifying that a deleted decision returns `404`

Run the requests in their numbered order for the complete workflow.

#### Current Lab 1 Limitations

The external service dependencies are currently represented by mocks rather than real gRPC clients.

The `decision_made` publisher is currently a mock rather than a RabbitMQ publisher.

Moderator identity is also mocked for Lab 1. Once authentication is integrated, the moderator identity should be obtained from the authenticated JWT rather than from a development/mock identity.

The service interfaces and publisher abstraction are intentionally separated from the decision logic so these mocks can later be replaced by the real infrastructure integrations.

---

### Discord DMs Service

The Discord DMs Service manages communication between moderators and junior moderators during a moderation session. It owns communication channels, channel membership, and messages.

The service provides REST endpoints for channel and message management and uses Socket.IO for real-time communication. Channel and message data is persisted in PostgreSQL.

The service transports messages between players but does not determine whether the information contained in a message is correct.

#### Requirements

To run the service locally, the following software is required:

- Node.js 24+
- npm
- PostgreSQL 16+

Alternatively, Docker can be used to run both the service and its PostgreSQL database:

- Docker
- Docker Compose

The service uses the following main technologies:

- TypeScript
- NestJS
- TypeORM
- PostgreSQL
- Socket.IO

Create a `.env` file based on `.env.example`:

```env
PORT=3000
DB_HOST=localhost
DB_PORT=5432
DB_USERNAME=discord_dms
DB_PASSWORD=change_me
DB_DATABASE=discord_dms
```

For local development, install the dependencies and start the service:

```bash
npm install
npm run start:dev
```

When running locally, the Discord DMs Service is available at:

```text
http://localhost:3000
```

#### Running with Docker

The recommended way to run the complete service is with Docker Compose:

```bash
docker compose -f deploy/docker-compose.yml up -d
```

The Discord DMs Service runs on port `3000` inside its container and is exposed on the host at:

```text
http://localhost:8086
```

The deployment also starts the PostgreSQL database used by the Discord DMs Service.

The published Docker image is:

```text
dannacojocari/discord-dms-service:0.3.0
```

The image supports:

```text
linux/amd64
linux/arm64
```

PostgreSQL data is stored in a persistent Docker volume.

To check the containers:

```bash
docker compose -f deploy/docker-compose.yml ps
```

To stop the service:

```bash
docker compose -f deploy/docker-compose.yml down
```

#### Communication

The Discord DMs Service uses different communication mechanisms depending on the operation.

**REST**

REST is used for channel and message management and for triggering session channel provisioning during Lab 1.

**WebSocket / Socket.IO**

Socket.IO is used for real-time communication between players.

Supported client events:

- `join_channel`
- `send_message`

Supported server events:

- `message`
- `error`

**gRPC / Session Service Integration**

The Discord DMs Service depends on session and player-assignment information to determine which players should have access to each communication channel.

The integration is represented by a `SessionClient` abstraction. For Lab 1, the real Session Service gRPC integration is not yet available, so the service uses `MockSessionClient`.

The mocked Session Service returns:

- `session_id`
- players belonging to the session
- each player's role
- each player's scopes

The currently agreed player scopes are:

```text
enrollment
courses
schedule
messages
```

The Lab 1 implementation maps these scopes to Discord channels:

```text
enrollment -> enrollment-check
courses    -> course-registration
schedule   -> schedule-check
messages   -> general-mod-chat
```

Channel membership is generated from the scopes assigned to each player.

The mock is isolated behind the `SessionClient` interface so that it can later be replaced by a real gRPC implementation without changing the channel provisioning logic.

**RabbitMQ**

The current Discord DMs Service does not publish or consume RabbitMQ events.

Real-time player messages are transported directly through Socket.IO and persisted in PostgreSQL. The service does not determine whether message contents are correct and currently has no asynchronous domain events that require RabbitMQ.

#### Channels REST API

`POST /channels` - create a channel and optionally assign players

```json
{
  "session_id": "uuid",
  "name": "general-mod-chat",
  "player_ids": ["uuid"]
}
```

`GET /channels` - list all channels

`GET /channels/{channel_id}` - retrieve a specific channel

`GET /sessions/{session_id}/channels` - list channels belonging to a session

`POST /sessions/{session_id}/channels/provision` - provision channels and memberships using session player scopes

The provisioning operation obtains session information through the `SessionClient` abstraction. In Lab 1, this information is supplied by `MockSessionClient`.

For example, if a player has:

```json
{
  "player_id": "uuid",
  "role": "test_junior_moderator",
  "scopes": ["enrollment", "messages"]
}
```

the player is assigned to:

```text
enrollment-check
general-mod-chat
```

Provisioning is idempotent. Calling the endpoint again for the same session updates the existing channel memberships instead of creating duplicate channels.

`PATCH /channels/{channel_id}` - update a channel

```json
{
  "name": "faculty-check",
  "player_ids": ["uuid"]
}
```

`DELETE /channels/{channel_id}` - delete a channel

Channel responses use the following format:

```json
{
  "id": "uuid",
  "session_id": "uuid",
  "name": "string",
  "player_ids": ["uuid"],
  "created_at": "RFC3339",
  "updated_at": "RFC3339"
}
```

#### Messages REST API

`POST /channels/{channel_id}/messages` - create a message

```json
{
  "sender_id": "uuid",
  "content": "string"
}
```

`GET /channels/{channel_id}/messages` - list messages in a channel

`GET /channels/{channel_id}/messages/{message_id}` - retrieve a specific message

`PATCH /channels/{channel_id}/messages/{message_id}` - update message content

```json
{
  "content": "updated message"
}
```

`DELETE /channels/{channel_id}/messages/{message_id}` - delete a message

Message responses use the following format:

```json
{
  "id": "uuid",
  "channel_id": "uuid",
  "sender_id": "uuid",
  "content": "string",
  "created_at": "RFC3339",
  "updated_at": "RFC3339"
}
```

#### WebSocket Protocol

Real-time communication uses Socket.IO.

Client → server, `join_channel`:

```json
{
  "channel_id": "uuid",
  "player_id": "uuid"
}
```

The service verifies that the channel exists and that the player is a member of the channel before joining the corresponding Socket.IO room.

Client → server, `send_message`:

```json
{
  "channel_id": "uuid",
  "sender_id": "uuid",
  "content": "string"
}
```

The sender must be a channel member and the socket must have previously joined that channel.

Messages sent through Socket.IO are persisted using the same message service used by the REST API before they are broadcast.

Server → client, `message`:

```json
{
  "id": "uuid",
  "channel_id": "uuid",
  "sender_id": "uuid",
  "content": "string",
  "created_at": "RFC3339",
  "updated_at": "RFC3339"
}
```

Server → client, `error`:

```json
{
  "message": "human-readable error"
}
```

#### Persistence

The service owns its PostgreSQL database.

The main entities are:

- `channels` - channels associated with moderation sessions
- `channel_members` - players that have access to channels
- `messages` - messages sent in channels

Deleting a channel also removes its memberships and messages.

Channel names are unique within a session. Session provisioning reuses existing channels and synchronizes their memberships rather than creating duplicates.

No other microservice directly accesses the Discord DMs database.

#### Postman Collection

The REST API can be tested using:

```text
postman/pad-team-17-pair4-discord-dms.postman_collection.json
```

The collection contains requests for:

- Channel CRUD
- Session channel lookup
- Session channel provisioning
- Message CRUD

The `Provision Session Channels` request verifies that the mocked Session Service information produces the expected channels.

#### Current Lab 1 Limitations

Authentication between the client and Discord DMs is not yet integrated. For Lab 1, player identity is supplied in the WebSocket payload.

JWT authentication should later provide the authenticated player identity instead of trusting `player_id` or `sender_id` supplied by the client.

The Session Service integration currently uses `MockSessionClient`. The mock provides session players, roles, and scopes so that channel provisioning can be implemented and tested independently while the real Session Service integration is unavailable.

The mock will later be replaced by a gRPC client implementing the same `SessionClient` abstraction.

The current scope-to-channel mapping is part of the Lab 1 implementation and can be revised when the final inter-service contract and channel configuration rules are integrated.

## GitHub Workflow

### Branches

| Branch | Role |
|---|---|
| `main` | Presented state. Only ever receives merges from `dev`. Tagged per lab. |
| `dev` | Integration branch. All feature work merges here first. |
| feature branches | Short-lived, one per task, deleted after merge. |

Both `main` and `dev` are protected: no direct pushes, pull request required.

### Branch naming

```
feat/<service>-<slug>     feat/credential-document-validation
fix/<service>-<slug>      fix/applicant-duplicate-events
docs/<slug>               docs/github-workflow
chore/<slug>              chore/submodules-anastasia
```

Lowercase, hyphen-separated, `<service>` matches the directory under `services/`.

### Merging

- feature branch → `dev`: **squash merge**, so `dev` keeps one commit per task
- `dev` → `main`: **merge commit**, so the integration history is preserved
- **1 approval required** — a team of four stalls on two
- The branch is deleted after merge

Rebase on `dev` before opening a PR; do not merge `dev` into your feature branch.

### Commit messages

One capitalised imperative sentence, no prefix, no body.

```
Create README.md with service boundaries
Link Applicant and Credential services as submodules
```

### Pull request contents

Every PR states:

1. **What** changed
2. **Why** — the task or decision behind it
3. **How it was tested** — commands run, or "docs only"
4. **Linked task** from the project board

A PR touching a service someone else owns needs that owner's approval, not just any.

### Versioning

Semantic versioning, tagged on `main` after each lab is presented:

```
v0.1.0   Lab 0 — planning and contract
v0.2.0   Lab 1 — first running services
```

Service repositories are tagged independently once they publish images; the CPR tag records
which submodule commits made up a presented state.
