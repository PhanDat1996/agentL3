<?xml version="1.0" encoding="UTF-8"?>
<!-- Renders phase1-report.xml to HTML: xsltproc phase1.xsl phase1-report.xml > phase1-report.html -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:output method="html" encoding="UTF-8" indent="yes" doctype-system="about:legacy-compat"/>

<xsl:template match="/rca-phase1-report">
<html lang="en"><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Phase 1 Report — <xsl:value-of select="system/host"/></title>
<style>
:root{--bg:#f7f7f5;--card:#fff;--fg:#1d1d1b;--mute:#6b6b66;--line:#e3e2dc;--pass:#2f7d4f;--warn:#a86a00;--fail:#b3261e;--nc:#77756d;--chip:#f0efe9}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--card:#1f1f1d;--fg:#ecebe6;--mute:#a09e96;--line:#34332f;--pass:#5fbf86;--warn:#e0a53a;--fail:#ff7a6e;--nc:#9a988f;--chip:#2a2a27}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif}
main{max-width:1100px;margin:0 auto;padding:24px 16px}h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:28px 0 10px}
.mute{color:var(--mute)}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px}
.big{font-size:26px;font-weight:650}.k{font-size:12px;color:var(--mute);text-transform:uppercase;letter-spacing:.04em}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}th{font-size:12px;color:var(--mute);font-weight:600}
tr:last-child td{border-bottom:0}.wrap{overflow-x:auto}
.r{font-weight:650;font-size:12px;padding:2px 8px;border-radius:99px;background:var(--chip);white-space:nowrap}
.pass{color:var(--pass)}.warn{color:var(--warn)}.fail{color:var(--fail)}.notchecked{color:var(--nc)}
.st-healthy{color:var(--pass)}.st-attention{color:var(--warn)}.st-degraded,.st-critical{color:var(--fail)}
code,.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12.5px}
</style></head><body><main>
<h1>Phase 1 — Collection &amp; Health Check</h1>
<div class="mute"><xsl:value-of select="system/host"/> · <xsl:value-of select="system/os"/> · kernel <xsl:value-of select="system/kernel"/> ·
 <xsl:value-of select="system/virtualization"/> · <xsl:value-of select="system/cpus"/> CPU · <xsl:value-of select="system/memory-mib"/> MiB ·
 window <xsl:value-of select="system/window/@days"/> days since <xsl:value-of select="system/window/@since"/>
 <xsl:if test="@redacted='true'"> · <b>REDACTED</b></xsl:if></div>

<h2>Summary</h2>
<div class="grid">
 <div class="card"><div class="k">Status</div><div class="big st-{summary/@status}"><xsl:value-of select="summary/@status"/></div></div>
 <div class="card"><div class="k">Score</div><div class="big"><xsl:value-of select="summary/@score"/>%</div></div>
 <div class="card"><div class="k">Pass</div><div class="big pass"><xsl:value-of select="summary/@pass"/></div></div>
 <div class="card"><div class="k">Warn</div><div class="big warn"><xsl:value-of select="summary/@warn"/></div></div>
 <div class="card"><div class="k">Fail</div><div class="big fail"><xsl:value-of select="summary/@fail"/></div></div>
 <div class="card"><div class="k">Boots / unclean</div><div class="big"><xsl:value-of select="statistics/boots/@total"/> / <xsl:value-of select="statistics/boots/@unclean"/></div></div>
</div>

<h2>Checks needing attention</h2>
<div class="wrap"><table><tr><th>ID</th><th>Result</th><th>Severity</th><th>Check</th><th>Observed</th><th>Expected</th><th>Evidence</th></tr>
<xsl:for-each select="checks/check[@result='fail']"><xsl:call-template name="row"/></xsl:for-each>
<xsl:for-each select="checks/check[@result='warn']"><xsl:call-template name="row"/></xsl:for-each>
</table></div>

