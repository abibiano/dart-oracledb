---
stepsCompleted: [1, 2, 3, 4, 5, 6]
inputDocuments:
  - 'docs/analysis/brainstorming-session-2025-12-14.md'
  - 'docs/dart-oracledb-porting-checklist.md'
workflowType: 'product-brief'
lastStep: 6
project_name: 'dart-oracledb'
user_name: 'Alex'
date: '2025-12-14'
status: 'complete'
---

# Product Brief: dart-oracledb

**Date:** 2025-12-14
**Author:** Alex

---

## Executive Summary

**dart-oracledb** is a pure Dart Oracle Database driver implementing the thin-mode TNS/TTC wire protocol. It enables Dart and Flutter developers to connect directly to Oracle databases without requiring Oracle Client installation or native dependencies.

The project addresses a critical gap in the Dart ecosystem: enterprise developers currently have no viable path to Oracle connectivity. The only existing package is abandoned and requires the Oracle thick client, which doesn't work on Apple Silicon and adds deployment complexity.

By porting the official node-oracledb thin driver architecture to Dart, this project brings Oracle database access to Dart backend frameworks (like Serverpod) and desktop applications, with the same developer experience as established packages like `package:postgres` or `package:sqlite3`.

---

## Core Vision

### Problem Statement

Dart and Flutter enterprise developers cannot connect to Oracle databases. The only existing Dart Oracle package is abandoned, unmaintained, and requires the Oracle thick client—a native dependency that fails on Apple Silicon and complicates cross-platform deployment.

### Problem Impact

- **No Oracle option for Dart backends**: Frameworks like Serverpod cannot serve enterprises using Oracle
- **Forced architectural complexity**: Developers must add REST API middleware layers just to reach Oracle
- **Platform exclusion**: Apple Silicon developers are completely blocked
- **Ecosystem gap**: Dart has mature drivers for PostgreSQL, MySQL, SQLite—but not Oracle

### Why Existing Solutions Fall Short

| Solution | Limitation |
|----------|------------|
| Existing Dart package | Abandoned, requires thick client, no Apple Silicon support |
| REST API middleware | Adds latency, complexity, and another service to maintain |
| Other languages | Breaks pure-Dart architecture, complicates deployment |

### Proposed Solution

A pure Dart implementation of Oracle's thin-mode protocol (TNS/TTC), ported from the official node-oracledb driver. This provides:

- **Direct database connectivity** without Oracle Client installation
- **Cross-platform support** including Apple Silicon, Windows, Linux
- **Connection pooling** for production workloads
- **Full CRUD operations** with bind parameter support
- **PL/SQL execution** for stored procedures and functions
- **Oracle 23ai LTS compatibility** with modern authentication methods

### Key Differentiators

1. **Pure Dart** - Zero native dependencies, works everywhere Dart runs
2. **Thin Protocol** - Direct TNS/TTC wire protocol, no middleware required
3. **Oracle 23ai Ready** - Supports latest Oracle LTS with modern auth (SHA512/PBKDF2)
4. **Maintainable Architecture** - Mirrors official node-oracledb structure for long-term sustainability
5. **First-Class Dart API** - Idiomatic Dart interface matching ecosystem conventions

---

## Target Users

### Primary Users

**Enterprise Dart Developer**

Enterprise developers building backend services or desktop applications with Dart who need Oracle database connectivity.

**Profile:**

- Experienced developers working in enterprise environments
- Building with Dart backend frameworks (Serverpod, Dart Frog) or desktop applications
- Organization uses Oracle as primary database
- Comfortable with database drivers (familiar with postgres, sqlite3 packages)

**Current Pain:**

- No viable Dart Oracle driver exists
- Forced to add REST API middleware layers to reach Oracle
- Existing abandoned package requires thick client, fails on Apple Silicon
- Cannot adopt Dart for new projects that need Oracle connectivity

**Goals:**

- Connect directly to Oracle from Dart code
- Use familiar API patterns consistent with other Dart database packages
- Eliminate middleware complexity
- Deploy cross-platform without native dependencies

**What Success Looks Like:**

- "I added the dependency, configured my connection string, and my query just worked"
- API feels natural—like using `package:postgres` or `package:sqlite3`
- Can recommend Dart for enterprise projects without the Oracle caveat

### Secondary Users

N/A - No secondary user segments identified.

### User Journey

