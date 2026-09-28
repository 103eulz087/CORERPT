using CoreReporting.Models;
using CoreReporting.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace CoreReporting.Controllers;

/// <summary>
/// "Hey Jude" — a dedicated natural-language Q&amp;A page (chat + chart) over
/// a small whitelist of report intents (see HeyJudeService). Gated the same
/// as every other reporting route in this portal: role-based, read-only, no
/// state changes — the question just picks which existing sp_rpt_* call to
/// make and how to chart the result.
/// </summary>
[Authorize(Roles = "Executive,Accounting,Audit")]
public sealed class HeyJudeController : Controller
{
    private readonly HeyJudeService _heyJude;

    public HeyJudeController(HeyJudeService heyJude) => _heyJude = heyJude;

    [HttpGet]
    public IActionResult Index() => View();

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Ask([FromBody] HeyJudeRequest request, CancellationToken ct)
    {
        var result = await _heyJude.AskAsync(request.Question, ct);
        return Json(result);
    }
}
