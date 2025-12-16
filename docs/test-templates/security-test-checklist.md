# Security Test Checklist (NFR5)

**Purpose:** Ensure credentials NEVER appear in logs, errors, or test output

**Epic 1 Context:** 3 security violations caught in code reviews (Stories 1.4, 1.5, 1.8)

**Team Agreement #3:** "Code reviews must check NFR5 (no credentials in logs/errors)"

---

## Story Information

**Story ID:** {Story ID}
**Feature:** {Feature Name}
**Date:** {Date}
**Developer:** {Name}
**Reviewer:** {Name}

---

## Security Requirements Checklist

### Credential Protection Tests

- [ ] **Password NEVER in logs during successful connection**
- [ ] **Password NEVER in logs during authentication failure**
- [ ] **Password NEVER in exception messages**
- [ ] **Username NEVER in logs** (also sensitive per Story 1.8)
- [ ] **Connection string NEVER in logs** (may contain credentials)
- [ ] **Crypto values properly encoded** (hex, uppercase, no plaintext)
- [ ] **Environment variables sanitized** (if logged)
- [ ] **Debug output scrubbed** (no credential leakage)

### Test Implementation

```dart
import 'dart:io';
import 'package:test/test.dart';
import 'package:dart_oracledb/dart_oracledb.dart';

@Tags(['security'])
group('NFR5: Credentials never logged - {Feature}', () {
  // Helper to capture log output
  String captureLogOutput(Function() fn) {
    // Implementation to capture logs
  }

  test('password not in logs during successful connection', () async {
    final logs = captureLogOutput(() async {
      await OracleConnection.connect(
        'localhost:1521/FREEPDB1',
        user: 'testuser',
        password: 'secretPassword123',
      );
    });

    expect(logs, isNot(contains('secretPassword123')));
    expect(logs, isNot(contains('password=')));
    expect(logs, isNot(contains('pwd=')));
    expect(logs, isNot(matches(r'pass\w*:')));
  });

  test('password not in logs during auth failure', () async {
    final logs = captureLogOutput(() async {
      await expectLater(
        () => OracleConnection.connect(
          'localhost:1521/FREEPDB1',
          user: 'testuser',
          password: 'WRONG_PASSWORD',
        ),
        throwsA(isA<OracleException>()),
      );
    });

    expect(logs, isNot(contains('WRONG_PASSWORD')));
    expect(logs, isNot(contains('password=')));
  });

  test('password not in exception messages', () async {
    try {
      await OracleConnection.connect(
        'localhost:1521/FREEPDB1',
        user: 'testuser',
        password: 'secretPassword123',
      );
      fail('Expected exception');
    } catch (e) {
      expect(e.toString(), isNot(contains('secretPassword123')));
      expect(e.toString(), isNot(contains('password')));
    }
  });

  test('username not in logs (also sensitive)', () async {
    final logs = captureLogOutput(() async {
      await OracleConnection.connect(
        'localhost:1521/FREEPDB1',
        user: 'sensitiveUsername',
        password: 'testpass',
      );
    });

    // Username also sensitive per Story 1.8 discovery
    expect(logs, isNot(contains('sensitiveUsername')));
    expect(logs, isNot(contains('user=')));
  });

  test('connection string not in logs', () async {
    final logs = captureLogOutput(() async {
      await OracleConnection.connect(
        'user/password@localhost:1521/FREEPDB1',
      );
    });

    expect(logs, isNot(contains('user/password@')));
    expect(logs, isNot(contains('password@')));
  });

  test('crypto values are encoded (not plaintext)', () async {
    final logs = captureLogOutput(() async {
      await OracleConnection.connect(
        'localhost:1521/FREEPDB1',
        user: 'testuser',
        password: 'testpass',
      );
    });

    // Verify crypto values are hex-encoded, not plaintext
    expect(logs, isNot(contains('testpass')));
  });

  test('environment variables sanitized in logs', () async {
    Platform.environment['ORACLE_PASSWORD'] = 'envPassword123';

    final logs = captureLogOutput(() async {
      // Code that might log environment
    });

    expect(logs, isNot(contains('envPassword123')));
  });

  test('debug output scrubbed of credentials', () async {
    // If debug logging enabled, verify no credentials
    Platform.environment['DEBUG'] = 'true';

    final logs = captureLogOutput(() async {
      await OracleConnection.connect(
        'localhost:1521/FREEPDB1',
        user: 'testuser',
        password: 'debugPassword',
      );
    });

    expect(logs, isNot(contains('debugPassword')));
  });
});
```

