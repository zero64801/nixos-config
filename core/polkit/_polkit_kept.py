import glob
import json
import sys
import xml.etree.ElementTree as ET

LEVELS = ("allow_any", "allow_inactive", "allow_active")

kept = {}
for path in sorted(glob.glob(sys.argv[1] + "/*.policy")):
    for action in ET.parse(path).getroot().iter("action"):
        defaults = action.find("defaults")
        levels = [(defaults.findtext(k) or "no").strip() if defaults is not None else "no" for k in LEVELS]
        if any(level.endswith("_keep") for level in levels):
            kept[action.get("id")] = levels

print(f"""var kept = {json.dumps(kept, sort_keys=True)};

polkit.addRule(function (action, subject) {{
  var levels = kept[action.id];
  if (!levels) {{
    return polkit.Result.NOT_HANDLED;
  }}
  var level = subject.local ? (subject.active ? levels[2] : levels[1]) : levels[0];
  if (level === "auth_admin_keep") {{
    return polkit.Result.AUTH_ADMIN;
  }}
  if (level === "auth_self_keep") {{
    return polkit.Result.AUTH_SELF;
  }}
  return polkit.Result.NOT_HANDLED;
}});""")
