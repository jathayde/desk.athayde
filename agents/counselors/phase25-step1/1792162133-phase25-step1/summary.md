# Run Summary

**Prompt:** file:prompt.md
**Tools:** claude-opus, gemini-3-pro
**Policy:** read-only=enforced

## Results

### ✓ claude-opus

- Status: success
- Duration: 492.3s
- Word count: 938
- Key sections:
  - Invariant breaks
  - Crashes and stale data
  - Races and audit accuracy
  - Specs that don't test what they name, and gaps
  - Lower priority

### ✗ gemini-3-pro

- Status: error
- Duration: 1.2s
- Word count: 0
- Error: Warning: --allowed-tools cli argument and tools.allowed in settings.json are deprecated and will be removed in 1.0: Migrate to Policy Engine: https://geminicli.com/docs/core/policy-engine/
Error authenticating: FatalAuthenticationError: Manual authorization is required but the current session is non-interactive. Please run the Gemini CLI in an interactive terminal to log in, provide a GEMINI_API_KEY, or ensure Application Default Credentials are configured.
    at initOauthClient (file:///opt/ho
