#!/usr/bin/env python3
"""Insert the DNS hooks into cloudflared; apply cloudflared_socks.patch separately.

Usage: python3 patch_cloudflared.py /path/to/cloudflared
"""

import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys


MAIN_HOOK = '''
	// Use an IP:port endpoint so resolving the DNS server cannot recurse.
	if dnsAddr := os.Getenv("TUNNEL_DNS_ADDRESS"); dnsAddr != "" {
		net.DefaultResolver = &net.Resolver{
			PreferGo: true,
			Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
				var dialer net.Dialer
				return dialer.DialContext(ctx, network, dnsAddr)
			},
		}
	}
'''

DOT_HOOK = '''
	// A custom resolver owns fallback policy; do not bypass it with direct DoT.
	if os.Getenv("TUNNEL_DNS_ADDRESS") != "" {
		return "", nil, fmt.Errorf("direct DoT fallback disabled with TUNNEL_DNS_ADDRESS")
	}
'''

# Hide Go comments and literals before locating declarations, preserving offsets.
NON_CODE = re.compile(
    r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|'
    r"'(?:\\.|[^'\\])*'|`[^`]*`"
)


def mask(source, comments_only=False):
    def replace(match):
        if comments_only and not match[0].startswith(("//", "/*")):
            return match[0]
        return re.sub(r"[^\n]", " ", match[0])

    return NON_CODE.sub(replace, source)


def insert_hook(source, names, hook):
    # These target functions have ordinary signatures, with no interface/struct
    # literals in their argument or result types. Reject ambiguous declarations.
    pattern = r"(?m)^func\s+(?:" + "|".join(map(re.escape, names)) + r")\s*\([^{}]*\)\s*\{"
    matches = list(re.finditer(pattern, mask(source)))
    if len(matches) != 1:
        raise ValueError(f"expected exactly one function {names}, found {len(matches)}")
    offset = matches[0].end()
    # Recognize the previous patch too, without needing a new marker comment.
    if source[offset:].startswith(hook):
        return source
    body = mask(source)[offset:]
    depth = 1
    for index, char in enumerate(body):
        depth += (char == "{") - (char == "}")
        if depth == 0:
            if "TUNNEL_DNS_ADDRESS" in source[offset:offset + index]:
                raise ValueError(f"function {names} already has a different DNS hook")
            return source[:offset] + hook + source[offset:]
    raise ValueError(f"function {names} has an unclosed body")


def add_imports(source, packages):
    # cloudflared uses an import block; fail rather than guess if that changes.
    matches = list(re.finditer(r"(?m)^import\s*\(", mask(source)))
    if len(matches) != 1:
        raise ValueError("expected exactly one import block")
    start = matches[0].end()
    end = mask(source).find(")", start)
    if end < 0:
        raise ValueError("unclosed import block")
    imports = mask(source[start:end], comments_only=True)
    missing = []
    for package in packages:
        found = re.search(r'(?m)^\s*(?:(\w+|\.)\s+)?"' + re.escape(package) + r'"', imports)
        if found is None:
            missing.append(package)
        elif found[1] not in (None, package):
            raise ValueError(f"import {package} has unsupported alias {found[1]}")
    return source[:start] + "".join(f'\n\t"{p}"' for p in missing) + source[start:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=Path, default=Path("."))
    args = parser.parse_args()
    targets = [
        ("cmd/cloudflared/main.go", ("main",), MAIN_HOOK, ("context", "net", "os")),
        ("edgediscovery/allregions/discovery.go", ("lookupSRVWithDOT", "lookupSRVWithDoT"), DOT_HOOK, ("fmt", "os")),
    ]
    pending = []
    gofmt = shutil.which("gofmt")
    # Validate and prepare both files before writing either of them.
    for relative, names, hook, imports in targets:
        path = args.source / relative
        original = path.read_text(encoding="utf-8")
        updated = add_imports(insert_hook(original, names, hook), imports)
        if gofmt and updated != original:
            updated = subprocess.run(
                [gofmt], input=updated, text=True, capture_output=True, check=True
            ).stdout
        pending.append((path, original, updated))
    for path, original, updated in pending:
        if updated != original:
            path.write_text(updated, encoding="utf-8")
        print(f"{'patched' if updated != original else 'already patched'}: {path}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"error: {error}")
