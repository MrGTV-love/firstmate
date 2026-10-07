Captain, this is a **design proposal only**; skill advice does not authorize implementation or test execution.

### Signup API
- **`POST /v1/signups`**, accepting JSON `{email, password}` over HTTPS. Enforce request-size limits, supported content type, an explicit field allowlist, and server-side validation.
- Validate email syntax and length without revealing whether an account exists. Define canonicalization consistently with account uniqueness; do not indiscriminately lowercase the local part.
- Allow long passwords and password-manager paste; reject passwords outside documented length bounds without trimming or silently truncating them.
- Hash passwords with a memory-hard password hash and a unique salt. Never log passwords, verification tokens, or raw request bodies.
- Create pending accounts atomically under a uniqueness constraint. Verification tokens must expire and be single-use; verification is required before account activation.
- Return the same **`202 Accepted`** response for eligible new and existing addresses: “If this address can be registered, check your email.” Avoid account-existence leaks through error text or materially different processing.
- Use **`400`** for malformed JSON, **`413`** for oversized requests, **`415`** for unsupported content types, **`422`** for field-validation failures, and **`429`** with `Retry-After` for rate limits. Apply abuse controls without exposing account existence.

### Validation errors and accessibility
Return stable machine-readable codes and human-readable messages, never echoed passwords or internal diagnostics:

```json
{
  "code": "validation_failed",
  "errors": [
    {
      "field": "email",
      "code": "invalid_format",
      "message": "Enter a valid email address."
    }
  ]
}
```

The client should associate errors with labelled controls using `aria-describedby` and `aria-invalid`, show a keyboard-accessible summary linking to invalid fields, and announce submission failures once through an appropriate live region. Choose one focus/announcement strategy to avoid duplicate announcements. Preserve entered values without persisting the password.

### Behavioral regression cases
- Malformed JSON, incorrect types, unknown fields, and oversized input produce the documented errors without creating an account.
- Passwords at both length boundaries are accepted; outside values are rejected without truncation or disclosure.
- Multiple invalid fields produce field-specific errors with stable codes.
- New-address and existing-address submissions have indistinguishable public outcomes.
- Concurrent equivalent submissions create at most one account and no inconsistent verification state.
- Expired or reused verification tokens cannot activate an account.
- Rate-limited requests receive `429` and cannot bypass limits through email formatting variants.
- Keyboard and screen-reader users can discover the failure, navigate to each invalid control, and hear relevant errors without duplicate announcements.
- Captured logs and error responses contain no passwords or verification tokens.

### Bodies actually read
All four complete bodies were read under  
`/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4A076ZYT1X4K1Z65KBR0AY2/.live-validation/gate-skill-picker/catalog/`:

- `safety-review/SKILL.md` — required.
- `input-validation/SKILL.md` — suggested.
- `regression-tests/SKILL.md` — suggested; applied to case design, not executable tests.
- `accessibility/SKILL.md` — suggested and independently relevant to error announcements.

**Independently added workflow:** none; accessibility was already suggested. Only read operations were performed; the proposed behavior and regression cases were not executed.