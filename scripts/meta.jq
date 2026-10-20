# Repo metadata from its GitHub topics (input: the repo JSON of `gh api repos/<owner>/<repo>`).
# std-<type> (exactly one), std-released, std-pypi, std-deploys, std-exception-<check-id with - for _>.
[.topics[]? | select(startswith("std-")) | ltrimstr("std-")] as $t
| [$t[] | select(IN("python", "typescript", "go", "infra", "config", "docs"))] as $types
| {types: $types,
   type: (if ($types | length) == 1 then $types[0] else "unknown" end),
   released: ($t | index("released") != null),
   pypi: ($t | index("pypi") != null),
   deploys: ($t | index("deploys") != null),
   exceptions: [$t[] | select(startswith("exception-")) | ltrimstr("exception-") | gsub("-"; "_")]}
