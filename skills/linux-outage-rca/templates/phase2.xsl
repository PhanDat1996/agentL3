<?xml version="1.0" encoding="UTF-8"?>
<!-- Renders phase2-analysis.xml to HTML: xsltproc phase2.xsl phase2-analysis.xml > phase2-analysis.html -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:output method="html" encoding="UTF-8" indent="yes" doctype-system="about:legacy-compat"/>

<xsl:template match="/rca-phase2-analysis">
<html lang="en"><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>RCA — <xsl:value-of select="engagement/host"/></title>
<style>
:root{--bg:#f7f7f5;--card:#fff;--fg:#1d1d1b;--mute:#6b6b66;--line:#e3e2dc;--ok:#2f7d4f;--warn:#a86a00;--crit:#b3261e;--unk:#77756d;--chip:#f0efe9}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--card:#1f1f1d;--fg:#ecebe6;--mute:#a09e96;--line:#34332f;--ok:#5fbf86;--warn:#e0a53a;--crit:#ff7a6e;--unk:#9a988f;--chip:#2a2a27}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.55 -apple-system,Segoe UI,Roboto,sans-serif}
main{max-width:1100px;margin:0 auto;padding:24px 16px}h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:30px 0 10px}h3{font-size:14px;margin:0 0 4px}
.mute{color:var(--mute)}.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin-bottom:10px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line)}th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-size:12px;color:var(--mute)}.wrap{overflow-x:auto}
.chip{font-size:12px;font-weight:650;padding:2px 8px;border-radius:99px;background:var(--chip);white-space:nowrap}
.ok,.healthy,.passed,.low,.info{color:var(--ok)}.warn,.attention,.medium,.probable,.pending{color:var(--warn)}
.critical,.degraded,.high,.failed{color:var(--crit)}.unknown,.hypothesis{color:var(--unk)}.confirmed{color:var(--ok)}
pre,code,.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12.5px}pre{white-space:pre-wrap;margin:4px 0;padding:6px 8px;background:var(--chip);border-radius:6px}
ol{margin:4px 0 0 18px;padding:0}
</style></head><body><main>
<h1>Root Cause Analysis — <xsl:value-of select="engagement/host"/></h1>
<div class="mute">Phase 2 deep analysis · <xsl:value-of select="engagement/analyst"/>
 <xsl:if test="engagement/analysis-model"> · <xsl:value-of select="engagement/analysis-model"/></xsl:if> · generated <xsl:value-of select="@generated"/>
 · Phase 1: <xsl:value-of select="engagement/phase1-ref/@status"/> (<xsl:value-of select="engagement/phase1-ref/@score"/>%)
 <xsl:if test="@redacted='true'"> · <b>REDACTED</b></xsl:if></div>

<div class="grid" style="margin-top:16px">
 <div class="card"><div class="mute">Overall</div><div style="font-size:22px;font-weight:650" class="{assessment/@overall}"><xsl:value-of select="assessment/@overall"/></div></div>
 <div class="card"><div class="mute">Root cause</div><div style="font-size:22px;font-weight:650" class="{root-cause/@confidence}"><xsl:value-of select="root-cause/@confidence"/></div></div>
 <div class="card"><div class="mute">Recurrence risk</div><div style="font-size:22px;font-weight:650" class="{assessment/@recurrence-risk}"><xsl:value-of select="assessment/@recurrence-risk"/></div></div>
 <div class="card"><div class="mute">Validation</div><div style="font-size:22px;font-weight:650" class="{validation/@status}"><xsl:value-of select="validation/@status"/></div></div>
</div>

<h2>Executive summary</h2><div class="card"><xsl:value-of select="executive-summary"/></div>
<div class="card"><h3>Client report</h3><xsl:value-of select="engagement/client-report"/></div>

<h2>Root cause</h2>
<div class="card"><b><xsl:value-of select="root-cause/summary"/></b>
<ol><xsl:for-each select="root-cause/mechanism/step"><li><xsl:value-of select="."/></li></xsl:for-each></ol>
<p><b>Trigger:</b> <xsl:value-of select="root-cause/trigger"/><br/><b>Why intermittent:</b> <xsl:value-of select="root-cause/why-intermittent"/>
<xsl:if test="root-cause/why-now"><br/><b>Why now:</b> <xsl:value-of select="root-cause/why-now"/></xsl:if>
<xsl:if test="root-cause/confirm-by"><br/><b>To confirm:</b> <xsl:value-of select="root-cause/confirm-by"/></xsl:if></p>
<xsl:if test="root-cause/confidence-detail"><b>Confidence by part</b><ul><xsl:for-each select="root-cause/confidence-detail"><li><span class="chip {@confidence}"><xsl:value-of select="@confidence"/></span><xsl:text> </xsl:text><xsl:value-of select="."/></li></xsl:for-each></ul></xsl:if>
<xsl:if test="root-cause/contributing-factor"><b>Contributing factors</b><ul><xsl:for-each select="root-cause/contributing-factor"><li><xsl:value-of select="."/></li></xsl:for-each></ul></xsl:if>
</div>

