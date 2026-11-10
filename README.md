# homelab

Docker Compose files for the services behind ethantyoung.com. Everything runs on one ARM VM, with Caddy handling HTTPS and routing each subdomain to its container over a shared Docker network (`production-network`).

| Service | URL | Folder |
|---|---|---|
| Portfolio | [ethantyoung.com](https://ethantyoung.com) | separate repo: [portfolio](https://github.com/EthanT-young/portfolio) |
| Uptime Kuma | [status.ethantyoung.com](https://status.ethantyoung.com) | `uptime-kuma/` |
| Open WebUI + Ollama | [ai.ethantyoung.com](https://ai.ethantyoung.com) | `ai-stack/` |
| File converter | [convert.ethantyoung.com](https://convert.ethantyoung.com) | separate repo: [convert](https://github.com/EthanT-young/convert) |
| Code Visualizer | [ethantyoung.com/projects/code-visualizer/app/](https://ethantyoung.com/projects/code-visualizer/app/) | separate repo: [code-visualizer](https://github.com/EthanT-young/code-visualizer), reached by Caddy through a Unix socket |
| Kibitz (chess game review) | [ethantyoung.com/projects/kibitz/](https://ethantyoung.com/projects/kibitz/) | separate repo: [kibitz-chess](https://github.com/EthanT-young/kibitz-chess) |

The Caddy config is in `caddy/conf/Caddyfile`. Images are pinned by digest, so upgrading a service means editing its `image:` line.

## Deploys

Pushing to `main` deploys automatically. A systemd timer runs `deploy/deploy.sh` every minute as `ethan`:

1. It looks at this repo and every git repo in a subfolder, but only deploys repos with a `.deploy` file created on the server. That file is gitignored and the script refuses a committed one, so cloning someone else's project here won't run it.
2. It checks the incoming commit in a scratch copy first: `docker compose config` for each changed project, and `caddy validate` with the Caddy image that commit pins. If the check fails, the server's files stay as they were.
   Project repos (everything except this one) also have to pass `deploy/compose_policy.py`, because anyone who can get a commit onto their `main` controls their compose file. It refuses anything that reaches outside the container: privileged mode (including in `post_start` hooks), added capabilities, host networking or namespaces, published ports, bind mounts other than the folders listed for that repo, env files outside the repo, other projects' volumes and networks, names that would shadow another service on a shared network, `include`, and any compose key it doesn't know. Every service also needs `cpus`, `mem_limit` and `pids_limit`, and containers on a shared network must drop `NET_RAW`. A project repo must be listed in `deploy/compose-policy.json`, which also holds its exceptions, and its compose file must sit at the repo root; the compose project is always named after the repo's folder on the server, so a repo can't pose as another project. A refused commit leaves the server untouched, and if it's still refused on the third try it goes in the attention file. Compose runs for project repos with that fixed name and file and an empty environment, and the check runs again in the real checkout right before `up`.
3. It fast-forwards to `origin/main` and runs `docker compose up -d --build --remove-orphans` for each changed project, then hot-reloads Caddy. Project repos go before this one, so a new service is already up when its route goes live. A repo the script hasn't seen before gets deployed in full.
4. Local edits or commits on the server that aren't on GitHub make it skip that repo. It never overwrites them.
5. A failed deploy is retried every minute, then every 15 minutes after three failures of the same commit. There's no automatic rollback, so the fix is another push.

To roll back, `git revert` the bad commit and push. Because images are pinned, that also restores the previous image versions.

Logs: `journalctl -u homelab-deploy`

If a compose file is deleted or its folder renamed, the old containers keep running. The script writes the cleanup command to `~/.local/state/homelab-deploy/attention`. Delete that file once you've handled it.

### Setup on a new server

```sh
sudo install -m 644 deploy/homelab-deploy.service deploy/homelab-deploy.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now homelab-deploy.timer
```

Optional heartbeat: put `DEPLOY_PUSH_URL=<Uptime Kuma push URL>` in `~/.config/homelab-deploy/env`. Only fully healthy runs ping it, so a failed or skipped deploy, or an open attention file, shows up as a down monitor. Give the monitor an interval of 5 to 10 minutes so a single slow run doesn't trip it.

### Adding a project

1. Create the repo with a compose file that joins `production-network` (or its own internal network that Caddy joins), and add `.deploy` to its `.gitignore`.
2. Add the repo to `deploy/compose-policy.json` here: its container and network names, the names of images it builds, and any folders it bind-mounts. Push that first: the deployer reads the policy from this repo, so a project it doesn't know yet is refused.
3. `git clone https://github.com/EthanT-young/<name>.git /home/ethan/docker/<name>`, then `touch /home/ethan/docker/<name>/.deploy`. The next run starts it.
4. Add its route to `caddy/conf/Caddyfile` here and push.

For a private repo, add a read-only deploy key on GitHub, clone over SSH, and point that repo at its key: `git config core.sshCommand "ssh -i ~/.ssh/<name>_deploy -o IdentitiesOnly=yes -o BatchMode=yes"`.

## Host firewall changes

Changes made to the server outside Docker, with how to undo each one.

### Containers can't reach Oracle Cloud's link-local services

Installed by `host/docker-block-metadata.sh` (run once by hand with sudo). Containers and image builds can't reach 169.254.0.0/16, which holds the instance metadata service at 169.254.169.254 (instance details, user-data, and credentials if an instance principal is ever set up) and other Oracle services. DNS to 169.254.169.254 still works, because it's also Oracle's DNS resolver and every build needs it. The host itself isn't affected: its DNS, NTP and the Oracle agent don't pass through these rules, and neither do Docker's image pulls.

What's on the server:

| Path | What it is |
|---|---|
| `/usr/local/sbin/docker-block-metadata` | Helper. `add` builds the rules, `remove` deletes them. Its header repeats the undo steps below. |
| `/etc/systemd/system/docker-block-metadata.service` | Runs `add` every time Docker starts and `remove` when Docker stops. |
| iptables chain `DOCKER-METADATA` | The rules: allow DNS (UDP and TCP 53) to 169.254.169.254, reject the rest of 169.254.0.0/16. |
| A jump in `DOCKER-USER` | Sends container traffic to 169.254.0.0/16 into `DOCKER-METADATA`. |

Nothing goes in `/etc/iptables/rules.v4`.

Check it's working: `systemctl status docker-block-metadata` should say `active (exited)`, and `sudo iptables -S DOCKER-METADATA` should list two RETURN rules and a REJECT.

To undo it:

```sh
sudo /usr/local/sbin/docker-block-metadata remove            # takes the rules out immediately
sudo systemctl disable --now docker-block-metadata.service   # stops them coming back
sudo rm /etc/systemd/system/docker-block-metadata.service /usr/local/sbin/docker-block-metadata
sudo systemctl daemon-reload
sudo iptables -S DOCKER-USER                                 # no DOCKER-METADATA line should be left
```

If container DNS ever breaks and you suspect these rules, the first line alone is enough to rule them out. That only lasts until Docker restarts or the server reboots, when the unit adds the rules again; `sudo systemctl restart docker-block-metadata` puts them back sooner. Running `bash host/docker-block-metadata.sh` again reinstalls the files and re-applies the rules.

