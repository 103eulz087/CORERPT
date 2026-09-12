# CORE Reporting Portal — Setup & Deployment

Executive Overview module. ASP.NET Core 8 MVC + Razor, ECharts, ClosedXML.
Server-rendered, cookie auth, polling refresh. No WinForms, no DevExpress.

---

## What's in this package

```
CoreReporting/
  Program.cs                     app startup, DI, auth, startup safety guards
  CoreReporting.csproj           net8.0; SqlClient + ClosedXML
  Models/ReportModels.cs         filter context + one DTO per SP result set
  Data/ReportRepository.cs       ADO.NET calls into the sp_rpt_* procedures
  Services/…DashboardService.cs  assembles + briefly caches the dashboard
  Controllers/…Controller.cs     dashboard, filter, JSON poll, Excel, health, auth
  Views/                         Razor: layout, executive, health, login
  wwwroot/css/site.css           the cold-storage design system
  wwwroot/js/exec-dashboard.js   ECharts + 5-minute polling
```

The SQL side ships separately as the three files you already have:
`01-exec-overview-data-layer.sql`, `02-…`, `03-…`. **Run `01` on the
database before the app will return anything.**

---

## Part A — One-time server preparation

Do these once on the Windows Server. None depends on the app being built yet.

### A1. Install the .NET 8 Hosting Bundle
This is the piece people forget. Not the SDK, not the runtime alone — the
**Hosting Bundle**, which installs the runtime *and* the IIS module (ANCM)
that lets IIS host .NET apps.

Download "ASP.NET Core Runtime 8.x — Hosting Bundle" from Microsoft, install,
then from an elevated command prompt:

```
net stop was /y
net start w3svc
```

Verify: `dotnet --info` should list `Microsoft.AspNetCore.App 8.x`.

