# CORE Reporting Portal

Read-only reporting & analytics portal over the CORECSJFC2026 meat-trading ERP.
ASP.NET Core 8 MVC + Razor, ADO.NET, ECharts, ClosedXML. Deployed to IIS.

## Start here
- **CLAUDE.md** — project memory, hard rules, DB connections, the team. Read first.
- **.claude/db.local.md** — credentials (gitignored; created locally).
- **docs/** — design previews + module briefs.
- **sql/** — all DDL, reviewable and replayable.
- **DEPLOYMENT.md** — IIS deployment walkthrough.

## Working in Claude Code
The `.claude/` folder defines the software team and playbooks:
- Agents: db-report-engineer, backend-dev, frontend-dev, accounting-reviewer.
- Skills: db-change-protocol, aging-sp-pattern, statement-renderer,
  new-report-module.

Typical flow for a new report: agree the design (docs/) → db-report-engineer
writes the SP against CORECSERP_002_DEV → backend-dev wires repo/service/
controller → frontend-dev builds the view → accounting-reviewer verifies any
financial numbers.

## Build
```
dotnet build
dotnet run                    # uses appsettings.Development.json -> DEV db
dotnet publish -c Release -r win-x64 --self-contained false -o ./publish
```

## Current status
Executive Overview: built + deployed. Accounting (aging + Report Center): next,
brief in docs/brief-accounting-module.md.
