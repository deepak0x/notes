#!/usr/bin/env bash
# Scheduled GitHub issue watcher: searches configured labels, diffs against
# state.json, and pushes newly-seen items. Requires: gh (authenticated), jq.
#
# One global label search returns the whole population; we DROP orgs listed in
# exclude.txt and keep the rest (denylist model), so new sources are covered
# automatically. A handful of API calls total, regardless of source count.
set -euo pipefail

STATE="state.json"
DENY_FILE="exclude.txt"             # orgs to EXCLUDE
PLAIN_FILE="extra-sources.txt"      # orgs queried per-owner for the plain label

[ -f "$STATE" ] || echo "[]" > "$STATE"
before_count=$(jq 'length' "$STATE")

# Lowercase JSON array of denylisted org logins (strips inline # comments).
deny_json="$(sed -E 's/#.*//' "$DENY_FILE" 2>/dev/null | tr -d '[:blank:]' \
  | grep -v '^$' | tr 'A-Z' 'a-z' | jq -R . | jq -s .)"
echo "Denylist (excluded): $(echo "$deny_json" | jq -r 'join(", ")')" >&2

current_raw="$(mktemp)"; : > "$current_raw"

# Filter a `gh search issues --json ...` payload (on stdin) to EVERY org EXCEPT
# the denylisted ones, and TRIAGE to only fresh, grabbable issues: not a PR,
# unassigned, and with ZERO comments (nobody has applied/attempted yet — for
# GrantFox a comment == an application, so 0 comments = an open shot).
# $1 = source/platform tag. For GrantFox we also build the portal `apply` link
# (contribute.grantfox.xyz/org/<org>/repo/<repo>/issue/<num>) — applying there is
# required to actually get assigned (a raw GitHub comment does not win).
# (isPullRequest/assignees/commentsCount come free from the search JSON — no
# extra API calls.)
emit_filtered() {
  jq -c --argjson deny "$deny_json" --arg src "${1:-}" '
    .[]
    | (.repository.nameWithOwner | split("/")) as $rp
    | ($rp[0] | ascii_downcase) as $o
    | select($deny | index($o) | not)
    | select((.isPullRequest // false) | not)      # not a PR
    | select((.assignees // []) | length == 0)      # nobody claimed it yet
    | select((.commentsCount // 0) == 0)            # 0 comments only — freshest, no applicants
    | ([.labels[].name]) as $L
    | { id: (.repository.nameWithOwner + "#" + (.number|tostring)),
        title: .title, url: .url,
        amount: ([$L[] | select(startswith("$"))] | join(" ")),
        source: $src,
        comments: (.commentsCount // 0),
        apply: (if $src == "GrantFox"
                then "https://contribute.grantfox.xyz/org/" + $rp[0] + "/repo/" + $rp[1] + "/issue/" + (.number|tostring)
                else "" end),
        rewarded: (if ($L | map(ascii_downcase) | any(test("maybe rewarded"))) then "maybe" else "" end) }'
}

# Broader net: free-text search catches bounties on platforms that DON'T apply a
# distinctive label (e.g. Opire). Noisier by nature, so we tag them source="text"
# and drop obvious non-dev / security-bug-bounty noise by title.
emit_text() {
  emit_filtered "text" \
    | jq -c 'select(.title | ascii_downcase
        | test("cve|vulnerab|exploit|write-?up|airdrop|giveaway|whitelist|nft|token sale|bounty alert|opportunit(y|ies)|new opportunities") | not)'
}

# 1) Niche, platform-specific labels. Each is rare enough that one global query
#    returns its whole population; we then drop denylisted orgs.
#      💎 Bounty   = Algora        (the big one, ~500+ open)
#      Merit       = Merit Systems (early/low-volume, low competition)
#      IssueHunt   = IssueHunt     (small, declining)
#      GrantFox OSS= GrantFox      (Stellar ecosystem; reward NOT guaranteed —
#                                   labeled "Maybe Rewarded", paid in Stellar crypto)
#    --limit 1000 = fetch all. Adding a label here costs one extra global call.
for LBL in "💎 Bounty" "Merit" "IssueHunt" "GrantFox OSS"; do
  case "$LBL" in
    "💎 Bounty")    src="Algora" ;;
    "Merit")        src="Merit" ;;
    "IssueHunt")    src="IssueHunt" ;;
    "GrantFox OSS") src="GrantFox" ;;
    *)              src="$LBL" ;;
  esac
  echo "Global search: $LBL" >&2
  gh search issues --state open --label "$LBL" --limit 1000 \
      --json repository,number,title,url,labels,assignees,commentsCount,isPullRequest 2>/dev/null \
    | emit_filtered "$src" >> "$current_raw" || echo "  (warning: '$LBL' search failed)" >&2
done

# 2) A few orgs use the plain "Bounty" label (e.g. tenstorrent). A global
#    "Bounty" search is drowned out by unrelated security bug-bounty repos, so
#    query those specific orgs directly (small list -> few calls).
if [ -f "$PLAIN_FILE" ]; then
  while IFS= read -r org; do
    org="${org%%#*}"; org="$(echo "$org" | tr -d '[:blank:]')"; [ -z "$org" ] && continue
    sleep 4   # be gentle with the search secondary rate limit
    echo "Per-org search (plain Bounty): $org" >&2
    gh search issues --owner "$org" --state open --label "Bounty" --limit 100 \
        --json repository,number,title,url,labels,assignees,commentsCount,isPullRequest 2>/dev/null \
      | emit_filtered "Algora" \
      >> "$current_raw" || echo "  (warning: search failed for $org)" >&2
  done < "$PLAIN_FILE"
fi

# 3) Broader net: free-text queries for bounties WITHOUT a distinctive label
#    (catches Opire and plain "bounty"/"reward" issues the label search misses).
#    Kept small + triaged + spam-filtered; tagged source="text" so noisy hits are
#    easy to tell apart from confirmed platform bounties.
for Q in "opire in:title,body" "reward bounty in:title" "\"paid\" \"bounty\" in:title,body"; do
  sleep 4   # be gentle with the search secondary rate limit
  echo "Text search: $Q" >&2
  gh search issues --state open --limit 40 --sort updated "$Q" \
      --json repository,number,title,url,labels,assignees,commentsCount,isPullRequest 2>/dev/null \
    | emit_text >> "$current_raw" || echo "  (warning: text search failed for '$Q')" >&2
done

# Dedupe the current set by id.
jq -s 'unique_by(.id)' "$current_raw" > current.json
rm -f "$current_raw"

# NEW = current issues whose id is not already in seen.json.
jq --slurpfile seen "$STATE" '
  (($seen[0]) // []) as $s
  | map(select(.id as $i | ($s | index($i)) | not))
' current.json > new.json

# On the very first run (empty state) just seed — don't email a backlog.
if [ "$before_count" -eq 0 ]; then
  echo "First run: seeding state with $(jq 'length' current.json) existing bounties, no email." >&2
  echo "[]" > new.json
fi

# Freshness re-check: an issue can be claimed in the minutes between our scan and
# this alert (GrantFox campaigns assign within ~20 min, and GitHub search indexes
# fresh assignees with a lag). Re-verify each NEW item LIVE and drop any that just
# got an assignee or a linked PR — so we never alert on something already taken.
# Only runs on the (small) NEW set, so it's cheap.
if [ "$(jq 'length' new.json)" -gt 0 ]; then
  echo "Freshness re-check on $(jq 'length' new.json) new item(s)..." >&2
  keep="$(mktemp)"; echo "[]" > "$keep"
  while IFS= read -r item; do
    id=$(printf '%s' "$item" | jq -r '.id'); repo="${id%#*}"; num="${id##*#}"
    asg=$(gh api "repos/$repo/issues/$num" -q '.assignees | length' 2>/dev/null || echo 0)
    prs=$(gh api "repos/$repo/issues/$num/timeline" --paginate 2>/dev/null \
      | jq '[.[] | select((.event=="cross-referenced" and .source.issue.pull_request!=null) or .event=="connected")] | length' 2>/dev/null || echo 0)
    if [ "${asg:-0}" -eq 0 ] && [ "${prs:-0}" -eq 0 ]; then
      jq --argjson it "$item" '. + [$it]' "$keep" > "$keep.t" && mv "$keep.t" "$keep"
    else
      echo "  dropped (already claimed): $id (assignees=$asg linkedPRs=$prs)" >&2
    fi
  done < <(jq -c '.[]' new.json)
  mv "$keep" new.json
fi

# Update seen.json = union of previously-seen ids and all current ids.
jq -s '((.[0]) // []) + ([.[1][].id]) | unique' "$STATE" current.json > seen.tmp
mv seen.tmp "$STATE"

new_count=$(jq 'length' new.json)
echo "new_count=$new_count"

# Human-readable email body for the send step.
{
  echo "New fresh bounties (0 comments, unassigned, no PR):"
  echo
  jq -r '.[] | "• [\(.source // "?")] \(.amount // "") \(.id)\n  \(.title)\(if .rewarded=="maybe" then "  (reward NOT guaranteed — GrantFox campaign)" else "" end)\n  \(.url)\(if (.apply // "") != "" then "\n  APPLY (required): \(.apply)" else "" end)\n"' new.json
  echo "— bounty-monitor. Algora/Merit = claim fast (comment /attempt or /claim)."
  echo "  GrantFox = you MUST apply via the portal APPLY link (a raw GitHub comment"
  echo "  does not win); Stellar ecosystem, reward not guaranteed."
  echo "  [text] = keyword-matched (may be noisier); verify it's a real bounty."
} > message.txt

# GitHub Actions output.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "new_count=$new_count" >> "$GITHUB_OUTPUT"
fi
