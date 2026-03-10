#!/usr/bin/env python3
"""Upload a file to Linear and return a markdown-embeddable URL.

Usage: python3 upload-file.py <file-path>

Prints the asset URL on success. Embed in comments/workpad as:
  ![description](url)    # images
  [filename](url)        # other files

Env: LINEAR_API_KEY
"""

import json, mimetypes, os, sys, urllib.request

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 upload-file.py <file-path>", file=sys.stderr)
        sys.exit(1)

    file_path = sys.argv[1]
    api_key = os.environ.get("LINEAR_API_KEY")
    if not api_key:
        print("error: LINEAR_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(file_path):
        print(f"error: {file_path} not found", file=sys.stderr)
        sys.exit(1)

    filename = os.path.basename(file_path)
    content_type = mimetypes.guess_type(file_path)[0] or "application/octet-stream"
    size = os.path.getsize(file_path)

    # Step 1: Get upload URL from Linear
    data = gql(api_key,
        """mutation($filename: String!, $contentType: String!, $size: Int!, $makePublic: Boolean) {
            fileUpload(filename: $filename, contentType: $contentType, size: $size, makePublic: $makePublic) {
                success
                uploadFile {
                    uploadUrl
                    assetUrl
                    headers { key value }
                }
            }
        }""",
        {"filename": filename, "contentType": content_type, "size": size, "makePublic": True},
    )

    upload = data["fileUpload"]
    if not upload["success"]:
        print("error: fileUpload failed", file=sys.stderr)
        sys.exit(1)

    upload_url = upload["uploadFile"]["uploadUrl"]
    asset_url = upload["uploadFile"]["assetUrl"]
    headers = {h["key"]: h["value"] for h in upload["uploadFile"]["headers"]}

    # Step 2: PUT file bytes to upload URL
    file_bytes = open(file_path, "rb").read()
    headers["Content-Type"] = content_type
    req = urllib.request.Request(upload_url, data=file_bytes, headers=headers, method="PUT")
    resp = urllib.request.urlopen(req)
    if resp.status not in (200, 201):
        print(f"error: upload returned {resp.status}", file=sys.stderr)
        sys.exit(1)

    # Step 3: Return the asset URL
    print(asset_url)


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
