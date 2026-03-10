#!/usr/bin/env python3
"""Read an issue's comments and attachments from Linear.

Returns a compact summary — not the full issue (the orchestrator already
provides title, description, state, labels, and URL in your prompt).

Usage: python3 read-issue.py <issue-id>

Env: LINEAR_API_KEY
"""

import json, os, sys, urllib.request

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 read-issue.py <issue-id>", file=sys.stderr)
        sys.exit(1)

    issue_id = sys.argv[1]
    api_key = os.environ.get("LINEAR_API_KEY")
    if not api_key:
        print("error: LINEAR_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    data = gql(api_key,
        """query($id: String!) {
            issue(id: $id) {
                comments(first: 50) {
                    nodes { id body user { name } createdAt }
                }
                attachments(first: 20) {
                    nodes { url title sourceType }
                }
            }
        }""",
        {"id": issue_id},
    )

    issue = data["issue"]

    comments = issue["comments"]["nodes"]
    if comments:
        print("## Comments\n")
        for c in comments:
            author = c["user"]["name"] if c.get("user") else "unknown"
            date = c["createdAt"][:10]
            print(f"### {author} ({date}) [id: {c['id']}]")
            print(c["body"])
            print()
    else:
        print("No comments.\n")

    attachments = issue["attachments"]["nodes"]
    if attachments:
        print("## Attachments\n")
        for a in attachments:
            source = f" ({a['sourceType']})" if a.get("sourceType") else ""
            print(f"- [{a.get('title', 'untitled')}]({a['url']}){source}")
        print()
    else:
        print("No attachments.\n")


def gql(api_key, query, variables):
    req = urllib.request.Request(
        "https://api.linear.app/graphql",
        data=json.dumps({"query": query, "variables": variables}).encode(),
        headers={"Content-Type": "application/json", "Authorization": api_key},
    )
    resp = json.loads(urllib.request.urlopen(req).read())
    if "errors" in resp:
        print(f"error: {resp['errors'][0]['message']}", file=sys.stderr)
        sys.exit(1)
    return resp["data"]


if __name__ == "__main__":
    main()