---

## Code Review Checklist

### Code Inspection

- [ ] **Log statements reviewed** - No credential variables logged
- [ ] **Exception messages reviewed** - No sensitive data in error messages
- [ ] **Debug output reviewed** - No credential exposure in debug mode
- [ ] **String interpolation reviewed** - No `"password: $password"` patterns
- [ ] **Error handling reviewed** - Errors don't leak credentials
- [ ] **Connection string handling** - Parsed safely without logging

### Common Patterns to Avoid

| Anti-Pattern | Correct Pattern |
|--------------|-----------------|
| `logger.info('Connecting with password: $password')` | `logger.info('Connecting to Oracle')` |
| `throw Exception('Auth failed for user $user')` | `throw OracleException('Authentication failed')` |
| `print('Connection string: $connStr')` | `print('Connection attempt')` |
| `logger.debug('Auth data: $authData')` | `logger.debug('Auth data prepared')` |
| `Exception('Failed: $username/$password')` | `OracleException('Authentication failed')` |

### Regex Patterns to Search For (Red Flags)

```bash
# Search for potential credential leaks
grep -r "password" lib/src/ | grep -i "log\|print\|debug\|error"
grep -r "user.*password" lib/src/
grep -r "credentials" lib/src/ | grep -i "log\|print"
```

---

## Manual Testing Checklist

- [ ] **Run tests with log capture** - Verify no credentials in output
- [ ] **Test with debug logging enabled** - Verify credentials still hidden
- [ ] **Test auth failures** - Verify password not in error messages
- [ ] **Test connection failures** - Verify connection string not exposed
- [ ] **Review test output manually** - Visual inspection for leaks

---

## Validation Results

### Test Execution

```bash
# Run security tests
dart test --tags=security

# Review output manually
dart test --tags=security 2>&1 | tee security-test-output.log

# Search for credential patterns in output
grep -i "password\|secret\|credential" security-test-output.log
```

### Manual Review

```bash
# Enable debug logging and check output
DEBUG=true RUN_INTEGRATION_TESTS=true dart test --tags=integration 2>&1 | grep -i "password"

# Should return NO matches
```

---

## Sign-Off

### Developer Certification

I certify that:
- [ ] All security tests passing
- [ ] Code reviewed for credential exposure
- [ ] Manual log review completed (no false positives)
- [ ] No credentials in logs, errors, or debug output

**Developer:** {Name}
**Date:** {Date}
**Signature:** ___________________

### Code Reviewer Certification

I have verified:
- [ ] Security tests comprehensive
- [ ] All tests passing
- [ ] Code inspection completed
- [ ] No credential exposure found

**Reviewer:** {Name}
**Date:** {Date}
**Status:** ✅ PASS / ❌ FAIL
**Comments:**

---

## Epic 1 Security Violations (Lessons Learned)

### Story 1.4: Password in Logs

**Issue:** Password logged during authentication debugging
**Fix:** Removed password from log statements
**Prevention:** Security checklist mandatory for auth code

### Story 1.5: Credentials in Error Messages

**Issue:** Connection string with credentials in exception message
**Fix:** Sanitized error messages
**Prevention:** Error handling review required

### Story 1.8: Username Exposure

**Issue:** Username logged (also sensitive)
**Discovery:** Username is ALSO sensitive, not just password
**Prevention:** All credentials (user + password) must be protected

---

## Reference: NFR5 Requirement

**NFR5: Credentials Never Logged**

> Passwords, usernames, and connection strings MUST NOT appear in log output, error messages, or debug output. All credential handling must be performed securely without exposure in any diagnostic output.

**Why This Matters:**
- Production logs are often stored in centralized systems
- Error messages may be displayed to users
- Debug output may be captured in CI/CD
- Security compliance requirements (SOC2, PCI-DSS)
- Protection against credential leakage in attacks

---

## Additional Resources

- [OWASP Logging Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html)
- [Epic 1 Retrospective](../../sprint-artifacts/epic-1-retro-2025-12-16.md)
- [Test Architecture](../test-architecture-dart-oracledb.md#security-edge-cases-nfr5---critical)

---

**Document Version:** 1.0
**Last Updated:** 2025-12-16
**Next Review:** After each Epic completion