<h2>Health assessment</h2>
<div class="wrap"><table><tr><th>Domain</th><th>Status</th><th>Assessment</th></tr>
<xsl:for-each select="assessment/domain"><tr><td><xsl:value-of select="@name"/></td><td><span class="chip {@status}"><xsl:value-of select="@status"/></span></td><td><xsl:value-of select="."/></td></tr></xsl:for-each>
</table></div>

<h2>Incidents</h2>
<div class="wrap"><table><tr><th>ID</th><th>Start</th><th>End</th><th>Source</th><th>Symptom</th></tr>
<xsl:for-each select="incidents/incident"><tr><td><xsl:value-of select="@id"/></td><td class="mono"><xsl:value-of select="@start"/></td><td class="mono"><xsl:value-of select="@end"/></td><td><xsl:value-of select="@source"/></td><td><xsl:value-of select="symptom"/></td></tr></xsl:for-each>
</table></div>

<h2>Findings</h2>
<xsl:for-each select="findings/finding"><div class="card">
<h3><xsl:value-of select="@id"/> · <xsl:value-of select="title"/></h3>
<span class="chip {@severity}"><xsl:value-of select="@severity"/></span><xsl:text> </xsl:text>
<span class="chip {@confidence}"><xsl:value-of select="@confidence"/></span><xsl:text> </xsl:text>
<span class="chip"><xsl:value-of select="@domain"/></span>
<xsl:if test="@related-checks"><span class="mute"> · Phase 1: <xsl:value-of select="@related-checks"/></span></xsl:if>
<p><xsl:value-of select="description"/></p>
<xsl:for-each select="evidence"><div class="mute mono"><xsl:value-of select="@file"/><xsl:if test="@line">:<xsl:value-of select="@line"/></xsl:if><xsl:if test="@timestamp"> @ <xsl:value-of select="@timestamp"/></xsl:if></div><pre><xsl:value-of select="."/></pre></xsl:for-each>
</div></xsl:for-each>

<h2>Timeline</h2>
<div class="wrap"><table><tr><th>Time</th><th>Event</th><th>Source</th><th>Incident</th></tr>
<xsl:for-each select="timeline/event"><tr><td class="mono"><xsl:value-of select="@time"/></td><td><xsl:value-of select="."/></td><td class="mono"><xsl:value-of select="@source"/></td><td><xsl:value-of select="@incident"/></td></tr></xsl:for-each>
</table></div>

<h2>Hypotheses ruled out</h2>
<div class="wrap"><table><tr><th>Hypothesis</th><th>Why not</th></tr>
<xsl:for-each select="ruled-out/hypothesis"><tr><td><xsl:value-of select="@name"/></td><td><xsl:value-of select="reason"/>
<xsl:for-each select="evidence"><div class="mute mono"><xsl:value-of select="@file"/> <xsl:value-of select="@timestamp"/>: <xsl:value-of select="."/></div></xsl:for-each></td></tr></xsl:for-each>
</table></div>

<h2>Phase 1 checks reviewed</h2>
<div class="wrap"><table><tr><th>Check</th><th>Verdict</th><th>Note</th></tr>
<xsl:for-each select="phase1-review/check"><tr><td class="mono"><xsl:value-of select="@id"/><xsl:if test="@subject"><div class="mute"><xsl:value-of select="@subject"/></div></xsl:if></td><td><span class="chip"><xsl:value-of select="@verdict"/></span></td><td><xsl:value-of select="."/></td></tr></xsl:for-each>
</table></div>

<h2>Recommendations</h2>
<xsl:for-each select="recommendations/recommendation"><div class="card">
<h3><xsl:value-of select="@id"/> · <xsl:value-of select="action"/></h3>
<span class="chip"><xsl:value-of select="@priority"/></span><xsl:text> </xsl:text><span class="chip"><xsl:value-of select="@type"/></span><xsl:text> </xsl:text><span class="chip"><xsl:value-of select="@status"/></span>
<xsl:if test="owner"><span class="mute"> · owner: <xsl:value-of select="owner"/></span></xsl:if>
<xsl:if test="command"><pre><xsl:value-of select="command"/></pre></xsl:if>
<div><b>Risk:</b> <xsl:value-of select="risk"/> · <b>Downtime:</b> <xsl:value-of select="downtime"/></div>
<div><b>Rollback:</b> <span class="mono"><xsl:value-of select="rollback"/></span></div>
</div></xsl:for-each>

<h2>Validation</h2>
<div class="card"><ul><xsl:for-each select="validation/criterion"><li><xsl:value-of select="."/></li></xsl:for-each></ul>
<xsl:if test="validation/result"><b>Result:</b> <xsl:value-of select="validation/result"/></xsl:if></div>

<h2>Commands run on the host <span class="mute">(<xsl:value-of select="actions-on-host/@access"/>)</span></h2>
<div class="wrap"><table><tr><th>Time</th><th>Read-only</th><th>Command</th></tr>
<xsl:for-each select="actions-on-host/command"><tr><td class="mono"><xsl:value-of select="@time"/></td><td><xsl:value-of select="@read-only"/></td><td class="mono"><xsl:value-of select="."/></td></tr></xsl:for-each>
</table></div>
<xsl:if test="actions-on-host/cleanup"><p class="mute">Cleanup: <xsl:value-of select="actions-on-host/cleanup"/></p></xsl:if>
</main></body></html>
</xsl:template>
</xsl:stylesheet>
