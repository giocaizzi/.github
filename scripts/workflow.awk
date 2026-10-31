# CI hygiene of one GitHub Actions workflow (docs/standard.md, CI hygiene). Reads the YAML on stdin and
# prints one `<check id><TAB><detail>` line per failed rule, nothing when it passes:
#   wf_permissions  top-level `permissions:` set, never `write-all`
#   wf_timeout      every job sets `timeout-minutes:` (a job that calls a reusable workflow cannot)
#   wf_concurrency  a pull_request workflow sets `concurrency:`; `cancel-in-progress: true` as a literal
#                   never sits in a workflow that also runs on push or merge_group
#   wf_pinned       every action `uses:` is pinned by a full commit SHA (local `./` and `docker://` excepted)
# Assumes the standard's layout: 2-space indent, jobs at 2 spaces, job keys at 4.
function strip(s) { sub(/[[:space:]]+#.*$/, "", s); gsub(/["\047]/, "", s); sub(/[[:space:]]+$/, "", s); return s }
function trig(s, n, a, i) { gsub(/[][{}:,]/, " ", s); n = split(s, a, " "); for (i = 1; i <= n; i++) on[a[i]] = 1 }
function endjob() { if (job != "" && !timeout && !reusable) nt = nt (nt ? ", " : "") job }
/^[[:space:]]*(#|$)/ { next }
/^[^ ]/ {
  sec = $0; sub(/:.*/, "", sec); sec = strip(sec)
  v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); v = strip(v)
  if (sec == "on" && v != "") trig(v)
  if (sec == "permissions") { perms = 1; if (v == "write-all") wall = 1 }
  if (sec == "concurrency") conc = 1
  if (sec != "jobs") { endjob(); job = "" }
}
sec == "on" && /^  [A-Za-z_]+:?/ { t = $1; sub(/:.*/, "", t); on[t] = 1 }
sec == "jobs" && /^  [^ ]/ { endjob(); job = $1; sub(/:.*/, "", job); timeout = 0; reusable = 0 }
sec == "jobs" && job != "" && /^    timeout-minutes:/ { timeout = 1 }
sec == "jobs" && job != "" && /^    uses:/ { reusable = 1 }
/^[[:space:]]*cancel-in-progress:[[:space:]]*true[[:space:]]*(#.*)?$/ { ctrue = 1 }
/^[[:space:]]*(- )?uses:/ {
  u = $0; sub(/^[[:space:]]*(- )?uses:[[:space:]]*/, "", u); u = strip(u)
  r = u; sub(/^[^@]*@?/, "", r) # the ref; no {40}: older mawk has no interval expressions
  if (u !~ /^(\.\/|docker:\/\/)/ && !(length(r) == 40 && r ~ /^[0-9a-f]+$/)) np = np (np ? ", " : "") u
}
END {
  endjob()
  if (!perms) print "wf_permissions\tno top-level permissions"
  else if (wall) print "wf_permissions\tpermissions: write-all"
  if (nt) print "wf_timeout\tjobs without timeout-minutes: " nt
  if ((on["pull_request"] || on["pull_request_target"]) && !conc) print "wf_concurrency\tpull_request trigger without concurrency"
  if (ctrue && (on["push"] || on["merge_group"])) print "wf_concurrency\tcancel-in-progress: true on a push or merge_group run"
  if (np) print "wf_pinned\tnot pinned by SHA: " np
}
