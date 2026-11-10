#!/usr/bin/env python3
"""Refuse compose configs from project repos that could reach outside their container.

deploy.sh runs this for every project repo (never for homelab itself) before
anything on the server changes, and again in the real checkout right before
`docker compose up`. Anyone who can get a commit onto a project repo's main
branch (an outside PR, a Dependabot bump, a stolen login) controls its compose
file. Without this check that is root on the host within a minute: compose can
ask for `privileged`, host namespaces, docker.sock or a bind mount of /.

The check is an allowlist: a compose key it doesn't know is refused, so new
compose features have to be reviewed before a project can use them. Exceptions
a project really needs go in compose-policy.json, next to this file.

Usage (deploy.sh builds the inputs with the same `docker compose` invocation
it uses for `up`):
  compose_policy.py POLICY REPO_NAME ROOT COMPOSE_FILE PROJECT CONFIG RAW
    POLICY        compose-policy.json
    REPO_NAME     repo folder name (the key in POLICY["repos"])
    ROOT          repo root on disk; nothing may point outside it
    COMPOSE_FILE  the one compose file passed to `docker compose -f`
    PROJECT       the compose project name passed with -p
    CONFIG        `docker compose config --format json` output
    RAW           the same with --no-interpolate (keeps env_file paths)
Prints one line per violation and exits 1 if there are any.
"""
import json
import os
import re
import sys

import yaml

# Service keys a project may use. Anything else is refused.
SERVICE_KEYS = {
    "attach", "build", "cap_add", "cap_drop", "command", "container_name",
    "cpu_count", "cpu_percent", "cpu_period", "cpu_quota", "cpu_shares", "cpus", "cpuset",
    "depends_on", "deploy", "dns", "dns_opt", "dns_search", "domainname",
    "entrypoint", "env_file", "environment", "expose", "extra_hosts", "healthcheck",
    "hostname", "image", "init", "labels", "logging", "mem_limit",
    "mem_reservation", "mem_swappiness", "memswap_limit", "network_mode", "networks",
    "oom_score_adj", "pids_limit", "platform", "post_start", "pre_stop", "profiles",
    "pull_policy", "read_only", "restart", "scale", "security_opt", "shm_size",
    "stdin_open", "stop_grace_period", "stop_signal", "tmpfs", "tty", "ulimits", "user",
    "volumes", "working_dir",
}
BUILD_KEYS = {"context", "dockerfile", "dockerfile_inline", "args", "target", "labels",
              "no_cache", "pull", "network", "shm_size", "platforms"}
TOP_KEYS = {"name", "services", "networks", "volumes", "configs", "secrets"}
NETWORK_KEYS = {"name", "external", "internal", "driver", "driver_opts", "labels", "ipam",
                "attachable", "enable_ipv6"}
NETWORK_DRIVER_OPTS = {"com.docker.network.bridge.inhibit_ipv4", "com.docker.network.bridge.enable_icc"}
NET_ATTACH_KEYS = {"aliases", "priority", "gw_priority"}
MOUNT_KEYS = {"type", "source", "target", "read_only", "bind", "volume", "tmpfs", "consistency"}
BIND_OPTS = {"create_host_path"}
VOLUME_OPTS = {"nocopy", "subpath"}
TMPFS_OPTS = {"size", "mode"}
VOLUME_KEYS = {"name", "labels", "driver"}
FILE_OBJ_KEYS = {"name", "content", "labels"}  # no `file`: content only
HOOK_KEYS = {"command", "user", "working_dir", "environment"}  # post_start/pre_stop
DEPLOY_KEYS = {"resources", "restart_policy", "replicas", "labels"}
RESOURCE_KEYS = {"cpus", "memory", "pids"}
LOG_DRIVERS = {"json-file", "local", "none"}
NNP = {"no-new-privileges", "no-new-privileges:true", "no-new-privileges=true"}


