"""Keeps only the part's file name in a .coastline project's partPath (the part is found next
to the project), so no local folder names end up in the repository."""
import re
import sys

for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        text = f.read()
    text = re.sub(r'("partPath" : ")[^"]*\\/([^"\\/]+)"', lambda m: m.group(1) + m.group(2) + '"', text)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
