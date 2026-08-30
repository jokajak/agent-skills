# agent-skills

[Agent Skills](https://agentskills.io/specification) for my own workflows,
packaged as a Claude Code plugin marketplace.

## Install

```
/plugin marketplace add jokajak/agent-skills
/plugin install homelab@jokajak-skills
```

Pin to a tag or branch with `jokajak/agent-skills@v1.0`.

## Plugins

### `homelab`

Skills for operating the [home-ops](https://github.com/jokajak/home-ops) cluster.

| Skill | What it does |
|---|---|
| `cluster-logs` | Search Kubernetes and journald logs in VictoriaLogs with LogsQL |

## Layout

```
.claude-plugin/marketplace.json     # marketplace manifest
plugins/<plugin>/
  .claude-plugin/plugin.json        # plugin manifest
  skills/<skill>/
    SKILL.md                        # metadata + instructions
    scripts/                        # executables the skill invokes
    references/                     # documentation loaded on demand
```

Skills follow the Agent Skills specification: `SKILL.md` carries YAML
frontmatter with `name` and `description`, and bundled files are referenced by
relative path so they load only when a task calls for them.

## Configuration

No skill in this repository hardcodes a hostname, credential, or network detail.
Anything environment-specific is read from environment variables with no
defaults, and the script fails loudly when one is missing. See each skill's
`SKILL.md` for the variables it expects.

## License

MIT — see [LICENSE](LICENSE).
