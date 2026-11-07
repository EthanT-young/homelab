# homelab

Docker Compose files for the services behind ethantyoung.com. Everything runs on one ARM VM, with Caddy handling HTTPS and routing each subdomain to its container over a shared Docker network (`production-network`).

| Service | URL | Folder |
|---|---|---|
| Portfolio | [ethantyoung.com](https://ethantyoung.com) | separate repo: [portfolio](https://github.com/EthanT-young/portfolio) |
| Uptime Kuma | [status.ethantyoung.com](https://status.ethantyoung.com) | `uptime-kuma/` |
| Open WebUI + Ollama | [ai.ethantyoung.com](https://ai.ethantyoung.com) | `ai-stack/` |
| File converter | [convert.ethantyoung.com](https://convert.ethantyoung.com) | separate repo: [convert](https://github.com/EthanT-young/convert) |
| Code Visualizer | [ethantyoung.com/projects/code-visualizer/app/](https://ethantyoung.com/projects/code-visualizer/app/) | separate repo: [code-visualizer](https://github.com/EthanT-young/code-visualizer), reached by Caddy through a Unix socket |

The Caddy config is in `caddy/conf/Caddyfile`. Images are pinned by digest, so upgrading a service means editing its `image:` line.

## Deploys

Pushing to `main` deploys automatically. A systemd timer runs `deploy/deploy.sh` every minute as `ethan`:

1. It looks at this repo and every git repo in a subfolder, but only deploys repos with a `.deploy` file created on the server. That file is gitignored and the script refuses a committed one, so cloning someone else's project here won't run it.
2. It checks the incoming commit in a scratch copy first: `docker compose config` for each changed project, and `caddy validate` with the Caddy image that commit pins. If the check fails, the server's files stay as they were.
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

1. Create the repo with a compose file that joins `production-network`, and add `.deploy` to its `.gitignore`.
2. `git clone https://github.com/EthanT-young/<name>.git /home/ethan/docker/<name>`, then `touch /home/ethan/docker/<name>/.deploy`. The next run starts it.
3. Add its route to `caddy/conf/Caddyfile` here and push.

For a private repo, add a read-only deploy key on GitHub, clone over SSH, and point that repo at its key: `git config core.sshCommand "ssh -i ~/.ssh/<name>_deploy -o IdentitiesOnly=yes -o BatchMode=yes"`.
