/* ============================================================================
   04-dev-compat-level-160.sql

   CORECSERP_002_DEV was at compatibility level 120 (SQL Server 2014) even
   though the instance engine is SQL Server 2022. sp_rpt_* procs in
   01-exec-overview-data-layer.sql use STRING_SPLIT (requires compat level
   130+) to split the @BranchCodes CSV parameter, which failed with
   "Invalid object name 'STRING_SPLIT'" under level 120.

   Applied to CORECSERP_002_DEV on 2026-09-11. NOT applied to
   CORECSJFC2026_STAGING — that needs explicit developer approval first per
   the DB change protocol, since it is a database-wide engine setting (can
   shift query plans for the whole ERP, not just reporting procs), not a
   change scoped to a single reporting object.
============================================================================ */

ALTER DATABASE CORECSERP_002_DEV SET COMPATIBILITY_LEVEL = 160;
GO
