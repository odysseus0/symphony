#!/usr/bin/env python3
"""Sync local workpad.md to a Linear issue comment.

First call creates the comment; subsequent calls update it.

Usage: python3 sync-workpad.py <issue-id>

Reads:  workpad.md   (workpad content)
State:  .workpad-id  (persisted comment ID, created automatically)
Env:    LINEAR_API_KEY
"""

import json, os, sys, urllib.request

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 sync-workpad.py <issue-id>", file=sys.stderr)
        sys.exit(1)

    issue_id = sys.argv[1]
    api_key = os.environ.get("LINEAR_API_KEY")
    if not api_key:
        print("error: LINEAR_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists("workpad.md"):
        print("error: workpad.md not found", file=sys.stderr)
        sys.exit(1)

    body = open("workpad.md").read()

    if os.path.exists(".workpad-id"):
        comment_id = open(".workpad-id").read().strip()
        data = gql(api_key,
            """mutation($id: String!, $body: String!) {
                commentUpdate(id: $id, input: { body: $body }) { success }
            }""",
            {"id": comment_id, "body": body},
        )
        if not data["commentUpdate"]["success"]:
            print("error: update failed", file=sys.stderr)
            sys.exit(1)
        print("synced (updated)")
    else:
        data = gql(api_key,
            """mutation($issueId: String!, $body: String!) {
                commentCreate(input: { issueId: $issueId, body: $body }) {
                    success
                    comment { id }
                }
            }""",
            {"issueId": issue_id, "body": body},
        )
        if not data["commentCreate"]["success"]:
            print("error: create failed", file=sys.stderr)
            sys.exit(1)
        open(".workpad-id", "w").write(data["commentCreate"]["comment"]["id"])
        print("synced (created)")


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
