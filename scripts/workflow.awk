# Text modes over one workflow on stdin, for sync.sh; the hygiene checks themselves are scripts/workflow.py.
# -v mode=norm prints the file with every remote `uses:` ref blanked (`uses: x@`), to compare a repo's copy of a
#   standard workflow with the standard across Dependabot bumps. A `uses` written any other way is left as it is, so
#   the copies differ and the copy is drift: this mode can only fail closed.
# -v mode=subst -v reps='<owner/repo>=<sha> # <version>;...' prints the file with those actions' refs replaced
#   (the standard's own workflows, written in the plain `- uses: owner/repo@<sha> # <version>` form).
# POSIX awk only (no [[:classes:]], no {n} intervals): `make test` runs both modes under every awk on PATH.
BEGIN {
  nr = split(reps, ra, ";")
  for (i = 1; i <= nr; i++) { k = ra[i]; sub(/=.*/, "", k); v = ra[i]; sub(/^[^=]*=/, "", v); rep[k] = v }
}
{
  line = $0
  if (match(line, /^ *(- )?uses: [A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+[^ @]*@/)) {
    head = substr(line, 1, RLENGTH); a = head; sub(/^ *(- )?uses: /, "", a); sub(/@$/, "", a)
    split(a, seg, "/"); repo = seg[1] "/" seg[2]
    if (mode == "norm") line = head
    else if (mode == "subst" && (repo in rep)) line = head rep[repo]
  }
  print line
}
