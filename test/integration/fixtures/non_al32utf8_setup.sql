-- Story 10.3 - local-only non-AL32UTF8 test fixture provisioning.
--
-- Creates a WE8MSWIN1252 (single-byte Western) pluggable database inside the
-- gvenzl/oracle-free CDB, whose root is AL32UTF8. The fixture is needed because
-- every readily available Oracle 23ai/26ai Free image ships a PREBUILT
-- AL32UTF8 database and ignores ORACLE_CHARACTERSET, so there is no image-level
-- way to get a non-AL32UTF8 database character set.
--
-- A seed-created PDB inherits the CDB's AL32UTF8 charset (CREATE PLUGGABLE
-- DATABASE has no CHARACTER SET clause), so this script migrates the fresh,
-- still-empty PDB down to WE8MSWIN1252 with the CSALTER bypass
-- (ALTER DATABASE CHARACTER SET INTERNAL_USE). That bypass is normally unsafe
-- (AL32UTF8 is not a binary superset of WE8MSWIN1252), but it is correct here
-- because the PDB contains only its freshly cloned data dictionary - all ASCII,
-- identical bytes under both character sets.
--
-- gvenzl runs files under /container-entrypoint-initdb.d as `sqlplus / as
-- sysdba` against CDB$ROOT on FIRST database init only, which is exactly the
-- privilege and container this migration needs. The optional `non-al32utf8`
-- docker-compose profile bind-mounts this file there.
--
-- This helper is also wired into CI as the manual `integration-non-al32utf8`
-- job in .github/workflows/ci.yml (Story 10.5). The README support matrix and
-- CONTRIBUTING.md document the local and CI usage.

WHENEVER SQLERROR EXIT SQL.SQLCODE
SET ECHO OFF

-- Fresh PDB from the seed (inherits AL32UTF8). FILE_NAME_CONVERT is required
-- because the gvenzl FREE database does not use Oracle Managed Files.
CREATE PLUGGABLE DATABASE we8pdb1
  ADMIN USER we8admin IDENTIFIED BY testpassword
  FILE_NAME_CONVERT = ('/opt/oracle/oradata/FREE/pdbseed/',
                       '/opt/oracle/oradata/FREE/we8pdb1/');
SET ECHO ON

-- Restricted mode is required so the character-set change has exclusive access.
ALTER PLUGGABLE DATABASE we8pdb1 OPEN RESTRICTED FORCE;
ALTER SESSION SET CONTAINER = we8pdb1;

-- ALTER DATABASE CHARACTER SET fails with ORA-12721 if any non-background
-- session is attached to the PDB; clear stragglers first.
DECLARE
  remaining_sessions PLS_INTEGER;
BEGIN
  FOR attempt IN 1..30 LOOP
    SELECT COUNT(*) INTO remaining_sessions
      FROM v$session
      WHERE con_id = SYS_CONTEXT('USERENV', 'CON_ID')
        AND sid <> SYS_CONTEXT('USERENV', 'SID')
        AND type <> 'BACKGROUND';

    EXIT WHEN remaining_sessions = 0;

    FOR s IN (
      SELECT sid, serial# FROM v$session
      WHERE con_id = SYS_CONTEXT('USERENV', 'CON_ID')
        AND sid <> SYS_CONTEXT('USERENV', 'SID')
        AND type <> 'BACKGROUND'
    ) LOOP
      BEGIN
        EXECUTE IMMEDIATE
          'ALTER SYSTEM KILL SESSION ''' || s.sid || ',' || s.serial# ||
          ''' IMMEDIATE';
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END LOOP;

    DBMS_LOCK.SLEEP(1);
  END LOOP;

  SELECT COUNT(*) INTO remaining_sessions
    FROM v$session
    WHERE con_id = SYS_CONTEXT('USERENV', 'CON_ID')
      AND sid <> SYS_CONTEXT('USERENV', 'SID')
      AND type <> 'BACKGROUND';

  IF remaining_sessions > 0 THEN
    RAISE_APPLICATION_ERROR(
      -20001,
      'Timed out waiting for sessions to detach before charset migration'
    );
  END IF;
END;
/

ALTER DATABASE CHARACTER SET INTERNAL_USE WE8MSWIN1252;

-- Reopen read-write and make the open mode survive container restarts so the
-- we8pdb1 service is available on every `up`.
ALTER SESSION SET CONTAINER = CDB$ROOT;
ALTER PLUGGABLE DATABASE we8pdb1 CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE we8pdb1 OPEN READ WRITE;
ALTER PLUGGABLE DATABASE we8pdb1 SAVE STATE;

-- Confirm the result in the container logs.
ALTER SESSION SET CONTAINER = we8pdb1;
SELECT value AS we8pdb1_charset
  FROM nls_database_parameters
  WHERE parameter = 'NLS_CHARACTERSET';
