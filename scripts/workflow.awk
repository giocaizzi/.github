# CI hygiene of one GitHub Actions workflow (docs/standard.md, CI hygiene). Reads the YAML on stdin.
# -v mode=check (default) prints one `<check id><TAB><detail>` line per failed rule, nothing when it passes:
#   wf_parsed       the file is in the line subset this checker reads (block style, 2-space indent: triggers and jobs
#                   at 2, job keys at 4); anything else fails closed here: flow-style `on:`, `jobs:` or a job, other
#                   or tab indents, aliases, merge keys, tags, explicit keys, quoted or flow values not closed on their
#                   line, and a `uses`, `permissions`, `concurrency` or `timeout-minutes` key that is not the line's own
#                   parsed key (docs/standard.md lists them; a fail-closed subset, not a YAML parser)
#   wf_permissions  top-level `permissions:` set; no `write-all` anywhere (top level or job); every value parsed
#   wf_timeout      every job sets `timeout-minutes:` (a job that calls a reusable workflow cannot)
#   wf_concurrency  a pull_request workflow sets `concurrency:` (top level, or on every job); in a workflow that also
#                   runs on push or merge_group, every group names `github.run_id` and no `cancel-in-progress` is a
#                   literal true (`true`, `True`, `${{ true }}`, ...)
#   wf_pinned       every action `uses:` is pinned by a full lowercase commit SHA with its version as a comment
#                   (`@<sha> # v7.0.1`); local `./` and `docker://` refs are exempt
# -v mode=pins prints `<owner/repo><TAB><sha><TAB><version>` for each pin wf_pinned accepts (sync.sh checks it upstream).
# -v mode=norm prints the file with every remote ref blanked (`uses: x@`), to compare copies across Dependabot bumps.
# -v mode=subst -v reps='<owner/repo>=<sha> # <version>;...' prints the file with those actions' refs replaced.
# POSIX awk only (no [[:classes:]], no {n} intervals): `make test` runs the fixtures under gawk, mawk and BWK awk.
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function unq(s) { if (s ~ /^".*"$/ || s ~ /^'.*'$/) s = substr(s, 2, length(s) - 2); return s }
function bad(id, d) { out[id] = out[id] (out[id] != "" ? "; " : "") d }
function unparsed(d) { bad("wf_parsed", "line " NR ": " d) }
function trig(s, n, a, i) { gsub(/[][,]/, " ", s); n = split(s, a, " "); for (i = 1; i <= n; i++) { on[unq(a[i])] = 1; ntrig++ } }
function lit_true(v) { v = tolower(v); gsub(/[ \t"']/, "", v); return v == "true" || v == "yes" || v == "on" || v == "${{true}}" }
function perm(v, where) { # a scalar or flow permissions value
  v = unq(v)
  if (v == "write-all") bad("wf_permissions", where ": permissions: write-all")
  else if (v != "read-all" && v != "{}" && v !~ /^\{([ \t]*[a-z-]+[ \t]*:[ \t]*(read|write|none)[ \t]*,?)*[ \t]*\}$/) unparsed("permissions value " v)
}
function conc_flow(v, g, c) { # `concurrency: <group>` or `concurrency: {group: ..., cancel-in-progress: ...}`
  if (v ~ /^\{/) {
    g = v; if (!sub(/.*group[ \t]*:[ \t]*/, "", g)) g = ""; sub(/,[ \t]*cancel-in-progress.*$/, "", g); sub(/\}$/, "", g)
    c = v; if (sub(/.*cancel-in-progress[ \t]*:[ \t]*/, "", c)) { sub(/[,}].*$/, "", c); if (lit_true(c)) ctrue = 1 }
  } else g = v
  groups[++ng] = g
}
function endjob() { if (job != "" && !timeout && !reusable) nt = nt (nt ? ", " : "") job; if (job != "" && !jconc) alljconc = 0 }
function emit() { if (mode == "norm" || mode == "subst") print line }
BEGIN {
  if (mode == "") mode = "check"
  alljconc = 1; bs = -1; pblk = -1; cblk = -1
  nr = split(reps, ra, ";"); for (i = 1; i <= nr; i++) { k = ra[i]; sub(/=.*/, "", k); v = ra[i]; sub(/^[^=]*=/, "", v); rep[k] = v }
}
{
  sub(/\r$/, ""); line = $0
  ind = match($0, /[^ ]/) ? RSTART - 1 : -1
  if (bs >= 0) { if (ind < 0 || ind > bs) { emit(); next }; bs = -1 } # block scalar content (`run: |`)
  if (ind < 0 || substr($0, ind + 1, 1) == "#") { emit(); next }
  if ($0 ~ /^ *\t/) unparsed("tab indentation")
  rest = substr($0, ind + 1); dash = 0; kind = ind
  if (rest ~ /^-([ \t]|$)/) { dash = 1; r2 = rest; sub(/^-[ \t]*/, "", r2); kind = ind + length(rest) - length(r2); rest = r2 }
  # YAML this checker does not read: explicit keys (`? k` / `: v`), tags, anchors or aliases on a key, directives,
  # block scalars as list items; each fails closed rather than hiding what follows
  if (rest ~ /^[?:!&*%@`|>]/) unparsed("YAML form not read: " rest)
  key = ""; val = rest; cm = ""; qkey = 0
  if (rest !~ /^[{[]/ && match(rest, /^("[^"]*"|'[^']*'|[^"'#:][^:]*)[ \t]*:([ \t]|$)/)) {
    key = substr(rest, 1, RLENGTH); sub(/[ \t]*:[ \t]*$/, "", key); key = trim(key); val = substr(rest, RLENGTH + 1)
    if (key ~ /^["']/) { qkey = 1; if (key ~ /\\/) unparsed("escape in a quoted key"); key = unq(key) }
  }
  if (match(val, /(^|[ \t])#.*$/)) { cm = trim(substr(val, RSTART)); sub(/^#[ \t]*/, "", cm); val = substr(val, 1, RSTART - 1) }
  val = trim(val)
  if (val ~ /^\*/ || key == "<<") unparsed("YAML alias or merge key")
  if (val ~ /^&/) sub(/^&[^ \t]*[ \t]*/, "", val) # an anchor, then the value
  if (val ~ /^!/) unparsed("YAML tag")
  # a scalar or flow value must end on its own line: a continuation line could fake a key or open a block scalar
  if (val ~ /^"/ && val !~ /^"([^"\\]|\\.)*"$/) unparsed("quoted value not closed on its line")
  if (val ~ /^'/ && val !~ /^'([^']|'')*'$/) unparsed("quoted value not closed on its line")
  if ((val ~ /^\[/ && val !~ /\]$/) || (val ~ /^\{/ && val !~ /\}$/)) unparsed("flow value not closed on its line")
  if (key != "" && !qkey && val ~ /^[|>][-+0-9]*$/) bs = kind # a block scalar header is the whole value of a plain key
  # the four keys this checker relies on are read only where it parsed them as the key of this line
  tk = (key == "uses" || key == "permissions" || key == "concurrency" || key == "timeout-minutes") ? val : (key != "" ? key ": " val : val)
  if (tk ~ /(^|[^A-Za-z0-9_-])["']?(uses|permissions|concurrency|timeout-minutes)["']?[ \t]*:/) unparsed("key not read: " rest)

  if (ind == 0) {
    if (dash || key == "") { unparsed("top-level line"); emit(); next }
    endjob(); job = ""; sec = key; pblk = -1; cblk = -1
    if (sec == "on" && val != "") { if (val ~ /^\{/) unparsed("flow-style on:"); else trig(val) }
    if (sec == "permissions") { perms = 1; if (val != "") perm(val, "top level"); else pblk = 0 }
    if (sec == "concurrency") { conc = 1; if (val != "") conc_flow(val); else { cblk = 0; groups[++ng] = "" } }
    if (sec == "jobs" && val != "") unparsed("flow-style jobs:")
  } else if (pblk >= 0 && ind > pblk) { # a permissions block entry
    if (dash || key == "" || unq(val) !~ /^(read|write|none)$/) unparsed("permissions entry " rest)
    key = ""
  } else if (cblk >= 0 && ind > cblk) { # a concurrency block entry
    if (key == "group") groups[ng] = val
    if (key == "cancel-in-progress" && lit_true(val)) ctrue = 1
    key = ""
  } else {
    pblk = -1; cblk = -1
    if (sec == "on" && ind == 2) {
      if (dash && key == "") { on[unq(val)] = 1; ntrig++ }
      else if (!dash && key != "") { on[key] = 1; ntrig++ }
      else unparsed("trigger " rest)
    } else if (sec == "on" && ind < 2) unparsed("indent")
    if (sec == "jobs") {
      if (ind == 2) {
        if (dash || key == "") unparsed("job " rest)
        else if (val != "") unparsed("flow-style job " key)
        endjob(); job = key; timeout = 0; reusable = 0; jconc = 0; njobs++
      } else if (job == "" || ind == 1 || ind == 3) unparsed("indent")
      else if (ind == 4 && !dash) { # a job key (`    - ...` is a list item of the key above, e.g. compact `steps:`)
        if (key == "") unparsed("job key " rest)
        if (key == "timeout-minutes" && val != "") timeout = 1
        if (key == "uses") reusable = 1
        if (key == "permissions") { if (val != "") perm(val, "job " job); else pblk = 4 }
        if (key == "concurrency") { jconc = 1; if (val != "") conc_flow(val); else { cblk = 4; groups[++ng] = "" } }
      }
    }
    if ((key == "permissions" || key == "concurrency") && !(sec == "jobs" && ind == 4 && !dash)) unparsed(key " key")
  }

  if (key == "uses") {
    u = unq(val)
    if (u ~ /^(\.\/|docker:\/\/)/) { emit(); next }
    at = index(u, "@"); a = substr(u, 1, at - 1); r = at ? substr(u, at + 1) : ""
    split(a, seg, "/"); repo = seg[1] "/" seg[2]
    if (!(at && length(r) == 40 && r ~ /^[0-9a-f]+$/)) bad("wf_pinned", "not pinned by SHA: " u)
    else if (cm !~ /^v?[0-9]+(\.[0-9]+)*$/) bad("wf_pinned", "no version comment: " u)
    else if (mode == "pins") print repo "\t" r "\t" cm
    p = index(line, "@")
    if (mode == "norm" && at && p) line = substr(line, 1, p)
    if (mode == "subst" && at && p && val !~ /^["']/ && (repo in rep)) line = substr(line, 1, p) rep[repo]
  }
  emit()
}
END {
  endjob()
  if (mode != "check") exit
  if (!ntrig) bad("wf_parsed", "no trigger found under on:")
  if (!njobs) bad("wf_parsed", "no job found under jobs:")
  if (!perms) bad("wf_permissions", "no top-level permissions")
  if (nt) bad("wf_timeout", "jobs without timeout-minutes: " nt)
  if ((on["pull_request"] || on["pull_request_target"]) && !conc && !(njobs && alljconc)) bad("wf_concurrency", "pull_request trigger without concurrency")
  if (on["push"] || on["merge_group"]) {
    if (ctrue) bad("wf_concurrency", "cancel-in-progress: true on a push or merge_group run")
    for (i = 1; i <= ng; i++) if (groups[i] !~ /github\.run_id/) { bad("wf_concurrency", "group without github.run_id on a push or merge_group run"); break }
  }
  n = split("wf_parsed wf_permissions wf_timeout wf_concurrency wf_pinned", ids, " ")
  for (i = 1; i <= n; i++) if (out[ids[i]] != "") print ids[i] "\t" out[ids[i]]
}
