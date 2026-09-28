using CoreReporting.Controllers;
using CoreReporting.Data;
using CoreReporting.Services;
using Microsoft.AspNetCore.Authentication.Cookies;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddControllersWithViews();
builder.Services.AddMemoryCache();

builder.Services.AddDistributedMemoryCache();
builder.Services.AddSession(o =>
{
    o.Cookie.Name = "core.session";
    o.Cookie.HttpOnly = true;
    o.Cookie.IsEssential = true;
    o.IdleTimeout = TimeSpan.FromHours(8);
});

builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(o =>
    {
        o.Cookie.Name = "core.auth";
        o.Cookie.HttpOnly = true;
        o.LoginPath = "/Account/Login";
        o.LogoutPath = "/Account/Logout";
        o.AccessDeniedPath = "/Account/Login";
        o.ExpireTimeSpan = TimeSpan.FromHours(8);
        o.SlidingExpiration = true;
    });

builder.Services.AddAuthorization();

// JSON POSTs (Hey Jude) carry the antiforgery token as a header, not a form
// field — see the meta tag in _Layout.cshtml and wwwroot/js/hey-jude.js.
builder.Services.AddAntiforgery(o => o.HeaderName = "X-CSRF-TOKEN");

builder.Services.AddScoped<IReportRepository, SqlReportRepository>();
builder.Services.AddScoped<IUserAuthenticator, ErpUserAuthenticator>();
builder.Services.AddScoped<ExecutiveDashboardService>();
builder.Services.AddScoped<AccountingDashboardService>();
builder.Services.AddScoped<SalesDashboardService>();
builder.Services.AddScoped<ExceptionCenterService>();
builder.Services.AddScoped<ItemCostingReconService>();

// Hey Jude: optional natural-language front end (see HeyJudeService). Left
// unconfigured (no Anthropic:ApiKey) it degrades to a friendly message
// rather than blocking startup — unlike the Erp connection string, this
// feature is not core to a read-only reporting portal.
builder.Services.AddHttpClient<HeyJudeService>(c =>
{
    c.BaseAddress = new Uri("https://api.anthropic.com/");
    c.Timeout = TimeSpan.FromSeconds(20);
});

var app = builder.Build();

/* --------------------------------------------------------------------------
   Startup guards. Both of these fail fast rather than letting a
   misconfigured server run in a state that looks fine until it is not.
-------------------------------------------------------------------------- */

// 1. The dev auth stub must never be reachable outside Development.
if (!app.Environment.IsDevelopment() &&
    app.Configuration.GetValue<bool>("DevAuth:Enabled"))
{
    throw new InvalidOperationException(
        "DevAuth:Enabled is true outside Development. Wire ErpUserAuthenticator " +
        "to the real ERP user table before deploying.");
}

// 2. The connection string must exist. Better a startup crash with a clear
//    message than a 500 on the first dashboard load.
if (string.IsNullOrWhiteSpace(app.Configuration.GetConnectionString("Erp")))
{
    throw new InvalidOperationException(
        "Connection string 'Erp' is missing. On the server set the environment " +
        "variable ConnectionStrings__Erp rather than editing appsettings.json.");
}

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Home/Error");
    app.UseHsts();
}

app.UseStaticFiles();
app.UseRouting();

app.UseSession();
app.UseAuthentication();
app.UseAuthorization();

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=Dashboard}/{action=Executive}/{id?}");

app.Run();