<h2>Event statistics</h2>
<div class="wrap"><table><tr><th>Category</th><th>Count</th><th>First</th><th>Last</th></tr>
<xsl:for-each select="statistics/events/event"><xsl:sort select="@count" data-type="number" order="descending"/>
<tr><td><xsl:value-of select="@category"/></td><td><b><xsl:value-of select="@count"/></b></td><td class="mono"><xsl:value-of select="@first"/></td><td class="mono"><xsl:value-of select="@last"/></td></tr></xsl:for-each>
<xsl:if test="not(statistics/events/event)"><tr><td colspan="4" class="mute">No known outage signatures in the window.</td></tr></xsl:if>
</table></div>

<xsl:if test="statistics/services/unit or statistics/oom-victims/process">
<h2>Services &amp; OOM victims</h2>
<div class="wrap"><table><tr><th>Unit / process</th><th>Failures</th><th>Auto restarts</th><th>Last result / OOM kills</th></tr>
<xsl:for-each select="statistics/services/unit"><tr><td class="mono"><xsl:value-of select="@name"/></td><td><xsl:value-of select="@failures"/></td><td><xsl:value-of select="@restarts"/></td><td><xsl:value-of select="@last-result"/></td></tr></xsl:for-each>
<xsl:for-each select="statistics/oom-victims/process"><tr><td class="mono"><xsl:value-of select="@name"/> (process)</td><td>—</td><td>—</td><td>OOM-killed <xsl:value-of select="@kills"/>×</td></tr></xsl:for-each>
</table></div></xsl:if>

<xsl:if test="statistics/history">
<h2>Historical peaks (sar, interval <xsl:value-of select="statistics/history/@interval-seconds"/>s)</h2>
<div class="wrap"><table><tr><th>Metric</th><th>Max</th><th>At</th><th>Device</th></tr>
<xsl:for-each select="statistics/history/peak"><tr><td class="mono"><xsl:value-of select="@metric"/></td><td><b><xsl:value-of select="@max"/></b></td><td class="mono"><xsl:value-of select="@at"/></td><td><xsl:value-of select="@device"/></td></tr></xsl:for-each>
</table></div></xsl:if>

<h2>Current resources</h2>
<div class="wrap"><table><tr><th>Metric</th><th>Value</th></tr>
<xsl:for-each select="statistics/resources/metric"><tr><td class="mono"><xsl:value-of select="@name"/></td><td><xsl:value-of select="@value"/></td></tr></xsl:for-each>
<xsl:for-each select="statistics/resources/filesystem"><tr><td class="mono">fs <xsl:value-of select="@mount"/></td><td><xsl:value-of select="@used-pct"/>% used</td></tr></xsl:for-each>
</table></div>

<h2>All checks</h2>
<div class="wrap"><table><tr><th>ID</th><th>Result</th><th>Severity</th><th>Check</th><th>Observed</th><th>Expected</th><th>Evidence</th></tr>
<xsl:for-each select="checks/check"><xsl:call-template name="row"/></xsl:for-each>
</table></div>
<p class="mute">Generated <xsl:value-of select="@generated"/> by phase1-report.sh v<xsl:value-of select="@version"/>. Phase 1 is automated pattern matching: it shows where to look, not why. Root cause is established in Phase 2.</p>
</main></body></html>
</xsl:template>

<xsl:template name="row">
<tr><td class="mono"><xsl:value-of select="@id"/></td><td><span class="r {@result}"><xsl:value-of select="@result"/></span></td>
<td><xsl:value-of select="@severity"/></td><td><xsl:value-of select="title"/><xsl:if test="advice"><div class="mute"><xsl:value-of select="advice"/></div></xsl:if></td>
<td><xsl:value-of select="observed"/></td><td><xsl:value-of select="expected"/></td><td class="mono"><xsl:value-of select="evidence"/></td></tr>
</xsl:template>
</xsl:stylesheet>
