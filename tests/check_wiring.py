#!/usr/bin/env python3
"""Cross-check the reusable workflow against the sub-actions it dispatches to.

actionlint cannot validate `uses: ./.apparmor-profile-action/_*`
because that path only exists at runtime, after the generator repo is checked
out. So the mapping of 67 workflow inputs onto two sub-actions is unchecked by
every other tool in the repo. This checks it.
"""

import re
import sys
import yaml

WORKFLOW = ".github/workflows/apparmor-profile.yml"
SUB_ACTIONS = {
    "_docker": "_docker/action.yml",
    "_host": "_host/action.yml",
}

errors = []
REF = re.compile(r"inputs\.([A-Za-z0-9_]+)")


def load(path):
    with open(path) as fh:
        return yaml.safe_load(fh)


wf = load(WORKFLOW)
# PyYAML parses the bare `on:` key as the boolean True.
call = wf[True]["workflow_call"]
wf_inputs = set(call["inputs"])

steps = wf["jobs"]["generate"]["steps"]
dispatched = set()

for step in steps:
    uses = step.get("uses", "")
    sub = next((s for s in SUB_ACTIONS if uses.endswith(s)), None)
    if not sub:
        continue
    dispatched.add(sub)
    action = load(SUB_ACTIONS[sub])
    declared = action["inputs"]
    required = {k for k, v in declared.items() if v.get("required")}
    provided = set(step.get("with") or {})

    for key in sorted(provided - set(declared)):
        errors.append("%s: passes '%s', which %s does not declare"
                      % (step["name"], key, sub))
    for key in sorted(required - provided):
        errors.append("%s: does not pass '%s', required by %s"
                      % (step["name"], key, sub))

    # Every value must come from a workflow input or an earlier step output.
    for key, value in (step.get("with") or {}).items():
        for ref in REF.findall(str(value)):
            if ref not in wf_inputs:
                errors.append("%s: '%s' references inputs.%s, which the "
                              "workflow does not declare" % (step["name"], key, ref))

for sub in SUB_ACTIONS:
    if sub not in dispatched:
        errors.append("the workflow never dispatches to %s" % sub)

# Nothing may reintroduce a free-form shell input.
for banned in ("run", "setup_command", "command", "script"):
    if banned in wf_inputs:
        errors.append("workflow declares input '%s': commands must stay baked "
                      "into the sub-actions" % banned)

# Inputs declared but never forwarded anywhere are dead weight; catch typos
# in the other direction too.
# Scan the raw file so `if:` conditions and job-level expressions count too.
with open(WORKFLOW) as fh:
    referenced = set(REF.findall(fh.read()))
# The `inputs:` declarations themselves are not references.
unused = wf_inputs - referenced
if unused:
    errors.append("workflow inputs declared but never used: %s"
                  % ", ".join(sorted(unused)))

# --- the examples must only use inputs the workflow actually declares ------
import glob

declared_secrets = set(call.get("secrets") or {})
for path in sorted(glob.glob("examples/caller-*.yml")):
    doc = load(path)
    for job_name, job in (doc.get("jobs") or {}).items():
        if "apparmor-profile.yml" not in str(job.get("uses", "")):
            continue
        for key in sorted(set(job.get("with") or {}) - wf_inputs):
            errors.append("%s: job '%s' passes '%s', which the workflow does "
                          "not declare" % (path, job_name, key))
        for key in sorted(set(job.get("secrets") or {}) - declared_secrets):
            errors.append("%s: job '%s' passes secret '%s', which the workflow "
                          "does not declare" % (path, job_name, key))
        required = {k for k, v in call["inputs"].items() if v.get("required")}
        for key in sorted(required - set(job.get("with") or {})):
            errors.append("%s: job '%s' omits required input '%s'"
                          % (path, job_name, key))

if errors:
    for e in errors:
        print("FAIL     %s" % e)
    sys.exit(1)

print("ok       workflow/sub-action wiring (%d workflow inputs, %d sub-actions)"
      % (len(wf_inputs), len(SUB_ACTIONS)))
print("ok       example callers use only declared inputs (%d examples)"
      % len(glob.glob("examples/caller-*.yml")))
