-- Applicant Service owns the claimed half of an applicant. The truth lives in University Record
-- Service and the documents in Credential Service; nothing here references those databases.

CREATE TABLE applicants (
    applicant_id      UUID         PRIMARY KEY,
    session_id        UUID         NOT NULL,
    name              VARCHAR(255) NOT NULL,
    student_id        VARCHAR(64)  NOT NULL,
    major             VARCHAR(64)  NOT NULL,
    year              INTEGER      NOT NULL,
    university_status VARCHAR(32)  NOT NULL,
    role              VARCHAR(64)  NOT NULL,
    -- Never leaves the applicant-side services: absent from every REST response and gRPC message.
    deception         VARCHAR(32)  NOT NULL,
    originated_here   BOOLEAN      NOT NULL,
    created_at        TIMESTAMPTZ  NOT NULL
);

CREATE INDEX idx_applicants_session ON applicants (session_id, created_at);

CREATE TABLE applicant_courses (
    applicant_id UUID        NOT NULL REFERENCES applicants (applicant_id) ON DELETE CASCADE,
    course       VARCHAR(64) NOT NULL
);

CREATE INDEX idx_applicant_courses_applicant ON applicant_courses (applicant_id);

-- Idempotency guard for the propagation events. One row per applicant means an applicant is
-- initialized exactly once, however many of the three events arrive or get redelivered.
CREATE TABLE processed_events (
    applicant_id UUID        PRIMARY KEY,
    source_event VARCHAR(64) NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL
);