| Stage | Experience |
|-------|------------|
| **Discovery** | Searches pub.dev for "oracle" |
| **Evaluation** | Reads README, sees pure Dart / no native deps |
| **Onboarding** | Adds dependency, configures connection, writes first query |
| **Success Moment** | First query returns data—"it just works" |
| **Adoption** | Uses dart-oracledb directly in production |
| **Advocacy** | Recommends for enterprise Oracle projects |

---

## Success Metrics

### User Success Metrics

| Metric | Definition | Indicator |
|--------|------------|-----------|
| **Connection Success** | User connects to Oracle database | Connection established without errors |
| **CRUD Completion** | User performs all basic operations | INSERT, SELECT, UPDATE, DELETE work |
| **"It Works" Moment** | User's first query returns data | Query returns rows matching Oracle data |

**User Success Definition:**
A user has succeeded when they can add dart-oracledb to their project, configure a connection string, and execute their first query returning data—with the same ease as using `package:postgres` or `package:sqlite3`.

### Business Objectives

| Objective | Description |
|-----------|-------------|
| **Production Reliability** | Package works reliably in author's own production environment |
| **Community Adoption** | Growing downloads and engagement on pub.dev |
| **Ecosystem Recognition** | Becomes the go-to Oracle solution for Dart developers |

### Key Performance Indicators

**Technical KPIs:**

- All core integration tests passing against Oracle 23ai
- Connection, pooling, CRUD, and PL/SQL execution working
- Cross-platform verified (macOS Apple Silicon, Windows, Linux)

**Adoption KPIs:**

- pub.dev downloads trending upward
- pub.dev likes indicating developer satisfaction
- GitHub issues/PRs showing community engagement

**Quality KPIs:**

- Zero critical bugs in production use
- API consistency with Dart database package conventions
- Documentation sufficient for onboarding without support

---

## MVP Scope

### Core Features

**Connection & Authentication:**

- Connect to Oracle 23ai with modern authentication (SHA512/PBKDF2)
- EZ Connect string parsing (host:port/service)
- TLS/SSL support
- Connection timeout handling

**Connection Pooling:**

- Min/max pool size configuration
- Connection acquisition and release
- Pool timeout and cleanup
- Session tagging support

**CRUD Operations:**

- SELECT, INSERT, UPDATE, DELETE execution
- Bind parameter support (positional and named)
- Transaction management (commit, rollback)
- Statement caching for performance

**PL/SQL Execution:**

- Call stored procedures
- Call functions with return values
- IN/OUT/IN OUT parameter binding

**Data Types:**

- VARCHAR/VARCHAR2, CHAR
- NUMBER (integers and decimals)
- DATE, TIMESTAMP
- CLOB/BLOB (basic read/write as values)
- RAW
- JSON

### Out of Scope for MVP

| Feature | Rationale | Target Phase |
|---------|-----------|--------------|
| Advanced LOB operations | Streaming, chunked I/O, temporary LOBs | Phase 3 |
| DB Objects | Oracle object types and collections | Phase 3 |
| Advanced Queuing (AQ) | Message queue operations | Phase 4 |
| Vector type | Oracle 23c AI vector support | Phase 4 |
| SODA | Document store API | Phase 4 |
| XA Transactions | Two-phase commit | Phase 4 |
| DRCP | Database Resident Connection Pooling | Future |

### MVP Success Criteria

The MVP is successful when:

1. **Core functionality works:** Connect, pool, CRUD, PL/SQL all passing integration tests
2. **Production ready:** Author successfully uses it in own production environment
3. **Cross-platform verified:** Works on macOS (Apple Silicon), Windows, Linux
4. **Oracle 23ai compatible:** Connects and operates with latest Oracle LTS
5. **Developer experience:** API feels familiar to users of package:postgres

### Future Vision

**Phase 3 - Extended Features:**

- Advanced LOB streaming (chunked read/write, temporary LOBs)
- DB Object support (Oracle object types, collections)
- Enhanced JSON capabilities

**Phase 4 - Advanced Features:**

- Advanced Queuing (AQ) for message-based applications
- Vector type support for Oracle 23ai AI workloads
- SODA document store API
- XA transaction support

**Long-term:**

- Serverpod integration package
- Performance optimizations (AOT compilation guidance)
- Community-driven feature expansion
- Potential mobile platform support investigation
