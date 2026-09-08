# Student ID, please

A cooperative game about Discord server moderation, built as a microservices project for the PAD course. A team of players runs moderation "shifts" for a university Discord server — one 
Moderator reviews applicants directly, while several Junior Moderators consult scattered university records and credentials to help verify who's really who, before a decision 
(Accept / Reject / Flag / Ban) gets made and checked against the current access rules.

The system is split into 8 microservices, each owning a distinct piece of the game's state — see the boundaries and diagram below.

## Team 17
- Anastasia Tiganescu, FAF-231 — [Service(s) owned]
- Catalin Darzu, FAF-231  — [Service(s) owned]
- Daniela Cojocari, FAF-231  — [Service(s) owned]
- Janeta Grigoras, FAF-231  — [Service(s) owned]

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

Applicant Service is the designated entry point for new applicants — it initializes 
a new applicant's profile and propagates it to Credential Service and University 
Record Service. Per the spec, any of these three services could technically be 
the first contacted; our team has fixed Applicant Service as that entry point for 
consistency.

Moderation Service is the only service that reaches into the applicant-data cluster 
after an applicant already exists — it queries Applicant, Credential, and University 
Record Services to gather what it needs before checking the decision against Server Rules.

---

## Technologies and Communication Patterns

### Language split — TypeScript and Java

The eight services fall into two halves with genuinely different runtime demands, so we
split them along that seam rather than by convenience.

**TypeScript (NestJS) — the real-time, stateful half: Player, Server Moderation Session,
Moderation, Discord DMs.**
A shift is four players connected at once for the whole duration, with far more idle
socket time than CPU work. Node's single event loop handles many mostly-idle WebSocket
connections at a low cost per connection, which is exactly the shape of the DMs traffic,
and Socket.IO gives us rooms, reconnection and acknowledgements without hand-written
socket plumbing — a room maps one-to-one onto a Discord channel, so channel membership
is a first-class primitive instead of something we implement. Session and Moderation live
on this side because they are the services the sockets talk to most: the session tick, the
running score and the decision outcome all need to reach the connected players immediately,
and keeping them in the same runtime avoids a language hop on the hottest path in the game.
The trade-off we accept is a weaker type story at runtime — the DTOs are validated with
`class-validator` at the edge precisely because TypeScript's types disappear after compilation.

**Java 21 (Spring Boot) — the data and rules half: Applicant, Credential, Server Rules,
University Record.**
This half is almost pure data modelling: an applicant has a *claim* and a *truth*, credentials
are documents with structural validity, records are a partitioned ground truth, and rules are
a set of predicates evaluated against all of it. Those are exactly the problems a strong static
type system, Bean Validation and JPA are good at — an invalid document state or a missing field
becomes a compile-time or validation-time error rather than a runtime surprise during a demo.
The rules engine also benefits from being written once, explicitly and verbosely, since it is
the component that decides whether a player's verdict was correct. The trade-off is heavier
services and slower startup than the Node half; we accept it because this half is
request/response and event-driven, never holding long-lived connections.

**Pinned versions:** JDK **21 LTS** and Node **20 LTS** for the whole team. Mismatched
toolchains between laptops and the Docker images are a class of bug we are not spending the
semester debugging.

| Service | Owner pair | Language / framework | Storage |
|---|---|---|---|
| Player | 1 | TypeScript · NestJS | PostgreSQL |
| Server Moderation Session | 1 | TypeScript · NestJS | PostgreSQL |
| Applicant | 2 | Java 21 · Spring Boot, Spring Data JPA | PostgreSQL |
| Credential | 2 | Java 21 · Spring Boot, Spring Data JPA | PostgreSQL |
| Server Rules | 3 | Java 21 · Spring Boot | PostgreSQL (rule sets only) |
| University Record | 3 | Java 21 · Spring Boot, Spring Data JPA | PostgreSQL |
| Moderation | 4 | TypeScript · NestJS | PostgreSQL |
| Discord DMs | 4 | TypeScript · NestJS, Socket.IO | PostgreSQL |

### Communication patterns

| Direction | Protocol | Why this one |
|---|---|---|
| Client → system | **REST + JSON** through an API gateway | Everything the players do outside of chat is a discrete request — log in, join a shift, look up a record, submit a verdict. REST is cacheable, trivially debuggable from a browser, and lets the gateway be the single place where the JWT is checked. |
| Client → Discord DMs | **WebSocket** (Socket.IO) | Chat between the Moderator and Junior Moderators has to be pushed, not polled. Polling four clients against a chat service for the length of a shift is wasted traffic and adds latency to the one interaction the game is built around. |
| Service → service, needs an answer now | **gRPC** | The synchronous calls are internal and on the critical path: Moderation asks Applicant, Credential and University Record for data, then asks Server Rules for the correct verdict — four round-trips before a decision can be answered. Protobuf keeps those payloads small and, more importantly, the `.proto` file is a contract both the Java and the TypeScript half generate from, so the language split cannot drift into mismatched JSON shapes. |
| Service → service, fire and forget | **RabbitMQ events** | Fan-out that must not block the caller. `ApplicantCreated` reaches Credential and University Record, `DecisionMade` reaches Session, `ShiftEnded` reaches Player. The publisher does not care when the consumers catch up, and a consumer being down must not fail the shift — the broker buffers instead. |

### Data management

**One database per service.** No service reads another service's tables; the only way to
data you do not own is that owner's API or an event it published. This costs us joins we
would otherwise get for free, and it is the point: it keeps the boundaries above enforceable
rather than merely documented.

The applicant-side trio (Applicant, Credential, University Record) is the one place where
the same conceptual entity is spread across three databases. They are kept consistent by
event propagation, not by a shared table: Applicant Service creates the applicant and
publishes `ApplicantCreated`; Credential builds the documents from it and University Record
builds the ground truth from it. Consumption is **idempotent, keyed on `applicant_id`**, so
a redelivered message cannot produce duplicate documents or records. The consistency we get
is eventual, which is acceptable here because an applicant is only shown to the Moderator
after the session advances to them.

### Shared conventions

So that eight services written by four people in two languages read as one system:

| Thing | Decision |
|---|---|
| Auth | `Authorization: Bearer <JWT>`, verified at the gateway and re-verified in each service |
| IDs | UUID v4, transported as strings |
| Timestamps | RFC 3339, UTC — e.g. `2026-09-15T14:03:00Z` |
| Error shape | `{ "error": { "code": "STRING_CODE", "message": "human text" } }` |
| JSON naming | `snake_case` |
| Resource paths | plural, e.g. `/applicants/{applicant_id}` |
| Databases | one per service, no cross-service reads |
