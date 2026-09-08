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