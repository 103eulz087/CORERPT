# Claude Code Brief — Sales Agent Scorecard

Extends the Sales module (designed in Phase 1, not yet built) and reuses the
aging pattern from the Accounting module. One scorecard per agent, combining
sales activity with the AR health of the accounts they own.

## Confirmed facts (from developer)

- Agent-to-account link is on the **customer master**: each customer has one
  assigned agent (`AccountOfficer` or similar — verify exact column name).
- **No sales targets/quotas exist yet.** Do not build a quota-attainment KPI.
  Leave a nullable `QuotaAmount` / `AttainmentPct` slot in the DTO so it can be
  added later without a schema break, but the UI shows trend and peer
  comparison instead of "% of quota" for now.
- Scope is a **combined scorecard**: sales performance + AR/collections
  accountability, not two separate views.

## Before writing any SQL — read the real schema, report back

1. Exact column names: the agent link on the customer master (`AccountOfficer`?),
   the agent master table itself (name, code, display name, active flag).
2. Confirm whether `TransactionChargeSales` (used for AR aging) carries the
   customer id needed to join back to the customer's assigned agent, or whether
   the join must go through an intermediate table.
3. Confirm whether sales postings (`TicketDetails`/`TicketMaster`) carry a
   customer reference that can join to the customer master for the agent link,
   or whether agent attribution for sales comes from elsewhere (e.g. the order/
   invoice header rather than the ledger).
4. **Ask the developer this before coding**: if a customer's assigned agent
   changes mid-period, should historical sales stay attributed to the agent who
   made them (recommended default — reassigning an account shouldn't retroactively
   change a past month's numbers), or should all of a customer's history follow
   them to the new agent? Confirm before building; this changes the join logic.

## `sp_rpt_Agent_Scorecard`

Parameter shape matches the rest of the portal:
`@DateFrom date, @DateTo date, @AgentCodes varchar(200) = NULL` (NULL/empty =
all agents).

Per agent, return:
- Net sales for the period + prior-period comparative (reuse the Exec Summary's
  prior-period pattern: same span, immediately before).
- Active accounts (ordered in the last 30 days) vs dormant accounts (assigned to
  this agent, no order in 30+ days) — counts and list.
- New accounts opened in the period (first-ever order date falls in range).
- AR outstanding total across their assigned accounts, and AR past due
  (reuse the bucket definitions from `sp_rpt_AR_Aging` — do not reinvent
  buckets; call or mirror that logic so the two reports never disagree).
- Agent-scoped DSO: computed only over their book, same formula as company DSO,
  so agents are comparable regardless of book size.
- Oldest open item age across their accounts.

Apply the standard hard rules: posted-only, BranchCode as varchar, explicit
CASTs on every output column, `>= @From AND < DATEADD(DAY,1,@To)` never BETWEEN.

## Repository / Service / Controller

Follow the existing pattern exactly (`GetAgentScorecardAsync`, `AgentScorecard`
DTO, `GetOrdinal` readers). This likely lives in a new `SalesDashboardService`
if the broader Sales module isn't built yet — check what already exists in the
project before creating a new service; don't duplicate the Executive one.

## View

A leaderboard-style table, sorted by net sales descending by default with a
toggle to sort by AR past due % (so a manager can flip between "who's selling"
and "whose book needs attention"). Oxblood pill on AR past due % above a
threshold (match the same 24%-ish scale used on the Accounting board, or ask
the developer for the house threshold). Dormant-account count as a smaller
amber pill next to each agent's name.

Roles: `Sales` (see their own row only — needs a "my accounts" filter tied to
the logged-in user's agent code once real auth is wired) plus
`Executive`/`Sales` management sees all agents. Confirm with developer whether
regular agents should see peers' numbers or only their own before finalizing
the authorization scope — this is a people-management decision, not a
technical one.

## Hand to accounting-reviewer before done

- Agent-scoped AR total, summed across all agents, should equal the company-wide
  AR total from `sp_rpt_AR_Aging` (minus any unassigned-customer accounts —
  flag those separately if they exist, don't silently drop them).
- Confirm no double-counting if a customer's orders span multiple branches but
  one agent.
