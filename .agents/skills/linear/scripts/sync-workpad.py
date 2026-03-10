#!/usr/bin/env python3
"""Sync a local markdown file to a Linear issue comment.

First call creates the comment; subsequent calls update it.

Usage: python3 sync-workpad.py <issue-id> [path]

Args:   issue-id  Linear issue identifier (e.g. ORC-535)
        path      Markdown file to sync (default: workpad.md)
State:  .workpad-id  (persisted comment ID, created automatically)
Env:    LINEAR_API_KEY
"""

import json, os, sys, urllib.request

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 sync-workpad.py <issue-id> [path]", file=sys.stderr)
        sys.exit(1)

    issue_id = sys.argv[1]
    workpad_path = sys.argv[2] if len(sys.argv) > 2 else "workpad.md"
    api_key = os.environ.get("LINEAR_API_KEY")
    if not api_key:
        print("error: LINEAR_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(workpad_path):
        print(f"error: {workpad_path} not found", file=sys.stderr)
        sys.exit(1)

    body = open(workpad_path).read()

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