### A2. Enable IIS (if not already)
Server Manager → Add Roles and Features → Web Server (IIS). Under role
services make sure these are checked:
- Web Server → Common HTTP Features → Static Content, Default Document
- Web Server → Health and Diagnostics → HTTP Logging
- Web Server → Security → Request Filtering
- Web Server → Application Development → **WebSocket Protocol** is *not*
  required (we don't use it)

### A3. Create a read-only SQL login for the portal
The portal only ever runs `SELECT` and `EXEC` on `sp_rpt_*`. Give it nothing
more. A reporting portal with write access to your ledger is a bad day
waiting to happen.

```sql
USE [master];
CREATE LOGIN rpt_reader WITH PASSWORD = 'use-a-strong-secret-here';
GO
USE [CORECSJFC2026];
CREATE USER rpt_reader FOR LOGIN rpt_reader;

-- read + execute the reporting surface only
GRANT SELECT ON SCHEMA::dbo TO rpt_reader;      -- reports read base tables
GRANT EXECUTE ON dbo.sp_rpt_Exec_Summary         TO rpt_reader;
GRANT EXECUTE ON dbo.sp_rpt_Exec_SalesTrend      TO rpt_reader;
GRANT EXECUTE ON dbo.sp_rpt_Exec_BranchScorecard TO rpt_reader;
GRANT EXECUTE ON dbo.sp_rpt_Exec_FlowBar         TO rpt_reader;
GRANT EXECUTE ON dbo.sp_rpt_DataHealthCheck      TO rpt_reader;

-- explicitly deny writes, belt and suspenders
DENY INSERT, UPDATE, DELETE ON SCHEMA::dbo TO rpt_reader;
GO
```

If you prefer even tighter scope, drop the schema-wide `GRANT SELECT` and
instead grant SELECT only on the specific tables the procs touch
(`TicketMaster`, `TicketDetails`, `ChartOfAccounts`, `Branch`,
`RptMnemonicMap`) plus the `vw_AccountTree` view.

---

## Part B — Publish from your dev machine

On the machine where you have the .NET 8 SDK:

```
cd CoreReporting
dotnet publish -c Release -o .\publish
```

That produces a self-contained-enough folder in `.\publish`. Copy that whole
folder to the server, e.g. `C:\inetpub\CoreReporting`.

> First build restores `Microsoft.Data.SqlClient` and `ClosedXML` from NuGet,
> so the dev machine needs internet once. The server does not.

---

## Part C — Configure the IIS site

### C1. App pool
IIS Manager → Application Pools → Add Application Pool:
- Name: `CoreReporting`
- .NET CLR version: **No Managed Code** ← counterintuitive but correct.
  .NET Core runs out-of-process; the ANCM module handles it, so IIS itself
  loads no CLR.
- Start mode: AlwaysRunning (optional, avoids first-hit cold start)

### C2. The site
IIS Manager → Sites → Add Website:
- Site name: `CoreReporting`
- Physical path: `C:\inetpub\CoreReporting\publish`
- Application pool: `CoreReporting`
- Binding: pick a port (e.g. 8080) or a hostname if you have DNS

### C3. The connection string — as an environment variable, not in a file
Do **not** put the production connection string in `appsettings.json`. Set it
on the app pool so it never lands in source control or a copied folder.

The cleanest way on IIS is the app pool environment. From an elevated
PowerShell:

```powershell
Import-Module WebAdministration

$pool = "CoreReporting"
Add-WebConfigurationProperty -pspath "MACHINE/WEBROOT/APPHOST" `
  -location $pool `
  -filter "system.applicationHost/applicationPools/add[@name='$pool']/environmentVariables" `
  -name "." -value @{
    name  = "ConnectionStrings__Erp"
    value = "Server=YOUR_SQL_HOST;Database=CORECSJFC2026;User Id=rpt_reader;Password=YOUR_SECRET;TrustServerCertificate=True;Encrypt=True;Application Name=CoreReportingPortal"
  }
```

> The double underscore in `ConnectionStrings__Erp` is how .NET maps an
> environment variable to the nested config key `ConnectionStrings:Erp`.

Recycle the pool after setting it:
```
Restart-WebAppPool -Name "CoreReporting"
```

### C4. Folder permissions
Give the app pool identity read access to the publish folder:
```
icacls "C:\inetpub\CoreReporting\publish" /grant "IIS AppPool\CoreReporting:(OI)(CI)RX"
```

---

## Part D — Wire real authentication

The app ships with a **development-only** auth stub so it runs before you
connect it to your ERP users. `Program.cs` refuses to start if that stub is
left enabled outside Development, so you cannot ship it by accident.

Open `Controllers/DashboardController.cs`, find `ErpUserAuthenticator.
ValidateAsync`, and replace its body with a lookup against your ERP user
table using your existing password hashing. Return the user's department as
the role string — one of: `Executive`, `Sales`, `Marketing`, `Operations`,
`Accounting`, `Audit`. The `[Authorize(Roles = …)]` filters already do the
rest.

Until then, to demo locally: set `ASPNETCORE_ENVIRONMENT=Development`, and the
stub in `appsettings.Development.json` lets you sign in as `exec` / `acct` /
`audit` / `admin` with password `dev`.

---

## Part E — First run checklist

1. Run `01-exec-overview-data-layer.sql` against `CORECSJFC2026`.
2. Run `03-health-check-v2-and-findings.sql` Section A + B (adds the module
   mnemonics, upgrades the health check).
3. Browse to the site. You should land on the login page.
4. Sign in. The Executive board should paint the flow bar, four KPI tiles,
   the 13-month trend, and the branch grid.
5. Open **Health Check** from the sidebar. Confirm criticals are zero on real
   data before anyone trusts the figures.
6. Click **Refresh** — the "as of" time should update. Wait 5 minutes and it
   should poll on its own.
7. Click **Export** on the branch scorecard — an .xlsx should download with
   leading zeros intact on branch codes.

---

## Notes on what is and isn't wired

- **Flow bar, two stages pending.** "Open POs" and "Open Orders" show a dash,
  not a zero, because those are commitments that never hit the general
  ledger. They light up the moment you send the purchase-order and
  sales-order header tables.
- **Receivables is trade balance, not aged.** The KPI shows the AR-trade
  ledger balance. True aging needs the invoice-level tables; that's the
  Accounting module.
- **Caching.** Dashboard results cache for 2 minutes keyed on the filter, so
  many users viewing the same month share one query. Refresh bypasses it.
- **Roles today.** Executive, Accounting, and Audit can all see the executive
  board and the health check. Tighten or widen in the `[Authorize]`
  attributes as you add the other departments.
