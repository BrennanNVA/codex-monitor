# Security Policy

## Reporting

Please report suspected vulnerabilities privately through GitHub's security-advisory feature rather than a public issue.

## Data boundaries

Codex Monitor reads local Codex session metadata and token-count records. It must never display, log, transmit, or persist session prompts, responses, tool arguments, credentials, or source-file contents. Reports involving accidental disclosure of session content are security issues.

The monitor performs no network requests and does not modify Codex sessions or monitored repositories.
