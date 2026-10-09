import Foundation

/// The phone page and the Scriptable widget source, kept inline so the app bundle needs no extra
/// resources. Both render usage with DOM text / widget text only; nothing from the JSON is ever
/// interpreted as HTML.
enum MobileUsagePages {
    static let html = #"""
    <!doctype html>
    <html lang="ko">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-title" content="Token Usage">
    <meta name="referrer" content="no-referrer">
    <title>Token Usage</title>
    <style>
    :root {
      --bg: #f5f5f7; --card: #ffffff; --text: #1d1d1f; --muted: #6e6e73; --track: #e5e5ea;
      --claude: #ff9500; --codex: #30b0c7; --router: #5856d6;
      --good: #34c759; --warn: #ff9500; --bad: #ff3b30;
    }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #000000; --card: #1c1c1e; --text: #f5f5f7; --muted: #98989d; --track: #3a3a3c; }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; background: var(--bg); color: var(--text);
      font: 15px/1.35 -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", sans-serif;
      padding: max(16px, env(safe-area-inset-top)) 16px max(24px, env(safe-area-inset-bottom));
    }
    header { display: flex; align-items: baseline; justify-content: space-between; margin: 4px 2px 12px; }
    h1 { font-size: 22px; margin: 0; }
    .meta { color: var(--muted); font-size: 12px; }
    .stale { color: var(--bad); }
    section { background: var(--card); border-radius: 14px; padding: 12px 14px; margin-bottom: 12px;
      border-left: 4px solid var(--accent); }
    h2 { font-size: 15px; margin: 0 0 6px; color: var(--accent); }
    .account { padding: 8px 0; border-top: 1px solid var(--track); }
    .account:first-of-type { border-top: 0; }
    .row { display: flex; align-items: center; gap: 8px; }
    .name { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 1; }
    .badge { font-size: 11px; font-weight: 600; padding: 2px 7px; border-radius: 999px;
      color: var(--accent); background: color-mix(in srgb, var(--accent) 16%, transparent); white-space: nowrap; }
    .windows { display: grid; grid-template-columns: repeat(var(--columns, 2), minmax(0, 1fr)); gap: 10px; margin-top: 6px; }
    .label { color: var(--muted); font-size: 12px; }
    .pct { font-size: 20px; font-weight: 700; font-variant-numeric: tabular-nums; }
    .bar { height: 4px; background: var(--track); border-radius: 2px; overflow: hidden; margin: 3px 0; }
    .bar > div { height: 100%; border-radius: 2px; }
    .reset { color: var(--muted); font-size: 11px; }
    .error { color: var(--bad); margin: 0 2px 12px; font-size: 13px; }
    </style>
    </head>
    <body>
    <header><h1>Token Usage</h1><span class="meta" id="refreshed"></span></header>
    <p class="error" id="error" hidden></p>
    <main id="main"></main>
    <script>
    const key = new URLSearchParams(location.search).get("k") || "";

    function el(tag, className, text) {
      const node = document.createElement(tag);
      if (className) node.className = className;
      if (text !== undefined && text !== null) node.textContent = text;
      return node;
    }
    function tone(percent) {
      if (percent == null) return "var(--track)";
      if (percent <= 10) return "var(--bad)";
      if (percent <= 30) return "var(--warn)";
      return "var(--good)";
    }
    function windowView(w) {
      const box = el("div");
      const head = el("div", "row");
      head.append(el("span", "label", w.label));
      box.append(head);
      const pct = el("div", "pct", w.percent == null ? "--" : w.percent + "%");
      pct.style.color = tone(w.percent);
      box.append(pct);
      const bar = el("div", "bar"); const fill = el("div");
      fill.style.width = (w.percent || 0) + "%"; fill.style.background = tone(w.percent);
      bar.append(fill); box.append(bar);
      box.append(el("div", "reset", [w.reset, w.pace].filter(v => v && v !== "--").join(" · ")));
      return box;
    }
    function accountView(a, windows) {
      const box = el("div", "account");
      const head = el("div", "row");
      head.append(el("span", "name", a.name));
      if (a.coupon) head.append(el("span", "badge", "🎟 " + [a.coupon.text, a.coupon.expiry].filter(Boolean).join(" · ")));
      if (a.active) head.append(el("span", "badge", "사용 중"));
      if (a.freshness && a.freshness !== "최신") head.append(el("span", "meta stale", a.freshness));
      box.append(head);
      const grid = el("div", "windows");
      grid.style.setProperty("--columns", windows.length);
      windows.forEach(w => grid.append(windowView(w)));
      box.append(grid);
      return box;
    }
    function sectionView(title, accent) {
      const s = el("section"); s.style.setProperty("--accent", accent);
      s.append(el("h2", null, title));
      return s;
    }
    function render(d) {
      const main = document.getElementById("main");
      main.replaceChildren();
      const claude = sectionView("Claude", "var(--claude)");
      d.claude.forEach(a => claude.append(accountView(a, a.windows || [a.fiveHour, a.weekly])));
      main.append(claude);
      const codex = sectionView("Codex", "var(--codex)");
      d.codex.forEach(a => codex.append(accountView(a, [a.weekly])));
      main.append(codex);
      if (d.openRouter) {
        const r = sectionView("OpenRouter", "var(--router)");
        const row = el("div", "row");
        row.append(el("span", "pct", d.openRouter.remaining));
        row.append(el("span", "label", "남음"));
        r.append(row);
        r.append(el("div", "reset", "사용 " + d.openRouter.used + " · " + d.openRouter.allowanceLabel + " " + d.openRouter.allowance));
        main.append(r);
      }
      const refreshed = document.getElementById("refreshed");
      refreshed.textContent = d.refreshedText;
      const ageMinutes = d.refreshedAt ? (Date.now() - Date.parse(d.refreshedAt)) / 60000 : Infinity;
      refreshed.className = ageMinutes > 15 ? "meta stale" : "meta";
      const error = document.getElementById("error");
      error.hidden = !d.error; error.textContent = d.error || "";
    }
    async function load() {
      try {
        const response = await fetch("usage.json?k=" + encodeURIComponent(key), { cache: "no-store" });
        if (!response.ok) throw new Error("HTTP " + response.status);
        render(await response.json());
      } catch (e) {
        const error = document.getElementById("error");
        error.hidden = false; error.textContent = "Mac에 연결하지 못했습니다 (" + e.message + "). Tailscale 연결을 확인해 주세요.";
      }
    }
    load();
    setInterval(load, 60000);
    document.addEventListener("visibilitychange", () => { if (!document.hidden) load(); });
    </script>
    </body>
    </html>
    """#

    /// Scriptable (iOS) widget source with this Mac's address and key filled in.
    static func widget(baseURL: URL, accessKey: String) -> String {
        let endpoint = baseURL.appendingPathComponent("usage.json").absoluteString
        let page = baseURL.absoluteString + "/?k=" + accessKey
        return widgetTemplate
            .replacingOccurrences(of: "__ENDPOINT__", with: jsString(endpoint))
            .replacingOccurrences(of: "__KEY__", with: jsString(accessKey))
            .replacingOccurrences(of: "__PAGE__", with: jsString(page))
    }

    private static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private static let widgetTemplate = #"""
    // Token Usage widget for Scriptable. Paste into a new Scriptable script, then add a
    // Scriptable widget to the home or lock screen and choose this script.
    const ENDPOINT = __ENDPOINT__;
    const KEY = __KEY__;
    const PAGE = __PAGE__;

    function tone(p) {
      if (p == null) return Color.gray();
      if (p <= 10) return Color.red();
      if (p <= 30) return Color.orange();
      return Color.green();
    }
    function pct(p) { return p == null ? "--" : p + "%"; }

    async function load() {
      const request = new Request(ENDPOINT);
      request.headers = { Authorization: "Bearer " + KEY };
      request.timeoutInterval = 10;
      return await request.loadJSON();
    }

    function addLine(stack, label, value, color, size) {
      const row = stack.addStack();
      row.centerAlignContent();
      const l = row.addText(label);
      l.font = Font.systemFont(size - 2); l.textColor = Color.gray();
      row.addSpacer();
      const v = row.addText(value);
      v.font = Font.boldSystemFont(size); v.textColor = color;
    }

    async function build() {
      const w = new ListWidget();
      w.url = PAGE;
      w.refreshAfterDate = new Date(Date.now() + 15 * 60 * 1000);
      const family = config.widgetFamily || "medium";
      const accessory = family.startsWith("accessory");
      let d;
      try { d = await load(); } catch (e) {
        w.addText(accessory ? "Mac 연결 안 됨" : "Mac에 연결하지 못했습니다").font = Font.systemFont(12);
        return w;
      }
      const claude = d.claude.find(a => a.active) || d.claude[0];
      const codex = d.codex.find(a => a.active) || d.codex[0];
      // Team plans have no all-model weekly limit; their second window is the Fable one.
      const claudeWeek = (claude.windows && claude.windows[1]) || claude.weekly;

      if (accessory) {
        const t = w.addText("C " + pct(claude.fiveHour.percent) + "/" + pct(claudeWeek.percent)
          + "  X " + pct(codex.weekly.percent));
        t.font = Font.boldSystemFont(12);
        if (claude.coupon) w.addText("🎟 " + claude.coupon.text).font = Font.systemFont(10);
        return w;
      }

      const size = family === "small" ? 13 : 15;
      const title = w.addText("Claude · " + claude.name + (claude.coupon ? "  🎟" + claude.coupon.text.replace("쿠폰 ", "") : ""));
      title.font = Font.semiboldSystemFont(size - 3); title.textColor = Color.orange(); title.lineLimit = 1;
      addLine(w, "5시간", pct(claude.fiveHour.percent), tone(claude.fiveHour.percent), size);
      addLine(w, claudeWeek.label, pct(claudeWeek.percent), tone(claudeWeek.percent), size);
      w.addSpacer(4);
      const codexTitle = w.addText("Codex · " + codex.name);
      codexTitle.font = Font.semiboldSystemFont(size - 3); codexTitle.textColor = Color.cyan(); codexTitle.lineLimit = 1;
      addLine(w, "주간", pct(codex.weekly.percent), tone(codex.weekly.percent), size);
      w.addSpacer();
      const stamp = w.addText(d.refreshedText);
      stamp.font = Font.systemFont(9); stamp.textColor = Color.gray(); stamp.lineLimit = 1;
      return w;
    }

    const widget = await build();
    if (config.runsInWidget) { Script.setWidget(widget); } else { await widget.presentMedium(); }
    Script.complete();
    """#
}
