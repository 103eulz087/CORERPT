using System.Text.Json;
using CoreReporting.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace CoreReporting.Controllers;

/// <summary>
/// Base for controllers that read the top-bar filter (Period + Branch)
/// persisted in session. Shared by DashboardController (Executive) and
/// AccountingController (Finance Overview) so Period/Branch survive
/// navigation between modules, not just within one. Factored out here
/// rather than duplicated, and rather than made public on one controller
/// for the other to reach into.
/// </summary>
[Authorize]
public abstract class FilterAwareController : Controller
{
    private const string FilterSessionKey = "core.filter";

    protected FilterContext CurrentFilter
    {
        get
        {
            var json = HttpContext.Session.GetString(FilterSessionKey);
            if (string.IsNullOrEmpty(json)) return FilterContext.CurrentMonth();
            try
            {
                return JsonSerializer.Deserialize<FilterContext>(json)
                       ?? FilterContext.CurrentMonth();
            }
            catch
            {
                return FilterContext.CurrentMonth();
            }
        }
        set => HttpContext.Session.SetString(FilterSessionKey, JsonSerializer.Serialize(value));
    }
}
