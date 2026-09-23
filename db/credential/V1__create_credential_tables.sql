-- Credential Service owns the documents an applicant presents and the verdict on each. It holds no
-- university ground truth - deliberately. Comparing a document against the records is the players'
-- job and Moderation Service's job, never this service's.

CREATE TABLE credentials (
    applicant_id                   UUID         PRIMARY KEY,
    name                           VARCHAR(255) NOT NULL,
    student_id                     VARCHAR(64)  NOT NULL,
    university_email               VARCHAR(255) NOT NULL,
    student_id_doc_valid           BOOLEAN      NOT NULL,
    student_id_doc_issue           VARCHAR(32)  NOT NULL,
    enrollment_confirmation_valid  BOOLEAN      NOT NULL,
    enrollment_confirmation_issue  VARCHAR(32)  NOT NULL,
    -- Never leaves the applicant-side services: absent from every REST response and gRPC message.
    deception                      VARCHAR(32)  NOT NULL,
    originated_here                BOOLEAN      NOT NULL,
    created_at                     TIMESTAMPTZ  NOT NULL
);

CREATE TABLE course_registrations (
    applicant_id UUID        NOT NULL REFERENCES credentials (applicant_id) ON DELETE CASCADE,
    course       VARCHAR(64) NOT NULL
);

CREATE INDEX idx_course_registrations_applicant ON course_registrations (applicant_id);

-- Idempotency guard: one row per applicant, so a redelivered propagation event cannot produce a
-- duplicate document set.
CREATE TABLE processed_events (
    applicant_id UUID        PRIMARY KEY,
    source_event VARCHAR(64) NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL
);
