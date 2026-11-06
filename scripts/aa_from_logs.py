#!/usr/bin/env python3
"""Synthesize an AppArmor profile from complain-mode audit records.

Reads kernel audit lines (dmesg / journalctl -k / audit.log) on stdin or from
files, keeps the records belonging to one learning profile, and emits an
enforce-mode profile covering everything the workload actually did.
"""

import argparse
import re
import sys
from collections import defaultdict

KV = re.compile(r'(\w+)=(?:"((?:[^"\\]|\\.)*)"|(\S+))')

# audit requested_mask char -> apparmor file permission char
MASK_MAP = {
    "r": "r", "w": "w", "a": "a", "c": "w", "d": "w",
    "l": "l", "k": "k", "m": "m",
}
# canonical emission order
PERM_ORDER = "mrwalk"

PID_RE = re.compile(r"/\d+(?=/|$)")
# dirs whose immediate children are per-process / per-boot and never stable
VOLATILE_DIRS = ("/proc", "/sys/fs/cgroup", "/run/user")


def parse_line(line):
    """Return a dict of key/value pairs if the line is an AppArmor audit record."""
    if "apparmor=" not in line:
        return None
    rec = {}
    for key, quoted, bare in KV.findall(line):
        val = quoted if quoted else bare
        rec[key] = val.replace('\\"', '"').replace("\\\\", "\\")
    return rec if "apparmor" in rec else None


def decode_name(name):
    """AppArmor hex-encodes names containing awkward bytes; decode when it did."""
    if re.fullmatch(r"(?:[0-9A-F]{2})+", name) and len(name) % 2 == 0:
        try:
            return bytes.fromhex(name).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            return name
    return name


def generalize_path(path):
    """Replace per-run components (pids, tids) with a glob."""
    for prefix in VOLATILE_DIRS:
        if path.startswith(prefix + "/"):
            return prefix + PID_RE.sub("/*", path[len(prefix):])
    return path


def apply_rewrites(path, rewrites):
    for pattern, repl in rewrites:
        new = pattern.sub(repl, path)
        if new != path:
            return new
    return path


def collapse_globs(files, threshold):
    """Fold sibling files sharing a permission set into <dir>/* once there are
    enough of them that listing each one is noise rather than signal."""
    if threshold <= 0:
        return files
    groups = defaultdict(list)
    for path, perms in files.items():
        if path.endswith("*"):
            continue
        parent, _, base = path.rpartition("/")
        if not parent or not base:
            continue
        groups[(parent, frozenset(perms))].append(path)

    out = dict(files)
    for (parent, perms), members in groups.items():
        if len(members) < threshold:
            continue
        for path in members:
            out.pop(path, None)
        glob = parent + "/*"
        out.setdefault(glob, set()).update(perms)
    return out


def absorb_covered(files):
    """Drop explicit paths already covered by a '<dir>/*' entry with >= perms."""
    globs = {p: perms for p, perms in files.items() if p.endswith("/*")}
    if not globs:
        return files
    out = {}
    for path, perms in files.items():
        if path in globs:
            out[path] = perms
            continue
        parent = path.rpartition("/")[0] + "/*"
        covering = globs.get(parent)
        if covering is not None and perms <= covering:
            continue
        out[path] = perms
    return out


def fmt_perms(perms):
    return "".join(c for c in PERM_ORDER if c in perms)


def quote(path):
    return '"%s"' % path.replace('"', '\\"')


