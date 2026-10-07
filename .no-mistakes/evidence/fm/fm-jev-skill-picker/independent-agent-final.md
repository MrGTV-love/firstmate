Captain, the shortlist omitted **`api-design`**, which directly applies to the requested HTTP contract; I independently added and read it. Required safety advice and all three suggested bodies were also read. `database-migrations` and `release-notes` are out of scope: this is a design-only assessment, with no schema or release change. The fixture bodies provide relevance guidance, not detailed implementation rules; the proposal below applies independent judgment.

## Signup contract

**`POST /v1/signups`**, over HTTPS, with `Content-Type: application/json`. Limit the body to **16 KiB**.

```json
{
  "email": "person@example.com",
  "password": "a long unique passphrase"
}
```

- Require both fields as strings; reject nulls, unknown fields, and duplicate JSON keys.
- **Email:** trim surrounding whitespace, validate supported email syntax, and limit the resulting UTF-8 value to 254 bytes. Lowercase the domain; do not silently remove dots, plus-tags, or lowercase the local part. Use the same identity comparison policy throughout signup and login.
- **Password:** allow 15–128 Unicode code points, including spaces; never trim, normalize, or truncate. Do not impose character-class rules. Reject known-compromised passwords using a check that does not disclose the plaintext.
- Perform authoritative validation server-side. Client checks are only usability aids.

### Accepted request

For both a new address and an already registered address, return the same status and body:

```http
HTTP/1.1 202 Accepted
Content-Type: application/json
Cache-Control: no-store
```

```json
{
  "status": "verification_required",
  "message": "Check your email for the next step."
}
```

This acknowledges processing, **not account creation or authentication**. Do not return an account identifier or session token. Activate a new account only after verification; a repeated signup must never replace an existing account’s password.

Use expiring, single-use verification tokens, store only token hashes, and throttle email delivery. Keep duplicate-address responses and processing observably consistent as far as practical; the response alone does not eliminate timing or delivery side channels.

## Validation and operational errors

Return `application/problem+json`, with stable codes and safe human-readable messages:

```json
{
  "type": "urn:problem:signup-validation",
  "title": "Check the highlighted fields.",
  "status": 422,
  "errors": [
    {
      "field": "email",
      "code": "invalid_email",
      "message": "Enter a valid email address."
    },
    {
      "field": "password",
      "code": "too_short",
      "message": "Use at least 15 characters."
    }
  ]
}
```

| Status | Meaning |
|---|---|
| `400` | Malformed JSON, including duplicate keys |
| `413` | Body exceeds the size limit |
| `415` | Unsupported media type |
| `422` | Invalid fields: `required`, `invalid_type`, `unknown_field`, `invalid_email`, `too_short`, `too_long`, or `compromised_password` |
| `429` | Rate limited; include `Retry-After` |
| `503` | Temporarily unable to accept processing; include `Retry-After` when known |

Never echo passwords, tokens, submitted values, stack traces, or account-existence information in errors or logs. Use vetted password hashing and parameterized persistence. Apply abuse controls to signup and verification; protect browser-origin requests against unwanted cross-origin submissions, with CSRF protection where cookies confer authority.

## Accessible failure flow

- Use persistent labels, `autocomplete="email"` and `autocomplete="new-password"`, and keyboard-operable controls.
- After validation fails, focus a concise error summary with links to affected inputs. Associate inline errors using `aria-describedby` and mark invalid inputs with `aria-invalid="true"`.
- Explain errors in text, not color alone. Preserve email and keep the password only in current-page memory for correction—never browser storage or telemetry.
- Announce pending and accepted outcomes through a polite status region without duplicate announcements.
- For network failures, rate limits, and service errors, show a form-level message and restore submission controls. Make retry keyboard-accessible; never claim success after a timeout.

## Behavioral regression cases

These are proposed cases, **not executed tests**:

- Required, wrong-type, unknown-field, malformed-JSON, and duplicate-key inputs produce the specified errors without persistence.
- Password lengths 14, 15, 128, and 129 exercise exact boundaries; spaces and Unicode remain unchanged.
- Email trimming and domain casing follow policy; plus-tags and local-part casing are not silently rewritten.
- New and existing addresses receive identical public responses; existing credentials remain unchanged.
- Expired, reused, or tampered verification tokens cannot activate an account.
- Oversized bodies and unsupported content types are rejected; throttling supplies retry guidance.
- Errors and logs contain no secrets or submitted-value echoes.
- Keyboard and screen-reader checks confirm summary focus, field associations, retained input, retry access, and status announcements.

## Exact paths actually read

All five bodies were read in full:

```text
/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4A076ZYT1X4K1Z65KBR0AY2/.live-validation/gate-skill-picker/catalog/safety-review/SKILL.md
/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4A076ZYT1X4K1Z65KBR0AY2/.live-validation/gate-skill-picker/catalog/input-validation/SKILL.md
/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4A076ZYT1X4K1Z65KBR0AY2/.live-validation/gate-skill-picker/catalog/api-design/SKILL.md
/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4A076ZYT1X4K1Z65KBR0AY2/.live-validation/gate-skill-picker/catalog/regression-tests/SKILL.md
/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4A076ZYT1X4K1Z65KBR0AY2/.live-validation/gate-skill-picker/catalog/accessibility/SKILL.md
```

Only read tools were used; no files were changed, commands run, or network requests made.