def main(argv):
    policy_path, repo_name, root, compose_file, project, config_path, raw_path = argv[1:8]
    with open(policy_path) as f:
        policy = json.load(f)
    with open(config_path) as f:
        cfg = json.load(f)
    with open(raw_path) as f:
        raw = json.load(f)
    repos = policy.get("repos", {})
    if repo_name not in repos:
        print(f"policy: repo {repo_name!r} is not listed in compose-policy.json")
        return 1
    v = Checker(policy, repos[repo_name], os.path.realpath(root), project)
    v.check_source_file(compose_file)
    v.check_config(cfg)
    v.check_raw(raw)
    for msg in v.errors:
        print(f"policy: {msg}")
    return 1 if v.errors else 0


class Checker:
    def __init__(self, policy, rules, root, project):
        self.root = root
        self.project = project
        self.ext_networks = set(policy.get("external_networks", []))
        self.cap_add = {c.upper() for c in rules.get("cap_add", [])}
        self.names = set(rules.get("names", []))
        self.images = set(rules.get("images", []))
        self.fixed_networks = set(rules.get("networks", []))
        self.fixed_volumes = set(rules.get("volumes", []))
        # Exact folders (relative to the repo root) a repo may bind-mount.
        self.binds = {}
        for b in rules.get("binds", []):
            parts = b.split("/")
            if not b or os.path.isabs(b) or any(x in ("", ".", "..", ".git") for x in parts):
                raise SystemExit(f"policy: bad bind entry {b!r} in compose-policy.json")
            self.binds[os.path.join(self.root, b)] = b
        self.net_raw_ok = bool(rules.get("allow_net_raw"))
        self.no_limits_ok = bool(rules.get("allow_no_limits"))
        self.errors = []

    def err(self, msg):
        self.errors.append(msg)

    def inside(self, path):
        """True if path, with every symlink resolved, is the repo root or below it."""
        if not isinstance(path, str) or not path or "$" in path:
            return False
        if "://" in path or path.startswith("git@"):
            return False  # remote build contexts and the like
        p = os.path.realpath(path if os.path.isabs(path) else os.path.join(self.root, path))
        return p == self.root or p.startswith(self.root + os.sep)

    def unknown(self, where, d, allowed):
        if not isinstance(d, dict):
            self.err(f"{where}: expected a mapping")
            return
        for k in d:
            if k not in allowed and not k.startswith("x-"):
                self.err(f"{where}: '{k}' is not allowed")

    # --- the compose file as written (things the rendered config hides) ---
    def check_source_file(self, path):
        if not self.inside(path):
            self.err(f"compose file {path} resolves outside the repo")
            return
        # compose reads .env next to the compose file for interpolation; a
        # symlink there could pull in another project's secrets.
        dotenv = os.path.join(os.path.dirname(path), ".env")
        if os.path.islink(dotenv) or (os.path.exists(dotenv) and not self.inside(dotenv)):
            self.err(".env next to the compose file must be a regular file in the repo")
        try:
            with open(path) as f:
                doc = yaml.safe_load(f)  # refuses custom tags such as !reset/!override
        except Exception as e:  # noqa: BLE001
            self.err(f"compose file can't be parsed safely: {e}")
            return
        if not isinstance(doc, dict):
            self.err("compose file is not a mapping")
            return
        # include: pulls in other files and env files, and vanishes from the
        # rendered config. extends with `file:` reads another file the same way.
        if "include" in doc:
            self.err("'include' is not allowed")
        for name, svc in (doc.get("services") or {}).items():
            ext = svc.get("extends") if isinstance(svc, dict) else None
            if isinstance(ext, dict) and "file" in ext:
                self.err(f"service {name}: 'extends' from another file is not allowed")
            elif isinstance(ext, str):
                pass  # extends another service in this same file

    # --- the rendered config (what `up` will actually do) ---
    def check_config(self, cfg):
        self.unknown("top level", cfg, TOP_KEYS)
        if cfg.get("name") != self.project:
            self.err(f"project name is {cfg.get('name')!r}, expected {self.project!r}")

        nets = cfg.get("networks") or {}
        shared = set()  # networks other projects' containers also sit on
        for key, n in nets.items():
            n = n or {}
            where = f"network {key}"
            self.unknown(where, n, NETWORK_KEYS)
            name = n.get("name", key)
            if n.get("external"):
                if name not in self.ext_networks:
                    self.err(f"{where}: external network {name!r} is not allowed")
                shared.add(key)
                continue
            if name in self.fixed_networks:
                shared.add(key)
            elif not name.startswith(self.project + "_"):
                self.err(f"{where}: fixed name {name!r} is not allowed")
            if n.get("driver") not in (None, "bridge"):
                self.err(f"{where}: driver {n.get('driver')!r} is not allowed")
            for opt in n.get("driver_opts") or {}:
                if opt not in NETWORK_DRIVER_OPTS:
                    self.err(f"{where}: driver option {opt!r} is not allowed")
            if n.get("ipam") not in (None, {}):
                self.err(f"{where}: custom ipam (subnets) is not allowed")
            if n.get("enable_ipv6"):
                self.err(f"{where}: enable_ipv6 is not allowed")

        vols = cfg.get("volumes") or {}
        for key, vol in vols.items():
            vol = vol or {}
            where = f"volume {key}"
            self.unknown(where, vol, VOLUME_KEYS)
            name = vol.get("name", key)
            if not (name.startswith(self.project + "_") or name in self.fixed_volumes):
                self.err(f"{where}: name {name!r} is not allowed (it could be another project's data)")
            if vol.get("driver") not in (None, "local"):
                self.err(f"{where}: driver {vol.get('driver')!r} is not allowed")

        for kind in ("configs", "secrets"):
            for key, obj in (cfg.get(kind) or {}).items():
                obj = obj or {}
                where = f"{kind[:-1]} {key}"
                self.unknown(where, obj, FILE_OBJ_KEYS)
                if "file" in obj and not self.inside(obj["file"]):
                    self.err(f"{where}: file {obj['file']} is outside the repo")

        for name, svc in (cfg.get("services") or {}).items():
            self.check_service(name, svc or {}, nets, shared)

    def check_service(self, name, svc, nets, shared):
        where = f"service {name}"
        self.unknown(where, svc, SERVICE_KEYS)

        for cap in svc.get("cap_add") or []:
            c = str(cap).upper().removeprefix("CAP_")
            if c not in self.cap_add:
                self.err(f"{where}: cap_add {cap} is not allowed")
        for opt in svc.get("security_opt") or []:
            if opt not in NNP:
                self.err(f"{where}: security_opt {opt!r} is not allowed")
        for hook in ("post_start", "pre_stop"):
            for h in svc.get(hook) or []:
                self.unknown(f"{where} {hook}", h, HOOK_KEYS)
        if not self.no_limits_ok:
            pids = svc.get("pids_limit")
            if not svc.get("cpus") or not svc.get("mem_limit") or not isinstance(pids, int) or pids <= 0:
                self.err(f"{where}: cpus, mem_limit and a positive pids_limit are required")
        if (svc.get("oom_score_adj") or 0) < 0:
            self.err(f"{where}: negative oom_score_adj is not allowed")
        mode = svc.get("network_mode")
        if mode is not None and mode != "none" and not str(mode).startswith("service:"):
            self.err(f"{where}: network_mode {mode!r} is not allowed")
        log = svc.get("logging") or {}
        if log.get("driver") not in (None, *LOG_DRIVERS):
            self.err(f"{where}: logging driver {log.get('driver')!r} is not allowed")
        for k in (svc.get("labels") or {}):
            if k.startswith("com.docker."):
                self.err(f"{where}: label {k!r} is reserved")

        dep = svc.get("deploy") or {}
        self.unknown(f"{where} deploy", dep, DEPLOY_KEYS)
        for part in ("limits", "reservations"):
            self.unknown(f"{where} deploy.resources.{part}",
                         (dep.get("resources") or {}).get(part) or {}, RESOURCE_KEYS)

        # Built images may only use this repo's own names, so a build can't
        # replace an image another project runs or builds FROM.
        if "build" in svc:
            b = svc["build"] or {}
            self.unknown(f"{where} build", b, BUILD_KEYS)
            ctx = b.get("context", ".")
            if not self.inside(ctx):
                self.err(f"{where}: build context {ctx} is outside the repo")
            elif b.get("dockerfile") and not self.inside(os.path.join(ctx, b["dockerfile"])):
                self.err(f"{where}: dockerfile {b['dockerfile']} is outside the repo")
            if b.get("network") not in (None, "default", "none"):
                self.err(f"{where}: build network {b.get('network')!r} is not allowed")
            for k in (b.get("labels") or {}):
                if k.startswith("com.docker."):
                    self.err(f"{where}: build label {k!r} is reserved")
            img = svc.get("image")
            if img is not None:
                m = re.fullmatch(r"([a-z0-9][a-z0-9._-]*)(?::latest)?", img)
                if not m or m.group(1) not in self.images:
                    self.err(f"{where}: built image name {img!r} is not allowed")

        # DNS names on shared networks: another project must not be able to
        # answer for "caddy", "open-webui", "kibitz"...
        dns = {name, *(filter(None, [svc.get("container_name")]))}
        attached = svc.get("networks") or {}
        on_shared = False
        for key, att in attached.items():
            att = att or {}
            self.unknown(f"{where} network {key}", att, NET_ATTACH_KEYS)
            dns.update(att.get("aliases") or [])
            if key in shared:
                on_shared = True
        if svc.get("container_name") and svc["container_name"] not in self.names:
            self.err(f"{where}: container_name {svc['container_name']!r} is not allowed")
        if on_shared:
            for n in sorted(dns - self.names):
                self.err(f"{where}: name {n!r} on a shared network is not allowed")
            # NET_RAW (in Docker's default set) allows ARP spoofing of the other
            # containers on the network, e.g. traffic between Caddy and a backend.
            dropped = {str(c).upper().removeprefix("CAP_") for c in svc.get("cap_drop") or []}
            if not self.net_raw_ok and not dropped & {"ALL", "NET_RAW"}:
                self.err(f"{where}: containers on a shared network must cap_drop NET_RAW (or ALL)")

        for m in svc.get("volumes") or []:
            self.check_mount(where, m)

    def check_mount(self, where, m):
        self.unknown(f"{where} mount", m, MOUNT_KEYS)
        t = m.get("type")
        if t == "bind":
            self.unknown(f"{where} bind", m.get("bind") or {}, BIND_OPTS)
            src = m.get("source")
            if not self.inside(src):
                self.err(f"{where}: bind mount {src} is outside the repo")
                return
            # Only folders listed in compose-policy.json, matched exactly and with
            # no symlink on the way (a writable bind of the repo root or .git
            # would let the container plant git hooks the deployer then runs).
            want = os.path.join(self.root, os.path.relpath(src, self.root))
            if want not in self.binds or os.path.realpath(want) != want:
                self.err(f"{where}: bind mount {src} is not in this repo's allowed binds")
        elif t == "volume":
            self.unknown(f"{where} volume", m.get("volume") or {}, VOLUME_OPTS)
        elif t == "tmpfs":
            self.unknown(f"{where} tmpfs", m.get("tmpfs") or {}, TMPFS_OPTS)
        else:
            self.err(f"{where}: mount type {t!r} is not allowed")

    # --- uninterpolated config: env_file paths survive only here ---
    def check_raw(self, raw):
        for name, svc in (raw.get("services") or {}).items():
            for ef in (svc or {}).get("env_file") or []:
                p = ef.get("path") if isinstance(ef, dict) else ef
                if not self.inside(p):
                    self.err(f"service {name}: env_file {p} is outside the repo")
                elif any(os.path.realpath(p).startswith(b + os.sep) for b in self.binds):
                    self.err(f"service {name}: env_file {p} is inside a bind-mounted folder")
            b = (svc or {}).get("build")
            if isinstance(b, dict) and "$" in str(b.get("context", "")):
                self.err(f"service {name}: build context uses a variable")
        for kind in ("configs", "secrets"):
            for key, obj in (raw.get(kind) or {}).items():
                if "file" in (obj or {}):
                    self.err(f"{kind[:-1]} {key}: file-based {kind} are not allowed")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