class Collector:
    def __init__(self, args):
        self.args = args
        self.files = defaultdict(set)
        self.execs = defaultdict(set)
        self.caps = set()
        self.network = set()
        self.unix = set()
        self.signals = set()
        self.ptrace = set()
        self.mounts = set()
        self.dbus = set()
        self.unhandled = defaultdict(int)
        self.records = 0

    def wanted(self, rec):
        if rec.get("apparmor") not in ("ALLOWED", "DENIED", "AUDIT"):
            return False
        profile = rec.get("profile", "")
        # container runtimes stack profiles as "parent//child"
        return profile == self.args.profile or profile.startswith(self.args.profile + "//")

    def add(self, rec):
        if not self.wanted(rec):
            return
        self.records += 1
        op = rec.get("operation", "")
        cls = rec.get("class", "")
        mask = rec.get("requested_mask") or rec.get("denied_mask") or ""

        if op == "capable" or cls == "cap":
            name = rec.get("capname")
            if name:
                self.caps.add(name)
            return

        family = rec.get("family")
        if family == "unix":
            self.unix.add((rec.get("sock_type", "stream"), mask))
            return
        if family:
            self.network.add((family, rec.get("sock_type", "stream")))
            return

        if op == "signal":
            self.signals.add((mask or "send", rec.get("signal", ""), rec.get("peer", "")))
            return
        if op == "ptrace":
            self.ptrace.add((mask or "trace", rec.get("peer", "")))
            return
        if op in ("mount", "remount", "umount", "pivotroot"):
            self.mounts.add((op, rec.get("srcname", ""), rec.get("name", ""),
                             rec.get("flags", ""), rec.get("fstype", "")))
            return
        if cls == "dbus" or op.startswith("dbus_"):
            self.dbus.add((rec.get("bus", ""), rec.get("path", ""),
                           rec.get("interface", ""), rec.get("member", "")))
            return

        name = rec.get("name")
        if not name or not name.startswith("/"):
            if name:
                self.unhandled[op or cls or "unknown"] += 1
            return

        path = apply_rewrites(
            generalize_path(decode_name(name)) if self.args.generalize else decode_name(name),
            self.args.rewrites,
        )
        if any(p.match(path) for p in self.args.exclude):
            return

        perms = {MASK_MAP[c] for c in mask if c in MASK_MAP}
        if "x" in mask or op in ("exec", "exec_link"):
            self.execs[path].add(self.args.exec_mode)
            perms.add("r")
        if perms:
            self.files[path].update(perms)

    def finish(self):
        files = {}
        for path, perms in self.files.items():
            if "w" in perms:
                perms.discard("a")
            files[path] = perms
        files = absorb_covered(collapse_globs(files, self.args.glob_threshold))
        self.files = files


CONTAINER_BASELINE = """\
  # Container baseline (mirrors docker-default's hardening)
  deny @{PROC}/* w,
  deny @{PROC}/sys/[^k]** w,
  deny @{PROC}/sys/k[^e]** w,
  deny @{PROC}/sys/ke[^r]** w,
  deny @{PROC}/sys/ker[^n]** w,
  deny @{PROC}/sys/kern[^e]** w,
  deny @{PROC}/sys/kerne[^l]** w,
  deny @{PROC}/sys/kernel/{,**} wklx,
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/kcore rwklx,
  deny /sys/[^f]*/** wklx,
  deny /sys/f[^s]*/** wklx,
  deny /sys/fs/[^c]*/** wklx,
  deny /sys/fs/c[^g]*/** wklx,
  deny /sys/firmware/{,**} rwklx,
  deny mount,
"""


def render(c, args):
    L = []
    L.append("# AppArmor profile for %s" % args.name)
    L.append("# Generated by apparmor-profile-action (runtime learning).")
    L.append("# Source: %d audit records from profile %r." % (c.records, args.profile))
    L.append("# Edit by hand if you need to tighten it -- re-running the action")
    L.append("# regenerates this file wholesale.")
    L.append("")
    if args.abi:
        L.append("abi <abi/%s>," % args.abi)
    L.append("include <tunables/global>")
    L.append("")

    flags = list(args.flags)
    if args.mode == "complain":
        flags.append("complain")
    header = "profile %s" % args.name
    if args.attach:
        header += " %s" % args.attach
    if flags:
        header += " flags=(%s)" % ",".join(flags)
    L.append(header + " {")

    for abstraction in args.abstractions:
        L.append("  include <abstractions/%s>" % abstraction)
    if args.abstractions:
        L.append("")

    if args.template == "container":
        L.append(CONTAINER_BASELINE.rstrip())
        L.append("")

    if c.caps:
        L.append("  # capabilities")
        for cap in sorted(c.caps):
            L.append("  capability %s," % cap)
        L.append("")

    if c.network:
        L.append("  # network")
        for family, sock in sorted(c.network):
            L.append("  network %s %s," % (family, sock))
        L.append("")

    if c.unix:
        L.append("  # unix sockets")
        for sock, mask in sorted(c.unix):
            perms = ", ".join(sorted({m for m in mask.split()} or {"create"}))
            L.append("  unix (%s) type=%s," % (perms, sock))
        L.append("")

    if c.signals:
        L.append("  # signals")
        for mask, signal, peer in sorted(c.signals):
            rule = "  signal (%s)" % mask.replace(" ", ", ")
            if signal:
                rule += " set=(%s)" % signal
            if peer:
                rule += " peer=%s" % peer
            L.append(rule + ",")
        L.append("")

    if c.ptrace:
        L.append("  # ptrace")
        for mask, peer in sorted(c.ptrace):
            rule = "  ptrace (%s)" % mask.replace(" ", ", ")
            if peer:
                rule += " peer=%s" % peer
            L.append(rule + ",")
        L.append("")

    if c.mounts:
        L.append("  # mounts (review these: generated rules are intentionally narrow)")
        for op, src, dst, flags_, fstype in sorted(c.mounts):
            rule = "  %s" % ("umount" if op == "umount" else "mount")
            if fstype:
                rule += " fstype=%s" % fstype
            if src:
                rule += " %s" % quote(src)
            if dst:
                rule += " -> %s" % quote(dst)
            L.append(rule + ",")
        L.append("")

    if c.execs:
        L.append("  # executables")
        for path in sorted(c.execs):
            modes = sorted(c.execs[path])
            perms = fmt_perms(c.files.get(path, {"r"}))
            L.append("  %s %s%s," % (quote(path), perms, modes[0]))
        L.append("")

    plain = {p: v for p, v in c.files.items() if p not in c.execs}
    if plain:
        L.append("  # files")
        for path in sorted(plain):
            L.append("  %s %s," % (quote(path), fmt_perms(plain[path])))
        L.append("")

    for extra in args.extra_rule:
        L.append("  %s" % extra)
    if args.extra_rule:
        L.append("")

    while L and L[-1] == "":
        L.pop()
    L.append("}")
    L.append("")
    return "\n".join(L)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("logs", nargs="*", help="audit log files (default: stdin)")
    p.add_argument("--profile", required=True, help="learning profile name to filter on")
    p.add_argument("--name", required=True, help="name of the profile to emit")
    p.add_argument("--attach", default="", help="attachment path for a host binary profile")
    p.add_argument("--template", choices=["container", "host"], default="host")
    p.add_argument("--mode", choices=["enforce", "complain"], default="enforce")
    p.add_argument("--abi", default="", help='apparmor abi, e.g. "3.0" (omit to leave it out)')
    p.add_argument("--flags", default="attach_disconnected,mediate_deleted")
    p.add_argument("--abstractions", default="base")
    p.add_argument("--exec-mode", default="ix", choices=["ix", "Px", "Ux", "Cx", "px", "ux", "cx"])
    p.add_argument("--generalize", dest="generalize", action="store_true", default=True)
    p.add_argument("--no-generalize", dest="generalize", action="store_false")
    p.add_argument("--glob-threshold", type=int, default=0,
                   help="collapse N+ siblings sharing a permission set into <dir>/* (0 = off)")
    p.add_argument("--exclude", action="append", default=[],
                   help="regex of paths to drop entirely (repeatable)")
    p.add_argument("--rewrite", action="append", default=[],
                   help="REGEX=REPLACEMENT path rewrite, applied in order (repeatable)")
    p.add_argument("--extra-rule", action="append", default=[],
                   help="verbatim rule appended to the profile (repeatable)")
    p.add_argument("-o", "--output", default="-")
    args = p.parse_args()

    args.flags = [f for f in args.flags.split(",") if f]
    args.abstractions = [a for a in args.abstractions.split(",") if a]
    args.exclude = [re.compile(e) for e in args.exclude]
    args.rewrites = []
    for spec in args.rewrite:
        pattern, sep, repl = spec.partition("=")
        if not sep:
            p.error("--rewrite expects REGEX=REPLACEMENT, got %r" % spec)
        args.rewrites.append((re.compile(pattern), repl))

    collector = Collector(args)
    if args.logs:
        for path in args.logs:
            with open(path, "r", errors="replace") as fh:
                for line in fh:
                    rec = parse_line(line)
                    if rec:
                        collector.add(rec)
    else:
        for line in sys.stdin:
            rec = parse_line(line)
            if rec:
                collector.add(rec)

    collector.finish()

    if collector.records == 0:
        sys.stderr.write(
            "error: no audit records matched profile %r.\n"
            "       The workload may not have run under the learning profile, or the\n"
            "       runner may not expose kernel audit messages.\n" % args.profile)
        return 2

    if collector.unhandled:
        for op, count in sorted(collector.unhandled.items()):
            sys.stderr.write("note: %d unmapped %r record(s) ignored\n" % (count, op))

    text = render(collector, args)
    if args.output == "-":
        sys.stdout.write(text)
    else:
        with open(args.output, "w") as fh:
            fh.write(text)
        sys.stderr.write("wrote %s (%d files, %d caps, %d net rules)\n"
                         % (args.output, len(collector.files), len(collector.caps),
                            len(collector.network)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
